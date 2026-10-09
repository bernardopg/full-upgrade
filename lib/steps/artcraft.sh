#!/usr/bin/env bash
# Releases locais da suíte Artcraft; o motor Python também é embutido no standalone.
# shellcheck shell=bash
# shellcheck disable=SC2034 # STEP_REASON é consumido pelo framework.

artcraft_installed() {
  [[ -r "${ARTCRAFT_DIR:-$HOME/development/artcraft}/installation.json" ]]
}

artcraft_run() {
  python3 - "${ARTCRAFT_DIR:-$HOME/development/artcraft}" "$1" <<'PY'
import asyncio
import configparser
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

APPS = ('photocraft', 'vectorcraft', 'filmcraft', 'lightcraft', 'pdfcraft', 'effectcraft', 'designcraft')
NATIVE = {'photocraft': ['pcraft'], 'vectorcraft': ['vectorcraft', 'drawcraft', 'vctemplate'],
          'filmcraft': ['fcproj'], 'effectcraft': ['ecproj'], 'designcraft': ['designcraft']}
root, mode = Path(sys.argv[1]).expanduser().absolute(), sys.argv[2]
home = Path.home()
data = Path(os.environ.get('XDG_DATA_HOME') or home / '.local/share')
config = Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')

def version(tag):
    if not isinstance(tag, str) or not re.fullmatch(r'v?\d+\.\d+\.\d+', tag):
        raise ValueError('versão estável inválida')
    return tuple(map(int, tag.lstrip('v').split('.')))

def fetch(url):
    headers = {'User-Agent': 'full-upgrade-artcraft', 'Accept': 'application/vnd.github+json'}
    token = os.environ.get('GITHUB_TOKEN') or os.environ.get('GH_TOKEN')
    if token and url.startswith('https://api.github.com/'):
        headers['Authorization'] = 'Bearer ' + token
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30)

def latest(app):
    with fetch(f'https://api.github.com/repos/storytold/{app}/releases/latest') as response:
        release = json.load(response)
    version(release['tag_name'])
    if release.get('draft') or release.get('prerelease'):
        raise ValueError('release não estável')
    return release

async def smoke(cli, args):
    with tempfile.TemporaryFile() as errors:
        process = await asyncio.create_subprocess_exec(str(cli), *args, stdin=asyncio.subprocess.PIPE,
                                                      stdout=asyncio.subprocess.PIPE, stderr=errors)
        async def request(identifier, method, params):
            process.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': identifier,
                                            'method': method, 'params': params}) + '\n').encode())
            await process.stdin.drain()
            while True:
                line = await asyncio.wait_for(process.stdout.readline(), 30)
                if not line:
                    raise ValueError('CLI encerrou antes da resposta MCP')
                result = json.loads(line)
                if result.get('id') == identifier:
                    if 'error' in result or 'result' not in result:
                        raise ValueError('resposta MCP inválida')
                    return result['result']
        try:
            await request(1, 'initialize', {'protocolVersion': '2025-03-26', 'capabilities': {},
                                          'clientInfo': {'name': 'full-upgrade', 'version': '1'}})
            process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            listing = await request(2, 'tools/list', {})
            if not listing.get('tools'):
                raise ValueError('servidor MCP sem ferramentas')
        finally:
            if process.returncode is None:
                process.terminate()
            try:
                await asyncio.wait_for(process.wait(), 5)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()

def cache_refresh():
    for command, directory in [('update-mime-database', data / 'mime'),
                               ('update-desktop-database', data / 'applications')]:
        subprocess.run([command, str(directory)], check=True, timeout=60, stdout=subprocess.DEVNULL)
    if shutil.which('gtk-update-icon-cache'):
        subprocess.run(['gtk-update-icon-cache', '-f', '-t', str(data / 'icons/hicolor')],
                       check=True, timeout=60, stdout=subprocess.DEVNULL)

