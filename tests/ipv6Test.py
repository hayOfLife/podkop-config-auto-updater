"""Exercise IPv6 apply/release only against temporary fake proc files."""
import os
import subprocess
import tempfile
from pathlib import Path

script = Path('package/luci-app-podkop-config-auto-updater/root/usr/libexec/podkop-config-auto-updater/ipv6').resolve()
with tempfile.TemporaryDirectory(prefix='podkop-ipv6-test-') as temporary:
    root = Path(temporary)
    original = {'all': '0', 'default': '0', 'lo': '0', 'eth0': '1', 'br-lan': '0'}
    for name, value in original.items():
        path = root / 'proc/sys/net/ipv6/conf' / name / 'disable_ipv6'
        path.parent.mkdir(parents=True)
        path.write_text(value + '\n')
    (root / 'disabled').write_text('0')
    environment = {**os.environ, 'CONFIG_UPDATER_TEST_ROOT': str(root)}
    def run(command='apply'):
        subprocess.run(['sh', str(script), command], env=environment, check=True)
    def values():
        return {name: (root / 'proc/sys/net/ipv6/conf' / name / 'disable_ipv6').read_text().strip() for name in original}
    run()
    assert values() == original
    assert not (root / 'etc').exists(), 'default off must not touch system settings'
    (root / 'disabled').write_text('1')
    run()
    assert set(values().values()) == {'1'}
    state = root / 'etc/podkop-config-auto-updater/ipv6-restore'
    snapshot = state.read_bytes()
    run()
    assert state.read_bytes() == snapshot, 'restart must preserve original snapshot'
    (root / 'disabled').write_text('0')
    run()
    assert values() == original, 'restore per-interface overrides'
    assert not state.exists()
    (root / 'disabled').write_text('1')
    run()
    run('release')
    assert values() == original, 'uninstall restores IPv6'
    assert not (root / 'etc/sysctl.d/99-podkop-config-auto-updater-disable-ipv6.conf').exists()
print('IPv6: default off, disable, repeated apply, exact restore and uninstall passed')
