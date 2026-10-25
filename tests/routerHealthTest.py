"""Проверяет контроль OpenAI в chroot с подставными curl и локальным API без сетевых запросов"""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile

install = Path(sys.argv[1]).resolve()
source = Path('package/luci-app-podkop-config-auto-updater/root').resolve()
assert os.geteuid() == 0, 'Run isolated chroot tests with sudo'
checks = 0
environment = {**os.environ, 'PATH': '/bin', 'LD_LIBRARY_PATH': str(install / 'lib')}
group = 'notUnderSanctions-out'
automatic = 'notUnderSanctions-urltest-out'
first = 'notUnderSanctions-1-out'
second = 'notUnderSanctions-2-out'
third = 'notUnderSanctions-3-out'
state_file = 'tmp/podkop-config-auto-updater/health-state.json'

with tempfile.TemporaryDirectory(prefix='podkop-router-health-') as directory:
    root = Path(directory)
    copied = set()
    control_socket = None

    def copy_binary(path, destination=None):
        path = Path(path)
        target = root / (destination or str(path)).lstrip('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        if str(path) in copied:
            return
        copied.add(str(path))
        listing = subprocess.run(['ldd', str(path)], env=environment, text=True, capture_output=True)
        assert 'not found' not in listing.stdout, listing.stdout
        for library in re.findall(r'(?:=>\s+|^\s*)(/[^\s]+)', listing.stdout, re.MULTILINE):
            copy_binary(library)

    shutil.copytree(install, root / 'opt/health-tools')
    for name in ['sh', 'cat', 'sleep', 'sha256sum']:
        copy_binary(shutil.which(name), '/bin/' + name)
    for library in (install / 'lib').rglob('*.so*'):
        if library.is_file():
            copy_binary(library)
    copy_binary(install / 'bin/ucode', '/opt/health-tools/bin/ucode')
    (root / 'dev').mkdir()
    for name, minor in [('null', '3'), ('urandom', '9')]:
        subprocess.run(['mknod', str(root / 'dev' / name), 'c', '1', minor], check=True)
        os.chmod(root / 'dev' / name, 0o666)

    def write(path, content, executable=False):
        target = root / path.lstrip('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding='utf-8')
        target.chmod(0o755 if executable else 0o600)

    write('/bin/ucode', '#!/bin/sh\nexec /opt/health-tools/bin/ucode -L /opt/health-tools/lib/ucode "$@"\n', True)
    write('/bin/curl', '#!/bin/sh\nexec ucode -- /fixtures/curl.uc "$@"\n', True)
    write('/bin/podkop', '#!/bin/sh\n[ "$1" = show_sing_box_config ] || exit 2\ncat /etc/sing-box/config.json\n', True)

    fake_curl = r'''
import * as fs from 'fs';
let output, dataFile, port, url;
for (let i = 0; i < length(ARGV); i++) {
    if (ARGV[i] == '--output') output = ARGV[++i];
    else if (ARGV[i] == '--data-binary') dataFile = substr(ARGV[++i], 1);
    else if (ARGV[i] == '--local-port') port = ARGV[++i];
    else url = ARGV[i];
}
function load(path) { return json(fs.readfile(path)); }
function write(value) { fs.writefile(output, sprintf('%J', value)); }
function append(path, value) { fs.writefile(path, (fs.readfile(path) || '') + value); }
function flag(value) { return index(ARGV, value) >= 0; }
let choice = trim(fs.readfile('/fixtures/choice'));
if (url == 'http://localhost/status') { write({ running: true }); exit(0); }
if (url == 'http://localhost/facts') { write({ clash_api: '127.0.0.1:9090', clash_secret: 'private-api-fixture-secret' }); exit(0); }
if (url == 'http://127.0.0.1:9090/proxies') {
    if (getenv('MOCK_API_DOWN') == '1') exit(7);
    let proxies = load('/fixtures/proxies.json');
    proxies['notUnderSanctions-out'].now = choice;
    write({ proxies }); exit(0);
}
if (url == 'http://127.0.0.1:9090/proxies/notUnderSanctions-out') {
    if (getenv('MOCK_SELECT_FAIL') == 'before') exit(7);
    let selected = load(dataFile).name;
    fs.writefile('/fixtures/choice', selected);
    append('/fixtures/selected', selected + '\n');
    if (getenv('MOCK_SELECT_FAIL') == 'after') exit(7);
    fs.writefile(output, ''); exit(0);
}
if (url == 'http://127.0.0.1:9090/connections') {
    let active = fs.readfile('/fixtures/active');
    write({ connections: active ? [json(active)] : [] }); exit(0);
}
if (url != 'https://api.openai.com/v1/models') exit(99);
if (ARGV[0] != '--disable' || !flag('-4') || !flag('--noproxy') || !flag('*') || !flag('--http1.1') ||
    !flag('--proto') || !flag('=https') || !flag('--max-time') || !flag('20') || !flag('--max-filesize') ||
    !flag('16384') || !flag('--limit-rate') || !flag('128') || flag('--fail') || flag('--insecure') || flag('-k') ||
    flag('--location') || flag('-L') || flag('--header')) exit(98);
let reply = load('/fixtures/replies.json')[choice] || { status: 401, exit: 0,
    body: { error: { message: 'Missing bearer authentication', type: 'invalid_request_error', code: null } } };
let chains = [choice, 'notUnderSanctions-out'];
if (getenv('MOCK_ROUTE') == 'wrong') chains = ['main-1-out', 'main-out'];
let sourceIP = getenv('MOCK_ROUTE') == 'other_source' ? '192.168.2.99' : '192.168.2.1';
if (getenv('MOCK_ROUTE') != 'missing') fs.writefile('/fixtures/active', sprintf('%J', {
    metadata: { sourceIP, sourcePort: getenv('MOCK_NUMERIC_PORTS') == '1' ? int(port) : port,
        host: 'api.openai.com', destinationPort: getenv('MOCK_NUMERIC_PORTS') == '1' ? 443 : '443' }, chains
}));
append('/fixtures/probes', choice + '\n');
fs.writefile(output, type(reply.body) == 'string' ? reply.body : sprintf('%J', reply.body));
system(['sleep', '0.8']);
fs.unlink('/fixtures/active');
if (getenv('MOCK_EXTERNAL_AFTER')) fs.writefile('/fixtures/choice', getenv('MOCK_EXTERNAL_AFTER'));
print(sprintf('%03d\n198.18.0.42\n192.168.2.1\n', reply.status));
exit(reply.exit);
'''

    def reset(backend='stable', enabled='1', check='1', configured=True):
        global control_socket
        if control_socket:
            control_socket.close()
            control_socket = None
        for name in ['etc', 'tmp', 'var', 'fixtures', 'usr']:
            shutil.rmtree(root / name, ignore_errors=True)
        shutil.copytree(source, root, dirs_exist_ok=True)
        # Пакет устанавливает этот helper через INSTALL_BIN
        (root / 'usr/libexec/podkop-config-auto-updater/health-io').chmod(0o755)
        write('/etc/config/podkop_config_auto_updater', "config settings 'main'\n option enabled '" + enabled + "'\n option openai_check_enabled '" + check + "'\n")
        config = "config settings 'settings'\n option config_path '/etc/sing-box/config.json'\nconfig section 'main'\n option connection_type 'proxy'\n"
        if configured:
            config += "config section 'notUnderSanctions'\n option connection_type 'proxy'\n option proxy_config_type 'urltest'\n list urltest_proxy_links 'vless://synthetic@example.test:443'\n"
        write('/etc/config/podkop', config)
        runtime = json.dumps({'experimental': {'clash_api': {'external_controller': '127.0.0.1:9090', 'secret': 'private-api-fixture-secret'}}})
        write('/etc/sing-box/config.json', runtime)
        write('/fixtures/curl.uc', fake_curl)
        write('/fixtures/choice', automatic)
        write('/fixtures/probes', '')
        write('/fixtures/selected', '')
        write('/fixtures/replies.json', '{}')
        proxies = {
            group: {'type': 'Selector', 'now': automatic, 'all': [automatic, first, second, third, 'DIRECT', 'notUnderSanctions-block']},
            automatic: {'type': 'URLTest', 'now': first, 'all': [first, second, third]},
            first: {'type': 'VLESS'}, second: {'type': 'VLESS'}, third: {'type': 'Trojan'},
            'notUnderSanctions-block': {'type': 'Reject'}, 'DIRECT': {'type': 'Direct'},
            'main-out': {'type': 'Selector', 'now': 'main-1-out', 'all': ['main-1-out']}, 'main-1-out': {'type': 'VLESS'}
        }
        write('/fixtures/proxies.json', json.dumps(proxies))
        (root / 'tmp/podkop-config-auto-updater').mkdir(parents=True)
        if backend == 'experimental':
            write('/var/run/podkop/config.json', runtime)
            control_socket = socket.socket(socket.AF_UNIX)
            control_socket.bind(str(root / 'var/run/podkop/ctl.sock'))
        preflight = subprocess.run([shutil.which('chroot'), str(root), '/bin/ucode', '-c', '-o', '/fixtures/curl.ucb',
                                    '/fixtures/curl.uc'],
                                   env={**environment, 'LD_LIBRARY_PATH': '/opt/health-tools/lib'},
                                   capture_output=True, text=True, timeout=5)
        assert preflight.returncode == 0, ('curl fixture compile failed', preflight.returncode, preflight.stderr)
        # GNU getopt разбирает флаги после имени скрипта, поэтому обёртка должна передать разделитель --
        smoke = subprocess.run([shutil.which('chroot'), str(root), '/bin/curl', '--disable', '--silent', '--output',
                                '/fixtures/smoke.json', 'http://127.0.0.1:9090/proxies'],
                               env={**environment, 'LD_LIBRARY_PATH': '/opt/health-tools/lib'},
                               capture_output=True, text=True, timeout=5)
        assert smoke.returncode == 0, ('curl fixture argument forwarding failed', smoke.returncode)
        assert group in json.loads((root / 'fixtures/smoke.json').read_text())['proxies']
        return (root / 'etc/config/podkop').read_bytes()

    def command(mode='tick', extra=None):
        work = root / 'tmp/podkop-config-auto-updater/work'
        shutil.rmtree(work, ignore_errors=True)
        work.mkdir(mode=0o700)
        result = subprocess.run([shutil.which('chroot'), str(root), '/bin/ucode', '-L', '/usr/share/podkop-config-auto-updater',
                                 '/usr/share/podkop-config-auto-updater/health-worker.uc', mode,
                                 '/tmp/podkop-config-auto-updater/work'],
                                env={**environment, 'LD_LIBRARY_PATH': '/opt/health-tools/lib', **(extra or {})},
                                capture_output=True, text=True, timeout=35)
        assert 'private-api-fixture-secret' not in result.stdout + result.stderr, result
        assert 'vless://' not in result.stdout + result.stderr, result
        assert not result.stderr, result.stderr
        report = json.loads((root / 'tmp/podkop-config-auto-updater/health.json').read_text())
        assert 'private-api-fixture-secret' not in json.dumps(report)
        assert 'body' not in report and 'proxies' not in report
        if report.get('error') in ['api_unavailable', 'invalid_runtime', 'io_failed']:
            diagnostics = {'work_files': {path.name: path.stat().st_size for path in work.iterdir() if path.is_file()},
                           'helper_exits': {}}
            for action in ['hash', 'discover', 'proxies']:
                diagnostic = subprocess.run([shutil.which('chroot'), str(root),
                                             '/usr/libexec/podkop-config-auto-updater/health-io', action,
                                             '/tmp/podkop-config-auto-updater/work'],
                                            env={**environment, 'LD_LIBRARY_PATH': '/opt/health-tools/lib', **(extra or {})},
                                            capture_output=True, text=True, timeout=10)
                diagnostics['helper_exits'][action] = diagnostic.returncode
            print('Synthetic health fixture diagnostics: ' + json.dumps(diagnostics), file=sys.stderr)
        return result.returncode, report

    def state():
        return json.loads((root / state_file).read_text())

    def due():
        data = state()
        data['next_check'] = 0
        write('/' + state_file, json.dumps(data))

    def replies(values):
        write('/fixtures/replies.json', json.dumps(values))

    def reply(status, body=None, exit_code=0):
        return {'status': status, 'exit': exit_code, 'body': body or {'error': {'message': 'Fixture response'}}}

    for backend in ['stable', 'experimental']:
        original = reset(backend)
        code, report = command(extra={'MOCK_NUMERIC_PORTS': '1'})
        assert code == 0 and report['state'] == 'healthy' and report['selected'] == first, report
        assert state()['previous'] == automatic and state()['owned'] == first
        assert (root / 'etc/config/podkop').read_bytes() == original
        assert (root / 'fixtures/selected').read_text().splitlines() == [first]
        before = (root / 'fixtures/probes').read_text()
        command()
        assert (root / 'fixtures/probes').read_text() == before
        code, report = command('release')
        assert code == 0 and report['state'] == 'disabled'
        assert (root / 'fixtures/choice').read_text() == automatic
        assert state()['owned'] is None
        checks += 1

    for options, expected in [({'enabled': '0'}, 'disabled'), ({'check': '0'}, 'disabled'), ({'configured': False}, 'not_configured')]:
        reset(**options)
        code, report = command(extra={'MOCK_API_DOWN': '1'})
        assert code == 0 and report['state'] == expected, report
        assert not (root / 'fixtures/probes').read_text() and not (root / 'fixtures/selected').read_text()
        checks += 1

    for route in ['missing', 'wrong', 'other_source']:
        reset()
        replies({first: reply(403, {'error': {'code': 'unsupported_country_region_territory'}})})
        code, report = command(extra={'MOCK_ROUTE': route})
        assert code == 0 and report['state'] == 'route_unconfirmed', (route, report)
        assert state()['cooldowns'] == {} and (root / 'fixtures/choice').read_text() == automatic
        assert state()['owned'] is None
        assert len((root / 'fixtures/probes').read_text().splitlines()) == 1
        checks += 1

    reset()
    replies({first: reply(403, {'error': {'code': 'unsupported_country_region_territory'}})})
    code, report = command()
    assert code == 0 and report['state'] == 'healthy' and report['selected'] == second, report
    assert state()['cooldowns'][first] > report['checked_at'] + 3500
    assert (root / 'fixtures/probes').read_text().splitlines() == [first, second]
    assert (root / 'fixtures/selected').read_text().splitlines() == [first, second]
    checks += 1

    for status, expected, exit_code in [(429, 'rate_limited', 0), (503, 'service_error', 0), (403, 'unknown', 0),
                                         (429, 'rate_limited', 28), (503, 'service_error', 28), (403, 'unknown', 28),
                                         (429, 'rate_limited', 63), (503, 'service_error', 63), (403, 'unknown', 63)]:
        reset()
        replies({first: reply(status, exit_code=exit_code)})
        code, report = command()
        assert code == 0 and report['state'] == expected, (status, exit_code, report)
        assert state()['cooldowns'] == {}
        delay = 600 if status == 429 else 180
        assert report['next_check'] - report['checked_at'] == delay
        assert (root / 'fixtures/probes').read_text().splitlines() == [first]
        checks += 1

    reset()
    replies({first: reply(0, exit_code=28)})
    for failure in [1, 2]:
        code, report = command()
        assert code == 0 and report['state'] == 'network_error' and report['failures'] == failure, report
        assert report['next_check'] - report['checked_at'] == 30
        due()
    code, report = command()
    assert code == 0 and report['state'] == 'healthy' and report['selected'] == second, report
    assert state()['cooldowns'][first] > report['checked_at'] + 290
    checks += 1

    reset()
    blocked = reply(403, {'error': {'code': 'unsupported_country_region_territory'}})
    replies({first: blocked, second: blocked, third: blocked})
    code, report = command()
    assert code == 0 and report['state'] == 'region_blocked', report
    assert (root / 'fixtures/probes').read_text().splitlines() == [first, second]
    due()
    code, report = command()
    assert code == 0 and report['state'] == 'no_eligible_nodes', report
    assert (root / 'fixtures/choice').read_text() == third
    assert (root / 'fixtures/probes').read_text().splitlines() == [first, second, third]
    checks += 1

    reset()
    command()
    due()
    write('/fixtures/choice', second)
    code, report = command()
    assert code == 0 and report['state'] == 'selection_changed', report
    assert (root / 'fixtures/choice').read_text() == second and state()['owned'] is None
    command('release')
    assert (root / 'fixtures/choice').read_text() == second
    checks += 1

    reset()
    code, report = command(extra={'MOCK_EXTERNAL_AFTER': second})
    assert code == 0 and report['state'] == 'selection_changed', report
    assert state()['cooldowns'] == {} and (root / 'fixtures/choice').read_text() == second
    checks += 1

    for failure in ['before', 'after']:
        reset()
        code, report = command(extra={'MOCK_SELECT_FAIL': failure})
        assert code == 1 and report['state'] == 'error' and report['error'] == 'selection_failed', report
        assert state()['pending']['to'] == first
        code, report = command('release')
        assert code == 0 and report['state'] == 'disabled', report
        assert (root / 'fixtures/choice').read_text() == automatic
        checks += 1

    reset()
    command()
    data = state()
    data['cooldowns'][first] = 4000000000
    write('/' + state_file, json.dumps(data))
    runtime_file = root / 'etc/sing-box/config.json'
    changed = json.loads(runtime_file.read_text())
    changed['outbounds'] = [{'tag': first, 'server': 'new-synthetic.example'}]
    runtime_file.write_text(json.dumps(changed))
    code, report = command()
    assert code == 0 and report['state'] == 'healthy', report
    assert state()['cooldowns'] == {} and state()['previous'] == automatic
    command('release')
    assert (root / 'fixtures/choice').read_text() == automatic
    checks += 1

    reset()
    command()
    proxies = json.loads((root / 'fixtures/proxies.json').read_text())
    del proxies[group]
    write('/fixtures/proxies.json', json.dumps(proxies))
    code, report = command('release')
    assert code == 0 and report['state'] == 'disabled' and state()['owned'] is None, report
    checks += 1

    if control_socket:
        control_socket.close()

print(f'{checks} router health scenarios passed')