def install(app, old, release, records):
    arch = {'x86_64': 'x86_64', 'aarch64': 'aarch64', 'arm64': 'aarch64'}.get(platform.machine())
    if not arch:
        raise ValueError('arquitetura Linux não suportada')
    tag = release['tag_name']
    name = f'{app}-{tag.lstrip("v")}-linux-{arch}.tar.gz'
    asset = next(a for a in release['assets'] if a['name'] == name)
    base = f'https://github.com/storytold/{app}/releases/download/{tag}/'
    if asset['browser_download_url'] != base + name:
        raise ValueError('URL do pacote não pertence à release oficial')
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        with fetch(base + 'SHA256SUMS.txt') as response:
            sums = response.read().decode().splitlines()
        hashes = [line.split()[0] for line in sums if len(line.split()) == 2
                  and line.split()[1].lstrip('*') == name]
        if len(hashes) != 1 or not re.fullmatch(r'[0-9a-f]{64}', hashes[0]):
            raise ValueError('SHA-256 oficial indisponível')
        digest = 'sha256:' + hashes[0]
    appdir = root / app
    with tempfile.TemporaryDirectory(prefix='.artcraft-', dir=appdir) as temporary:
        stage = Path(temporary)
        archive = stage / name
        checksum = hashlib.sha256()
        with fetch(base + name) as response, archive.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                checksum.update(chunk)
        if digest != 'sha256:' + checksum.hexdigest() or archive.stat().st_size != asset['size']:
            raise ValueError('tamanho ou SHA-256 do download não confere')
        with tarfile.open(archive) as bundle:
            bundle.extractall(stage, filter='data')
        package = stage / name.removesuffix('.tar.gz')
        for binary in [app, app + '-cli']:
            path = package / 'bin' / binary
            if not path.is_file() or not os.access(path, os.X_OK) or not path.resolve().is_relative_to(stage):
                raise ValueError('binário ausente, inválido ou fora do pacote')
        with (package / 'bin' / app).open('rb') as gui:
            elf = gui.read(4) == b'\x7fELF'
        if elf and shutil.which('ldd'):
            libraries = subprocess.run(['ldd', str(package / 'bin' / app)], capture_output=True,
                                       text=True, timeout=30)
            if libraries.returncode or 'not found' in libraries.stdout:
                raise ValueError('bibliotecas da GUI ausentes: ' + libraries.stdout.strip())
        command_file = appdir / 'mcp-command.json'
        args = json.loads(command_file.read_text())['args'] if command_file.exists() else ['mcp']
        if not isinstance(args, list) or not args or args[0] != 'mcp' or not all(isinstance(a, str) for a in args):
            raise ValueError('argumentos MCP inválidos')
        asyncio.run(smoke(package / 'bin' / (app + '-cli'), args))
        source = stage / 'source'
        subprocess.run(['git', 'clone', '--depth', '1', '--branch', tag,
                        f'https://github.com/storytold/{app}.git', str(source)],
                       check=True, timeout=180, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                       env={**os.environ, 'GIT_TERMINAL_PROMPT': '0'})
        commit = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
        desktop_id = f'ai.storyteller.{app}.desktop'
        desktop = (package / 'share/applications' / desktop_id).read_text()
        desktop = desktop.replace(f'Exec={app} ', f'Exec={home}/.local/bin/{app} ')
        desktop = desktop.replace(f'TryExec={app}', f'TryExec={home}/.local/bin/{app}')
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read_string(desktop)
        types = parser['Desktop Entry'].get('MimeType', '').strip(';').split(';')
        native = 'application/x-' + app
        types = list(dict.fromkeys([t for t in types if t] + ([native] if app in NATIVE else [])))
        desktop = '\n'.join(line for line in desktop.splitlines() if not line.startswith('MimeType=')) + '\n'
        if types:
            desktop += 'MimeType=' + ';'.join(types) + ';\n'
        check_desktop = stage / desktop_id
        check_desktop.write_text(desktop)
        subprocess.run(['desktop-file-validate', str(check_desktop)], check=True, timeout=15)
        mimepath = config / 'mimeapps.list'
        associations = configparser.ConfigParser(interpolation=None, strict=False)
        associations.optionxform = str
        associations.read(mimepath)
        for section in ['Default Applications', 'Added Associations']:
            if not associations.has_section(section):
                associations.add_section(section)
        for mime in types:
            previous = associations['Added Associations'].get(mime, '').strip(';').split(';')
            associations['Added Associations'][mime] = ';'.join(dict.fromkeys([t for t in previous if t] + [desktop_id])) + ';'
        if app in NATIVE:
            associations['Default Applications'].setdefault(native, desktop_id + ';')
        import io
        mimelist = io.StringIO()
        associations.write(mimelist, space_around_delimiters=False)
        namespace = 'http://www.freedesktop.org/standards/shared-mime-info'
        ET.register_namespace('', namespace)
        mime_xml = ET.Element('{' + namespace + '}mime-info')
        if app in NATIVE:
            item = ET.SubElement(mime_xml, '{' + namespace + '}mime-type', {'type': native})
            ET.SubElement(item, '{' + namespace + '}comment').text = app + ' project'
            ET.SubElement(item, '{' + namespace + '}sub-class-of', {'type': 'application/zip' if app == 'photocraft' else 'application/json'})
            for extension in NATIVE[app]:
                ET.SubElement(item, '{' + namespace + '}glob', {'pattern': '*.' + extension})
        # O clone original e suas alterações locais nunca são substituídos.
        releases = appdir / 'releases'
        releases.mkdir(exist_ok=True)
        destination = releases / (tag + '-' + stage.name.removeprefix('.artcraft-'))
        stage.rename(destination)
        package = destination / package.name
        backup = appdir / 'backups' / destination.name
        backup.mkdir(parents=True, mode=0o700)
        changes = []
        def write(path, content=None, link=None):
            if path.is_symlink():
                previous = ('link', os.readlink(path))
            elif path.exists():
                if not path.is_file():
                    raise ValueError(f'destino não é arquivo: {path}')
                saved = backup / str(len(changes))
                shutil.copy2(path, saved)
                saved.chmod(0o600)
                previous = ('file', saved, stat.S_IMODE(path.stat().st_mode))
            else:
                previous = ('absent',)
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary_name = tempfile.mkstemp(prefix='.artcraft-', dir=path.parent)
            os.close(descriptor)
            temporary_path = Path(temporary_name)
            try:
                if link is not None:
                    temporary_path.unlink()
                    temporary_path.symlink_to(link)
                else:
                    with temporary_path.open('wb') as output:
                        output.write(content)
                    temporary_path.chmod(previous[2] if previous[0] == 'file' else 0o644)
                temporary_path.replace(path)
                changes.append((path, previous))
            finally:
                temporary_path.unlink(missing_ok=True)
        record = {**old, 'version': tag, 'sha256': checksum.hexdigest(), 'archive': str(destination / name),
                  'release_url': release['html_url'], 'source': str(destination / 'source'), 'commit': commit,
                  'previous_package': str((appdir / 'current').resolve())}
        def encoded(value):
            return (json.dumps(value, indent=2, ensure_ascii=False) + '\n').encode()
        try:
            write(data / 'applications' / desktop_id, desktop.encode())
            for directory in ['icons', 'mime/packages', 'metainfo']:
                for file in (package / 'share' / directory).rglob('*'):
                    if file.is_file():
                        if not file.name.startswith('ai.storyteller.' + app + '.'):
                            raise ValueError('asset fora do namespace do aplicativo')
                        write(data / file.relative_to(package / 'share'), file.read_bytes())
            write(data / 'mime/packages' / ('full-upgrade-' + app + '.xml'),
                  ET.tostring(mime_xml, encoding='utf-8', xml_declaration=True))
            write(mimepath, mimelist.getvalue().encode())
            write(appdir / 'current', link=os.path.relpath(package, appdir))
            write(appdir / 'source-current', link=os.path.relpath(destination / 'source', appdir))
            write(appdir / 'installation.json', encoded(record))
            write(root / 'installation.json', encoded([record if r['app'] == app else r for r in records]))
            cache_refresh()
            (backup / 'rollback.json').write_bytes(encoded([
                {'path': str(p), 'type': v[0], 'saved': str(v[1]) if len(v) > 1 else None,
                 'mode': v[2] if len(v) > 2 else None} for p, v in changes]))
        except BaseException:
            for path, previous in reversed(changes):
                path.unlink(missing_ok=True)
                if previous[0] == 'link':
                    path.symlink_to(previous[1])
                elif previous[0] == 'file':
                    shutil.copyfile(previous[1], path)
                    path.chmod(previous[2])
            with contextlib.suppress(Exception):
                cache_refresh()
            raise
        return record

