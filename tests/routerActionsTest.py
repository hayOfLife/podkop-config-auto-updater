"""Проверяет настоящие команды в изолированном chroot с подставными сетью и пакетным менеджером

Фикстуры проверяют отсутствие записи при тесте и границы установки пакетов, но не работу живого роутера
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

install = Path(sys.argv[1]).resolve()
source = Path('package/luci-app-podkop-config-auto-updater/root').resolve()
assert os.geteuid() == 0, 'Run isolated chroot tests with sudo'
checks = 0
chroot = shutil.which('chroot')
environment = {**os.environ, 'PATH': '/bin', 'LD_LIBRARY_PATH': str(install / 'lib')}

with tempfile.TemporaryDirectory(prefix='podkop-router-actions-') as directory:
    root = Path(directory)
    copied = set()

    def copy_binary(path, destination=None):
        path = Path(path)
        destination = destination or str(path)
        target = root / destination.lstrip('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if str(path) in copied:
            return
        copied.add(str(path))
        listing = subprocess.run(['ldd', str(path)], env={**os.environ, 'LD_LIBRARY_PATH': str(install / 'lib')},
                                 text=True, capture_output=True)
        assert 'not found' not in listing.stdout, listing.stdout
        for library in re.findall(r'(?:=>\s+|^\s*)(/[^\s]+)', listing.stdout, re.MULTILINE):
            copy_binary(library)

    shutil.copytree(install, root / str(install).lstrip('/'))
    for name in ['sh', 'mkdir', 'chmod', 'flock', 'mktemp', 'rm', 'cp', 'mv', 'sed', 'cat', 'sha256sum']:
        copy_binary(shutil.which(name), '/bin/' + name)
    copy_binary(install / 'bin/ucode', '/bin/ucode')
    for library in (install / 'lib').rglob('*.so*'):
        if library.is_file():
            copy_binary(library)
    (root / 'dev').mkdir()
    subprocess.run(['mknod', str(root / 'dev/null'), 'c', '1', '3'], check=True)
    os.chmod(root / 'dev/null', 0o666)

    def write(path, data, executable=False):
        target = root / path.lstrip('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(data, encoding='utf-8')
        target.chmod(0o755 if executable else 0o600)

    write('/bin/ucode', f'#!/bin/sh\nexec "{install}/bin/ucode" -L "{install}/lib/ucode" "$@"\n', True)

    write('/bin/curl', '''#!/bin/sh
out=''
while [ "$#" -gt 0 ]; do
 case "$1" in --output|-o) shift; out="$1" ;; esac
 url="$1"; shift
done
[ "${MOCK_DOWNLOAD_FAIL:-0}" = 0 ] || exit 22
if [ "${MOCK_CURL_EXIT:-0}" != 0 ]; then printf '%s' "${MOCK_HTTP_CODE:-000}"; exit "$MOCK_CURL_EXIT"; fi
case "$url" in
 */releases/latest)
  printf '%s\\n' "$url" >> /fixtures/urls
  [ "$url" = "https://api.github.com/repos/$(cat /fixtures/repository)/releases/latest" ] || exit 99
  cp /fixtures/release.json "$out" ;;
 */releases/download/*)
  printf '%s\\n' "$url" >> /fixtures/urls
  case "$url" in "https://github.com/$(cat /fixtures/repository)/releases/download/"*) ;; *) exit 99 ;; esac
  cp "/fixtures/assets/${url##*/}" "$out" ;;
 *) cp /fixtures/feed.json "$out" ;;
esac
printf '%s' "${MOCK_HTTP_CODE:-200}"
[ "${MOCK_HTTP_CODE:-200}" -lt 400 ] || exit 22
''', True)
    manager = '''#!/bin/sh
kind="${0##*/}"
action="$1"; shift
case "$action" in
 status|info)
  for arg do name="$arg"; done
  [ -f "/fixtures/installed/$name" ] || exit 1
  value="$(cat "/fixtures/installed/$name")"
  if [ "$kind" = opkg ]; then printf 'Version: %s\\n' "$value";
  else printf '{\\n  "version": "%s"\\n}\\n' "$value"; fi ;;
 compare-versions)
  [ "${MOCK_COMPARE_FAIL:-0}" = 0 ] || exit 2
  if [ "$1" = "$3" ]; then comparison='='; elif [ "$3" = 9.9.9-r1 ] || [ "$3" = 0.261024.70000 ]; then comparison='<'; else comparison='>'; fi
  [ "$2" = "$comparison" ] ;;
 version)
  [ "${MOCK_COMPARE_FAIL:-0}" = 0 ] || exit 2
  if [ "$2" = "$3" ]; then printf '='; elif [ "$3" = 9.9.9-r1 ] || [ "$3" = 0.261024.70000 ]; then printf '<'; else printf '>'; fi ;;
 update)
  printf '%s update\\n' "$kind" >> /fixtures/calls
  [ "${MOCK_INDEX_FAIL:-0}" = 0 ] ;;
 install|add)
  printf '%s %s\\n' "$kind" "$action" >> /fixtures/calls
  [ "${MOCK_INSTALL_FAIL:-0}" = 0 ] || exit 1
  for file do
   [ "$file" = --allow-untrusted ] && continue
   name="$(sed -n '1p' "$file")"; value="$(sed -n '2p' "$file")"
   [ "${MOCK_VERSION_MISMATCH:-0}" = 0 ] || value=0.0.0-r1
   printf '%s' "$value" > "/fixtures/installed/$name"
   if [ "${MOCK_MISSING_TRANSLATION:-0}" = 1 ] && [ "$name" = luci-i18n-podkop-exp-ru ]; then rm "/fixtures/installed/$name"; fi
  done
  if [ "${MOCK_REPLACE_CODE:-0}" = 1 ]; then
   printf 'exit 99\\n' > /usr/libexec/podkop-config-auto-updater/software-io
   printf 'broken source\\n' > /usr/share/podkop-config-auto-updater/software.uc
  fi ;;
 *) exit 2 ;;
esac
'''
    write('/bin/opkg', manager, True)
    write('/bin/apk', manager, True)

    def reset(format='apk', token='demo_token', architecture='aarch64_cortex-a53'):
        for name in ['etc', 'tmp', 'fixtures']:
            shutil.rmtree(root / name, ignore_errors=True)
        shutil.copytree(source, root, dirs_exist_ok=True)
        release = "DISTRIB_RELEASE='" + ('25.12.6' if format == 'apk' else '24.10.7') + "'\n"
        if architecture is not None:
            release += "DISTRIB_ARCH='" + architecture + "'\n"
        write('/etc/openwrt_release', release)
        write('/etc/config/podkop_config_auto_updater', "config settings 'main'\n option enabled '0'\n option config_url 'https://github.com/example/config/blob/main/config/main.json'\n option github_token '" + token + "'\n")
        write('/etc/config/podkop', "config section 'main'\n option connection_type 'proxy'\n")
        write('/tmp/podkop-config-auto-updater/schedule.json', '{"next":1900000000}')
        write('/tmp/podkop-config-auto-updater/previous-podkop', 'previous configuration')
        write('/tmp/podkop-config-auto-updater/status.json', '{"state":"unchanged"}')
        write('/fixtures/feed.json', json.dumps({'schema_version': 2, 'revision': 'demo', 'main': {'user_domains': ['example.com']}, 'settings': {}}))
        write('/fixtures/calls', '')
        write('/fixtures/urls', '')
        (root / 'fixtures/installed').mkdir()
        return snapshot()

    def snapshot():
        paths = [root / 'etc/config/podkop', root / 'etc/config/podkop_config_auto_updater',
                 root / 'tmp/podkop-config-auto-updater/schedule.json', root / 'tmp/podkop-config-auto-updater/previous-podkop',
                 root / 'tmp/podkop-config-auto-updater/status.json']
        return {str(path): (path.read_bytes(), path.stat().st_mode) for path in paths}

    def command(program, action, extra=None):
        result = subprocess.run([chroot, str(root), '/usr/libexec/podkop-config-auto-updater/' + program, action],
                                env={**environment, **(extra or {})}, capture_output=True, text=True, timeout=20)
        assert 'demo_token' not in result.stdout + result.stderr
        assert result.stdout, (result.returncode, result.stderr)
        return result.returncode, json.loads(result.stdout)

    for case in ['valid', 'comments', 'unfinished_comment', 'network', 'json', 'schema', 'token', 'busy']:
        before = reset(token='' if case == 'token' else 'demo_token')
        write('/tmp/.uci/podkop', 'pending manual settings')
        if case == 'json': write('/fixtures/feed.json', '{broken JSON')
        if case == 'schema': write('/fixtures/feed.json', '{"schema_version":99}')
        if case == 'comments':
            write('/fixtures/feed.json', '// Группа\n' + (root / 'fixtures/feed.json').read_text() + '\n/* Конец */')
        if case == 'unfinished_comment': write('/fixtures/feed.json', '{/* unfinished')
        lock = None
        if case == 'busy':
            lock = (root / 'tmp/podkop-config-auto-updater/lock').open('w')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, report = command('run', 'test', {'MOCK_DOWNLOAD_FAIL': '1' if case == 'network' else '0'})
        if lock: lock.close()
        valid = case in ['valid', 'comments']
        assert code == (0 if valid else 1), (case, report)
        assert report['state'] == ('tested' if valid else 'error'), (case, report)
        if case != 'busy':
            assert report['downloaded'] == (case in ['valid', 'comments', 'unfinished_comment', 'json', 'schema']), (case, report)
            assert report['parsed'] == (case in ['valid', 'comments', 'schema']), (case, report)
            assert report['valid'] == valid, (case, report)
        if case == 'unfinished_comment': assert report['error'] == 'invalid_json'
        assert snapshot() == before, case
        assert not list((root / 'tmp/podkop-config-auto-updater').glob('run.*'))
        checks += 1

    reset()
    write('/etc/init.d/podkop', '#!/bin/sh\nexit 0\n', True)
    updater = root / 'etc/config/podkop_config_auto_updater'
    updater.write_text(updater.read_text() + " list ignored_options 'main.user_domains'\n")
    before_podkop = (root / 'etc/config/podkop').read_bytes()
    code, report = command('run', 'update')
    assert code == 0 and report['state'] == 'unchanged', report
    assert (root / 'etc/config/podkop').read_bytes() == before_podkop
    metadata = json.loads((root / 'tmp/podkop-config-auto-updater/fields.json').read_text())
    assert metadata == {'fields': ['main.user_domains']}
    checks += 1

    for scenario in ['apply', 'deletes_disabled', 'target_disabled', 'invalid_comment']:
        reset()
        write('/etc/init.d/podkop', '#!/bin/sh\nprintf "restart\\n" >> /fixtures/calls\nexit 0\n', True)
        updater = root / 'etc/config/podkop_config_auto_updater'
        updater.write_text(updater.read_text() + " option allow_deletes '" + ('0' if scenario == 'deletes_disabled' else '1') + "'\n")
        if scenario == 'target_disabled':
            updater.write_text(updater.read_text() + " list ignored_options 'notUnderSanctions.user_domains'\n")
        write('/etc/config/podkop', "config settings 'settings'\n option dns_server '192.0.2.1'\nconfig section 'main'\n option connection_type 'proxy'\n option user_domain_list_type 'text'\n option user_domains_text 'ai.example'\nconfig section 'manual'\n option connection_type 'vpn'\n")
        title = 'AI services' if scenario != 'invalid_comment' else 'invalid\nheading'
        write('/fixtures/feed.json', json.dumps({
            'schema_version': 3, 'revision': 'split-worker-test',
            'main': {'user_domains': [{'value': 'ai.example', 'delete': True}, 'ordinary.example']},
            'notUnderSanctions': {
                'connection_type': 'proxy', 'proxy_config_type': 'urltest',
                'urltest_proxy_links': ['vless://synthetic@example.test:443'],
                'user_domains': [{'comment': title}, 'ai.example']
            }, 'settings': {}
        }))
        before_podkop = (root / 'etc/config/podkop').read_bytes()
        code, report = command('run', 'update')
        if scenario == 'apply':
            assert code == 0 and report['state'] == 'applied', report
            applied = (root / 'etc/config/podkop').read_text()
            assert applied.index("'notUnderSanctions'") < applied.index("'main'") < applied.index("'manual'")
            assert '// AI services\nai.example' in applied and 'ordinary.example' in applied
            assert "option dns_server '192.0.2.1'" in applied
            assert (root / 'fixtures/calls').read_text() == 'restart\n'
            code, repeated = command('run', 'update')
            assert code == 0 and repeated['state'] == 'unchanged', repeated
            assert (root / 'fixtures/calls').read_text() == 'restart\n'
            metadata = json.loads((root / 'tmp/podkop-config-auto-updater/fields.json').read_text())
            assert 'notUnderSanctions.user_domains' in metadata['fields']
            assert 'AI services' not in json.dumps(metadata)
        else:
            expected = 'invalid_comment' if scenario == 'invalid_comment' else 'section_move_blocked'
            assert code == 1 and report['error'] == expected, (scenario, report)
            assert (root / 'etc/config/podkop').read_bytes() == before_podkop
            assert not (root / 'fixtures/calls').read_text()
        checks += 1

    for curl_exit, http_code, expected in [
        (5, '000', 'download_proxy_dns_failed'), (6, '000', 'download_dns_failed'),
        (7, '000', 'download_connect_failed'), (28, '000', 'download_timeout'),
        (35, '000', 'download_tls_failed'), (51, '000', 'download_certificate_failed'),
        (60, '000', 'download_certificate_failed'), (77, '000', 'download_ca_failed'),
        (63, '200', 'download_too_large'), (47, '302', 'download_http_redirect'),
        (22, '401', 'download_http_unauthorized'), (22, '403', 'download_http_forbidden'),
        (22, '404', 'download_http_not_found'), (22, '429', 'download_http_rate_limited'),
        (22, '503', 'download_http_server_error'), (0, '302', 'download_http_redirect'),
        (0, '204', 'download_http_error'), (23, '000', 'download_failed')
    ]:
        before = reset()
        code, report = command('run', 'test', {'MOCK_CURL_EXIT': str(curl_exit), 'MOCK_HTTP_CODE': http_code})
        assert code == 1 and report['error'] == expected, (curl_exit, http_code, report)
        assert report['downloaded'] is False and report['parsed'] is False
        assert snapshot() == before
        assert not list((root / 'tmp/podkop-config-auto-updater').glob('run.*'))
        checks += 1

    def prepare_release(target, format, current=None, variant='stable'):
        revision = '0.1.1' if target == 'self' else ('0.8.4' if variant == 'experimental' else '0.7.24')
        repository = 'hayOfLife/podkop-config-auto-updater' if target == 'self' else ('podkop-net/podkop-experimental' if variant == 'experimental' else 'itdoginfo/podkop')
        tag = 'v' + revision if target == 'self' or variant == 'experimental' else revision
        core = 'podkop-exp' if variant == 'experimental' else 'podkop'
        packages = ['luci-app-podkop-config-auto-updater'] if target == 'self' else [core, 'luci-app-' + core, 'luci-i18n-' + core + '-ru']
        write('/fixtures/repository', repository)
        assets = []
        for name in packages:
            old = current or ('0.1.0-r1' if target == 'self' else ('0.8.1-r1' if variant == 'experimental' else '0.7.23-r1'))
            if name == 'luci-i18n-podkop-exp-ru': old = '0.261024.70000'
            write('/fixtures/installed/' + name, old)
            expected = revision + '-r1'
            if target == 'self':
                filenames = [name + '-openwrt-' + ('25.12' if format == 'apk' else '24.10') + '.' + format]
            elif name == 'luci-i18n-' + core + '-ru':
                expected = revision
                filenames = [name + '-' + expected + '.' + format]
            else:
                expected = ('v' if format == 'ipk' else '') + expected
                suffixes = ['-x86-64', '-aarch64-cortex-a53'] if name == 'podkop-exp' else ['-all' if format == 'ipk' else '']
                filenames = [name + '-' + expected + suffix + '.' + format for suffix in suffixes]
            for filename in filenames:
                package_version = ('0.261025.79457' if format == 'ipk' else '0.261025.79453') if name == 'luci-i18n-podkop-exp-ru' else expected
                payload = name + '\n' + package_version + '\n'
                write('/fixtures/assets/' + filename, payload)
                assets.append({'name': filename, 'browser_download_url': f'https://github.com/{repository}/releases/download/{tag}/{filename}',
                               'digest': 'sha256:' + hashlib.sha256(payload.encode()).hexdigest(), 'size': len(payload)})
        release = {'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': assets}
        write('/fixtures/release.json', json.dumps(release))
        return release

    def wait_result():
        for attempt in range(100):
            code, report = command('software', 'status')
            temporary = [path for path in (root / 'tmp/podkop-config-auto-updater').glob('software.*') if path.is_dir()]
            if report['state'] != 'running' and not temporary: return report
            time.sleep(0.05)
        raise AssertionError('Background update did not complete')

    for format, target in [('ipk', 'self'), ('apk', 'self'), ('ipk', 'podkop'), ('apk', 'podkop')]:
        before = reset(format)
        prepare_release(target, format)
        code, started = command('software', target, {'MOCK_REPLACE_CODE': '1' if target == 'self' else '0'})
        assert code == 0 and started['state'] == 'running'
        report = wait_result()
        assert report['state'] == 'updated', (format, target, report)
        assert report['installed_version'] == report['available_version']
        if target == 'podkop': assert report['variant'] == 'stable', report
        assert snapshot() == before
        assert (root / f'tmp/podkop-config-auto-updater/before-software-{target}/podkop').is_file()
        assert not list((root / 'tmp/podkop-config-auto-updater').glob('software.*??????'))
        checks += 1

    for format in ['ipk', 'apk']:
        for case in ['equal', 'newer', 'comparison_error']:
            before = reset(format)
            prepare_release('podkop', format)
            installed = ('v' if format == 'ipk' else '') + ('9.9.9-r1' if case == 'newer' else '0.7.24-r1')
            write('/fixtures/installed/podkop', installed)
            # Отсутствующий LuCI не должен запускать установку при актуальном ядре Podkop
            (root / 'fixtures/installed/luci-app-podkop').unlink()
            command('software', 'podkop', {'MOCK_COMPARE_FAIL': '1' if case == 'comparison_error' else '0'})
            report = wait_result()
            assert report['state'] == ('error' if case == 'comparison_error' else 'up_to_date'), (format, case, report)
            if case == 'comparison_error': assert report['error'] == 'package_compare_failed', report
            assert report['installed_version'] == installed
            assert report['available_version'] == ('v' if format == 'ipk' else '') + '0.7.24-r1'
            assert (root / 'fixtures/calls').read_text() == '', (format, case)
            assert snapshot() == before
            checks += 1

    for format in ['ipk', 'apk']:
        for architecture, russian in [('aarch64_cortex-a53', True), ('aarch64_cortex-a53', False), ('x86_64', True)]:
            before = reset(format, architecture=architecture)
            prepare_release('podkop', format, variant='experimental')
            # При обновлении старого ядра LuCI должен добавиться, даже если его раньше не было
            (root / 'fixtures/installed/luci-app-podkop-exp').unlink()
            if not russian: (root / 'fixtures/installed/luci-i18n-podkop-exp-ru').unlink()
            code, started = command('software', 'podkop')
            assert code == 0 and started['state'] == 'running', started
            report = wait_result()
            expected = ('v' if format == 'ipk' else '') + '0.8.4-r1'
            assert report['state'] == 'updated' and report['variant'] == 'experimental', (format, architecture, russian, report)
            assert report['installed_version'] == report['available_version'] == expected, report
            installed = {path.name: path.read_text() for path in (root / 'fixtures/installed').iterdir()}
            wanted = {'podkop-exp': expected, 'luci-app-podkop-exp': expected}
            if russian: wanted['luci-i18n-podkop-exp-ru'] = '0.261025.79457' if format == 'ipk' else '0.261025.79453'
            assert installed == wanted, (format, architecture, russian, installed)
            urls = (root / 'fixtures/urls').read_text().splitlines()
            assert urls[0] == 'https://api.github.com/repos/podkop-net/podkop-experimental/releases/latest', urls
            core_url = 'https://github.com/podkop-net/podkop-experimental/releases/download/v0.8.4/podkop-exp-' + expected + '-' + architecture.replace('_', '-') + '.' + format
            assert core_url in urls, urls
            assert len(urls) == (4 if russian else 3), urls
            assert all(url.startswith('https://github.com/podkop-net/podkop-experimental/releases/download/v0.8.4/') for url in urls[1:]), urls
            assert (root / 'fixtures/calls').read_text() == ('opkg update\nopkg install\n' if format == 'ipk' else 'apk update\napk add\n')
            assert snapshot() == before
            checks += 1

        for case in ['equal', 'newer', 'comparison_error']:
            before = reset(format)
            prepare_release('podkop', format, variant='experimental')
            installed = ('v' if format == 'ipk' else '') + ('9.9.9-r1' if case == 'newer' else '0.8.4-r1')
            write('/fixtures/installed/podkop-exp', installed)
            (root / 'fixtures/installed/luci-app-podkop-exp').unlink()
            command('software', 'podkop', {'MOCK_COMPARE_FAIL': '1' if case == 'comparison_error' else '0'})
            report = wait_result()
            assert report['state'] == ('error' if case == 'comparison_error' else 'up_to_date'), (format, case, report)
            if case == 'comparison_error': assert report['error'] == 'package_compare_failed', report
            assert report['variant'] == 'experimental' and report['installed_version'] == installed, report
            assert report['available_version'] == ('v' if format == 'ipk' else '') + '0.8.4-r1', report
            assert not (root / 'fixtures/installed/luci-app-podkop-exp').exists()
            assert (root / 'fixtures/installed/luci-i18n-podkop-exp-ru').read_text() == '0.261024.70000'
            assert (root / 'fixtures/calls').read_text() == ''
            assert (root / 'fixtures/urls').read_text().splitlines() == ['https://api.github.com/repos/podkop-net/podkop-experimental/releases/latest']
            assert snapshot() == before
            checks += 1

        for architecture in [None, '', 'all', 'noarch', 'bad/arch', 'AARCH64', 'a' * 65]:
            before = reset(format, architecture=architecture)
            prepare_release('podkop', format, variant='experimental')
            command('software', 'podkop')
            report = wait_result()
            assert report['state'] == 'error' and report['error'] == 'unsupported_architecture', (format, architecture, report)
            assert report['variant'] == 'experimental', report
            assert (root / 'fixtures/calls').read_text() == '' and (root / 'fixtures/urls').read_text() == ''
            assert snapshot() == before
            checks += 1

        for case, expected in [('wrong_arch', 'missing_package'), ('duplicate_asset', 'missing_package'),
                               ('malformed_release', 'invalid_release'), ('wrong_repository', 'invalid_package'),
                               ('checksum', 'checksum_mismatch'), ('translation_missing', 'installed_version_mismatch')]:
            before = reset(format)
            release = prepare_release('podkop', format, variant='experimental')
            asset = next(asset for asset in release['assets'] if '-aarch64-cortex-a53.' in asset['name'])
            if case == 'wrong_arch': release['assets'].remove(asset)
            if case == 'duplicate_asset': release['assets'].append(dict(asset))
            if case == 'malformed_release': release['assets'] = 'not an array'
            if case == 'wrong_repository': asset['browser_download_url'] = asset['browser_download_url'].replace('podkop-net/podkop-experimental', 'itdoginfo/podkop')
            if case == 'checksum':
                payload = (root / 'fixtures/assets' / asset['name']).read_text()
                write('/fixtures/assets/' + asset['name'], 'X' + payload[1:])
            write('/fixtures/release.json', json.dumps(release))
            command('software', 'podkop', {'MOCK_MISSING_TRANSLATION': '1' if case == 'translation_missing' else '0'})
            report = wait_result()
            assert report['state'] == 'error' and report['error'] == expected, (format, case, report)
            assert report['variant'] == 'experimental', report
            if case != 'translation_missing': assert (root / 'fixtures/calls').read_text() == '', (format, case)
            assert 'itdoginfo/podkop' not in (root / 'fixtures/urls').read_text()
            assert not (root / 'fixtures/installed/podkop').exists()
            assert snapshot() == before
            checks += 1

        for case, expected in [('missing', 'podkop_package_missing'), ('conflict', 'podkop_variant_conflict')]:
            before = reset(format)
            if case == 'conflict':
                prepare_release('podkop', format, variant='experimental')
                write('/fixtures/installed/podkop', '0.7.24-r1')
            installed = {path.name: path.read_bytes() for path in (root / 'fixtures/installed').iterdir()}
            command('software', 'podkop')
            report = wait_result()
            assert report['state'] == 'error' and report['error'] == expected, (format, case, report)
            assert (root / 'fixtures/calls').read_text() == '' and (root / 'fixtures/urls').read_text() == ''
            assert {path.name: path.read_bytes() for path in (root / 'fixtures/installed').iterdir()} == installed
            assert snapshot() == before
            checks += 1

    for case, expected in [('checksum', 'checksum_mismatch'), ('pending', 'pending_changes'), ('old', 'podkop_migration_required'),
                           ('install', 'package_install_failed'), ('version', 'installed_version_mismatch'),
                           ('unchanged', None), ('downgrade', None)]:
        before = reset()
        target = 'podkop' if case == 'old' else 'self'
        release = prepare_release(target, 'apk', '0.6.0-r1' if case == 'old' else ('0.1.1-r1' if case == 'unchanged' else ('9.9.9-r1' if case == 'downgrade' else None)))
        if case == 'checksum': write('/fixtures/assets/' + release['assets'][0]['name'], 'tampered')
        if case == 'pending': write('/tmp/.uci/podkop', 'pending change')
        command('software', target, {'MOCK_INSTALL_FAIL': '1' if case == 'install' else '0', 'MOCK_VERSION_MISMATCH': '1' if case == 'version' else '0'})
        report = wait_result()
        assert report['state'] == ('error' if expected else 'up_to_date'), (case, report)
        if expected: assert report['error'] == expected, (case, report)
        if case in ['checksum', 'pending', 'old', 'unchanged', 'downgrade']:
            assert (root / 'fixtures/calls').read_text() == '', case
        assert snapshot() == before, case
        checks += 1

print(f'Router actions: {checks} isolated download, parse, no-write and package-update scenarios passed')
