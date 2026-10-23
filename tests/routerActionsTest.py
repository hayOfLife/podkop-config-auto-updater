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
 */releases/latest) cp /fixtures/release.json "$out" ;;
 */releases/download/*) cp "/fixtures/assets/${url##*/}" "$out" ;;
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
  if [ "$1" = "$3" ]; then comparison='='; elif [ "$3" = 9.9.9-r1 ]; then comparison='<'; else comparison='>'; fi
  [ "$2" = "$comparison" ] ;;
 version)
  [ "${MOCK_COMPARE_FAIL:-0}" = 0 ] || exit 2
  if [ "$2" = "$3" ]; then printf '='; elif [ "$3" = 9.9.9-r1 ]; then printf '<'; else printf '>'; fi ;;
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

    def reset(format='apk', token='demo_token'):
        for name in ['etc', 'tmp', 'fixtures']:
            shutil.rmtree(root / name, ignore_errors=True)
        shutil.copytree(source, root, dirs_exist_ok=True)
        write('/etc/openwrt_release', "DISTRIB_RELEASE='" + ('25.12.6' if format == 'apk' else '24.10.7') + "'\n")
        write('/etc/config/podkop_config_auto_updater', "config settings 'main'\n option enabled '0'\n option config_url 'https://github.com/example/config/blob/main/config/main.json'\n option github_token '" + token + "'\n")
        write('/etc/config/podkop', "config section 'main'\n option connection_type 'proxy'\n")
        write('/etc/podkop-config-auto-updater/schedule.json', '{"next":1900000000}')
        write('/etc/podkop-config-auto-updater/previous-podkop', 'previous configuration')
        write('/tmp/podkop-config-auto-updater/status.json', '{"state":"unchanged"}')
        write('/fixtures/feed.json', json.dumps({'schema_version': 2, 'revision': 'demo', 'main': {'user_domains': ['example.com']}, 'settings': {}}))
        write('/fixtures/calls', '')
        (root / 'fixtures/installed').mkdir()
        return snapshot()

    def snapshot():
        paths = [root / 'etc/config/podkop', root / 'etc/config/podkop_config_auto_updater',
                 root / 'etc/podkop-config-auto-updater/schedule.json', root / 'etc/podkop-config-auto-updater/previous-podkop',
                 root / 'tmp/podkop-config-auto-updater/status.json']
        return {str(path): (path.read_bytes(), path.stat().st_mode) for path in paths}

    def command(program, action, extra=None):
        result = subprocess.run([chroot, str(root), '/usr/libexec/podkop-config-auto-updater/' + program, action],
                                env={**environment, **(extra or {})}, capture_output=True, text=True, timeout=20)
        assert 'demo_token' not in result.stdout + result.stderr
        assert result.stdout, (result.returncode, result.stderr)
        return result.returncode, json.loads(result.stdout)

    for case in ['valid', 'network', 'json', 'schema', 'token', 'busy']:
        before = reset(token='' if case == 'token' else 'demo_token')
        write('/tmp/.uci/podkop', 'pending manual settings')
        if case == 'json': write('/fixtures/feed.json', '{broken JSON')
        if case == 'schema': write('/fixtures/feed.json', '{"schema_version":99}')
        lock = None
        if case == 'busy':
            lock = (root / 'tmp/podkop-config-auto-updater/lock').open('w')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, report = command('run', 'test', {'MOCK_DOWNLOAD_FAIL': '1' if case == 'network' else '0'})
        if lock: lock.close()
        assert code == (0 if case == 'valid' else 1), (case, report)
        assert report['state'] == ('tested' if case == 'valid' else 'error'), (case, report)
        if case != 'busy':
            assert report['downloaded'] == (case in ['valid', 'json', 'schema']), (case, report)
            assert report['parsed'] == (case in ['valid', 'schema']), (case, report)
            assert report['valid'] == (case == 'valid'), (case, report)
        assert snapshot() == before, case
        assert not list((root / 'tmp/podkop-config-auto-updater').glob('run.*'))
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

    def prepare_release(target, format, current=None):
        revision = '0.1.1' if target == 'self' else '0.7.24'
        repository = 'hayOfLife/podkop-config-auto-updater' if target == 'self' else 'itdoginfo/podkop'
        tag = 'v' + revision if target == 'self' else revision
        packages = ['luci-app-podkop-config-auto-updater'] if target == 'self' else ['podkop', 'luci-app-podkop', 'luci-i18n-podkop-ru']
        assets = []
        for name in packages:
            old = current or ('0.1.0-r1' if target == 'self' else '0.7.23-r1')
            write('/fixtures/installed/' + name, old)
            expected = revision + '-r1'
            if target == 'self':
                filename = name + '-openwrt-' + ('25.12' if format == 'apk' else '24.10') + '.' + format
            elif name == 'luci-i18n-podkop-ru':
                expected = revision
                filename = name + '-' + expected + '.' + format
            else:
                expected = ('v' if format == 'ipk' else '') + expected
                filename = name + '-' + expected + ('-all' if format == 'ipk' else '') + '.' + format
            payload = name + '\n' + expected + '\n'
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
        assert snapshot() == before
        assert (root / f'etc/podkop-config-auto-updater/before-software-{target}/podkop').is_file()
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
