"""Build real tar archives and a user installation for the executable updater tests."""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile

root, fixtures = map(Path, sys.argv[1:3])
apps = sys.argv[3:]
home = Path.home()
root.mkdir(parents=True)
fixtures.mkdir(parents=True, exist_ok=True)
cli = b'''#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    q = json.loads(line)
    if 'id' not in q: continue
    result = {'protocolVersion': '2025-03-26', 'capabilities': {'tools': {}}} if q['method'] == 'initialize' else {'tools': [{'name': 'inspect'}]}
    print(json.dumps({'jsonrpc': '2.0', 'id': q['id'], 'result': result}), flush=True)
'''
records = []
for app in apps:
    appdir = root / app
    package = appdir / 'v0.1.0' / f'{app}-0.1.0-linux-x86_64'
    (package / 'bin').mkdir(parents=True)
    (appdir / 'source').mkdir()
    (appdir / 'source/user-work.txt').write_text('local changes must survive')
    (appdir / 'current').symlink_to(package.relative_to(appdir))
    for name in [app, app + '-cli']:
        file = package / 'bin' / name
        file.write_bytes(cli)
        file.chmod(0o755)
        link = home / '.local/bin' / name
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(appdir / 'current/bin' / name)
    info = {'app': app, 'version': 'v0.1.0', 'sha256': 'old', 'source': str(appdir / 'source')}
    (appdir / 'installation.json').write_text(json.dumps(info))
    (appdir / 'mcp-command.json').write_text(json.dumps({'command': str(home / '.local/bin' / (app + '-cli')), 'args': ['mcp']}))
    records.append(info)
    desktop_id = f'ai.storyteller.{app}.desktop'
    launcher = home / '.local/share/applications' / desktop_id
    launcher.parent.mkdir(parents=True, exist_ok=True)
    launcher.write_text('[Desktop Entry]\nName=Old\nType=Application\nExec=old\n')
    prefix = f'{app}-2.0.0-linux-x86_64'
    files = {f'bin/{app}': b'#!/bin/sh\nexit 0\n', f'bin/{app}-cli': cli,
             f'share/applications/{desktop_id}': f'[Desktop Entry]\nName={app}\nType=Application\nExec={app} %F\nTryExec={app}\nMimeType=application/pdf;\n'.encode(),
             f'share/mime/packages/ai.storyteller.{app}.xml': b'<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info"/>',
             f'share/icons/hicolor/48x48/apps/ai.storyteller.{app}.png': b'new-icon',
             f'share/metainfo/ai.storyteller.{app}.metainfo.xml': b'<component/>'}
    with tarfile.open(fixtures / (app + '.tar.gz'), 'w:gz') as archive:
        for name, content in files.items():
            info = tarfile.TarInfo(prefix + '/' + name)
            info.mode, info.size = (0o755 if name.startswith('bin/') else 0o644), len(content)
            archive.addfile(info, io.BytesIO(content))
    archive = fixtures / (app + '.tar.gz')
    name = prefix + '.tar.gz'
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    release = {'tag_name': 'v2.0.0', 'html_url': f'https://github.com/storytold/{app}/releases/tag/v2.0.0',
               'assets': [{'name': name, 'size': archive.stat().st_size, 'digest': 'sha256:' + digest,
                           'browser_download_url': f'https://github.com/storytold/{app}/releases/download/v2.0.0/{name}'}]}
    (fixtures / (app + '.json')).write_text(json.dumps(release))
    (fixtures / (app + '.sums')).write_text(digest + '  ' + name + '\n')
(root / 'installation.json').write_text(json.dumps(records))
config = home / '.config/mimeapps.list'
config.parent.mkdir(parents=True, exist_ok=True)
config.write_text('[Default Applications]\napplication/pdf=reader.desktop;\napplication/x-vectorcraft=custom.desktop;\n[Added Associations]\napplication/pdf=reader.desktop;\n')