def main():
    records = json.loads((root / 'installation.json').read_text())
    if not isinstance(records, list):
        raise ValueError('inventário Artcraft inválido')
    installed = []
    for app in APPS:
        info = root / app / 'installation.json'
        if info.exists():
            record = json.loads(info.read_text())
            if record.get('app') != app or sum(r.get('app') == app for r in records) != 1:
                raise ValueError('inventários Artcraft divergentes')
            version(record['version'])
            installed.append((app, record))
    if mode == 'doctor':
        for app, record in installed:
            package = (root / app / 'current').resolve(strict=True)
            for name in [app, app + '-cli']:
                if not os.access(package / 'bin' / name, os.X_OK) or (home / '.local/bin' / name).resolve() != package / 'bin' / name:
                    raise ValueError(f'{app}: binário ou symlink inválido')
            if not (data / 'applications' / f'ai.storyteller.{app}.desktop').is_file():
                raise ValueError(f'{app}: launcher ausente')
            print(f'  {app}: {record["version"]}, GUI/CLI/launcher presentes.', flush=True)
        return 0
    def probe(item):
        app, record = item
        try:
            return app, record, latest(app), None
        except Exception as error:
            return app, record, None, str(error)
    failed, updated = 0, 0
    for app, old, release, error in ThreadPoolExecutor(max_workers=7).map(probe, installed):
        if error:
            print(f'  {app}: consulta indisponível ({error}).', file=sys.stderr, flush=True)
            failed += 1
            continue
        if version(release['tag_name']) <= version(old['version']):
            if mode != 'check':
                print(f'  {app}: atualizado ({old["version"]}).', flush=True)
            continue
        if mode == 'check':
            print(f'{app} {old["version"]} -> {release["tag_name"]}', flush=True)
            continue
        try:
            print(f'  {app}: {old["version"]} -> {release["tag_name"]}; verificando download e MCP.', flush=True)
            new = install(app, old, release, records)
            records = [new if r['app'] == app else r for r in records]
            updated += 1
            print(f'  {app}: instalado; versão anterior e clone original preservados.', flush=True)
        except Exception as error:
            failed += 1
            print(f'  {app}: atualização recusada; versão anterior preservada ({error}).', file=sys.stderr, flush=True)
            if isinstance(error, subprocess.CalledProcessError) and error.stderr:
                print(error.stderr.decode(errors='replace'), file=sys.stderr)
    if mode != 'check':
        print(f'  Artcraft: {len(installed)} instalado(s), {updated} atualizado(s), {failed} falha(s).', flush=True)
    return 1 if failed else 0

def interrupted(_signal, _frame):
    raise KeyboardInterrupt('atualização interrompida')

signal.signal(signal.SIGTERM, interrupted)
try:
    sys.exit(main())
except (Exception, KeyboardInterrupt) as error:
    print(f'  Artcraft: {error}; instalação anterior preservada.', file=sys.stderr)
    sys.exit(1)
PY
}

artcraft_check_updates() {
  artcraft_run check
}
