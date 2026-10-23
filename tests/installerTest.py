"""Run the installer with fake downloads and package managers, without network access."""
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

installer = Path('install.sh').resolve()
passed = 0
for series, release, manager, extension in [('24.10', '24.10.7', 'opkg', 'ipk'), ('25.12', '25.12.5', 'apk', 'apk')]:
    with tempfile.TemporaryDirectory(prefix='podkop-installer-test-') as temporary:
        root = Path(temporary)
        binaries = root / 'bin'
        binaries.mkdir()
        (root / 'etc/init.d').mkdir(parents=True)
        (root / 'etc/config').mkdir()
        (root / 'etc/openwrt_release').write_text(f"DISTRIB_RELEASE='{release}'\n")
        (root / 'etc/init.d/podkop').write_text('#!/bin/sh\nexit 0\n')
        (root / 'etc/init.d/podkop').chmod(0o755)
        previous = "config settings 'main'\n option enabled '0'\n"
        (root / 'etc/config/podkop_config_auto_updater').write_text(previous)
        asset = f'luci-app-podkop-config-auto-updater-openwrt-{series}.{extension}'
        data = b'fixture package; not an installable archive'
        server = root / 'server'
        server.mkdir()
        (server / asset).write_bytes(data)
        (server / 'SHA256SUMS').write_text(f'{hashlib.sha256(data).hexdigest()}  {asset}\n')
        (server / 'latest').write_text(json.dumps({'tag_name': 'v0.1.0'}))
        scripts = {
            'id': '#!/bin/sh\nprintf 0\n',
            'curl': '''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
shutil.copyfile(Path(os.environ['CONFIG_UPDATER_TEST_ROOT']) / 'server' / args[-1].split('/')[-1], args[args.index('-o') + 1])
''',
            'jsonfilter': '''#!/usr/bin/env python3
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[sys.argv.index('-i') + 1]).read_text())['tag_name'])
''',
            manager: '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
with (Path(os.environ['CONFIG_UPDATER_TEST_ROOT']) / 'manager.log').open('a') as stream:
    stream.write(' '.join(sys.argv[1:]) + '\\n')
''',
        }
        for name, source in scripts.items():
            path = binaries / name
            path.write_text(source)
            path.chmod(0o755)
        environment = {**os.environ, 'CONFIG_UPDATER_TEST_ROOT': str(root), 'PATH': f'{binaries}:{os.environ["PATH"]}'}
        result = subprocess.run(['sh', str(installer)], env=environment, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        operations = (root / 'manager.log').read_text().splitlines()
        assert operations[0] == 'update'
        assert ('install ' if manager == 'opkg' else 'add --allow-untrusted ') in operations[1]
        assert operations[1].endswith(asset)
        assert (root / 'etc/config/podkop_config_auto_updater').read_text() == previous
        assert (root / 'tmp/podkop-config-auto-updater/before-install-config').read_text() == previous
        passed += 1
        (root / 'manager.log').unlink()
        (server / asset).write_bytes(b'corrupted')
        result = subprocess.run(['sh', str(installer)], env=environment, capture_output=True, text=True)
        assert result.returncode != 0 and not (root / 'manager.log').exists(), 'bad hash must block package manager'
        passed += 1
        (root / 'etc/openwrt_release').write_text("DISTRIB_RELEASE='SNAPSHOT'\n")
        result = subprocess.run(['sh', str(installer)], env=environment, capture_output=True, text=True)
        assert result.returncode != 0 and not (root / 'manager.log').exists(), 'unsupported release must stop'
        passed += 1
print(f'Installer: {passed} platform, preservation and rejection scenarios passed')
