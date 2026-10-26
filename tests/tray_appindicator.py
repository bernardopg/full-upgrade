#!/usr/bin/env python3
"""Runnable checks for the embedded tray menu, without a desktop session."""
import ast
import datetime
import json
from pathlib import Path
import subprocess
import textwrap
from types import SimpleNamespace
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'lib/tray.sh').read_text()
source = source.split("<<'PY'\nimport atexit", 1)[1].split('\nPY\n', 1)[0]
module = ast.parse('import atexit' + source)
functions = ast.Module(body=[n for n in module.body if isinstance(n, ast.FunctionDef)], type_ignores=[])

class Item:
    def __init__(self, label=''):
        self.label, self.children, self.enabled, self.image = label, [], True, None
    @classmethod
    def new_with_label(cls, label):
        return cls(label)
    def append(self, item): self.children.append(item)
    def prepend(self, item): self.children.insert(0, item)
    def insert(self, item, pos): self.children.insert(pos, item)
    def get_label(self): return self.label
    def set_label(self, value): self.label = value
    def get_submenu(self): return self.submenu
    def set_sensitive(self, value): self.enabled = value
    def set_image(self, value): self.image = value
    def set_always_show_image(self, value): pass
    def connect(self, *args): pass
    def show_all(self): pass
    def show(self): pass
    def set_submenu(self, menu): self.submenu, self.children = menu, menu.children

menus, notices = [], []
ctx = dict(json=json, datetime=datetime, textwrap=textwrap,
           os=__import__('os'), checking=False, check_error='', _menu_key=None,
           _relative_items={}, _previous_menus=[],
           LOG_DIR='', SELF='full-upgrade', FU_ROOT=str(ROOT), SYSTEM_ICON_DIR='/nonexistent',
           ICON_PLACEHOLDER='#bebebe', ICON_COLOR='#bebebe', MENU_ICON_PX=32,
           ICON_CACHE_DIR=tempfile.mkdtemp(), _icon_color_probe=None,
           # Pixbuf e Image devolvem o caminho do SVG para o teste conferir o arquivo.
           GdkPixbuf=SimpleNamespace(Pixbuf=SimpleNamespace(new_from_file_at_size=lambda path, w, h: path)),
           GLib=SimpleNamespace(Error=Exception),
           Gtk=SimpleNamespace(Menu=Item, ImageMenuItem=Item, SeparatorMenuItem=Item,
                               Image=SimpleNamespace(new_from_pixbuf=lambda pixbuf: pixbuf),
                               main_quit=lambda: None),
           indicator=SimpleNamespace(set_menu=menus.append))
exec(compile(functions, '<tray>', 'exec'), ctx)
artcraft = {'state': 'updates', 'artcraft': 2,
            'artcraft_updates': ['photocraft v0.1.0 -> v0.2.0', 'pdfcraft v0.1.0 -> v0.2.0']}
assert ctx['_updates_total'](artcraft) == 2
ctx['rebuild_menu'](artcraft)
craft_menu = next(item for item in menus[-1].children if item.label == 'Suíte Artcraft (2)')
assert all(any(entry in child.label for child in craft_menu.children) for entry in artcraft['artcraft_updates'])
menus.clear()
ctx['_menu_key'] = None
entries = [('Aviso %d: ' % i) + 'autenticação expirada; abra pi e execute /login ' * 4 for i in range(35)]
data = {'state': 'attention', 'todo': 35, 'doctor_pending': entries}
ctx['rebuild_menu'](data)
menu = menus[-1]
pending = next(i for i in menu.children if i.label.startswith('Avisos'))
lines = [i.label for i in pending.children if i.label]
assert len(lines) > 35 and max(map(len, lines)) <= 30
# No entry count cap or truncated tail: compare the complete wrapped output.
assert lines == [line for entry in entries for line in textwrap.wrap(entry, 30, break_on_hyphens=False)]
assert next(i for i in menu.children if i.label == 'Atualizar').image.endswith('/full-upgrade-menu-update.svg')
ctx['rebuild_menu'](dict(data, prev_state='idle'))
assert len(menus) == 1, 'unchanged menu should preserve navigation'
ctx['rebuild_menu'](dict(data, state='running'))
assert not next(i for i in menus[-1].children if i.label == 'Atualizar').enabled
assert not next(i for i in menus[-1].children if i.label == 'Executar reparos').enabled

# Run the actual timeout worker synchronously: it must reset the checking flag,
# retain the cached data, and announce incomplete rather than successful checks.
def timeout(*args, **kwargs):
    raise subprocess.TimeoutExpired('full-upgrade', 300)
ctx.update(subprocess=SimpleNamespace(run=timeout, DEVNULL=subprocess.DEVNULL, TimeoutExpired=subprocess.TimeoutExpired),
           threading=SimpleNamespace(Thread=lambda target, daemon: SimpleNamespace(start=target)),
           GLib=SimpleNamespace(idle_add=lambda fn, *args: fn(*args)),
           load_state=lambda: data, apply_state=lambda value: None,
           desktop_notify=lambda *args: notices.append(args))
ctx['refresh'](True, True)
assert not ctx['checking']
assert ctx['check_error'] and notices[-1][0] == 'Verificação incompleta'
assert not any(n[0] == 'Verificação concluída' for n in notices)
print('Tray: complete details, icons, stable menus, action guards and timeout recovery OK')

# Plural correto, estado no ícone (não em glifo de texto) e fontes zeradas fora do resumo.
assert ctx['state_headline']({'state': 'attention', 'todo': 1}) == '1 item para revisar'
assert ctx['state_headline']({'state': 'updates', 'aur': 1}) == '1 atualização'
assert ctx['state_headline']({'state': 'updates', 'repo': 3}) == '3 atualizações'
assert ctx['updates_breakdown']({'repo': 0, 'aur': 1, 'flatpak': 0}) == '1 AUR'
# Pacote: nome e versões em linhas próprias; pendência: motivo recuado sob o item.
assert ctx['package_lines']('ioruba-desktop-bin 1.10.1-1 -> 1.10.2-1') == ['ioruba-desktop-bin', '   1.10.1-1 → 1.10.2-1']
pend = ctx['entry_lines']('→ Atualizar plugins DMS — trabalho local em andamento')
assert pend[0] == '→ Atualizar plugins DMS' and all(l.startswith('   ') for l in pend[1:])

# Textos relativos mudam no lugar, sem recriar o menu (o recriar quebrava a
# navegação e soltava widgets ainda usados pelo serializer dbusmenu).
now = datetime.datetime.now().astimezone()
timed = {'state': 'idle', 'checked_at': now.isoformat(),
         'last_run_at': (now - datetime.timedelta(minutes=5)).isoformat()}
ctx['_menu_key'] = None
menus.clear()
ctx['rebuild_menu'](timed)
summary = next(i for i in menus[-1].children if i.label == 'Resumo da execução')
assert [c.label for c in summary.children] == ['Última execução: há 5 min'], 'sem "Nenhum item"'
real_relative = ctx['relative_time']
ctx['relative_time'] = lambda iso: 'há 7 min' if iso == timed['last_run_at'] else real_relative(iso)
ctx['refresh_relative_labels'](timed)
assert len(menus) == 1 and summary.children[0].label == 'Última execução: há 7 min'
ctx['relative_time'] = real_relative
print('Tray: plural, package lines, breakdown and in-place relative labels OK')

# Atomic writes by an external runner update the menu without a network probe.
applied = []
ctx.update(STATE_FILE='/tmp/state.json', checking=False,
           load_state=lambda: dict(data, state='running'), apply_state=applied.append,
           GLib=SimpleNamespace(idle_add=lambda fn, *args: fn(*args)))
file = SimpleNamespace(get_path=lambda: '/tmp/state.json')
ctx['state_file_changed'](None, file, None, None)
assert applied[-1]['state'] == 'running'
assert not next(i for i in menus[-1].children if i.label == 'Atualizar').enabled
ctx['load_state'] = lambda: dict(data, state='attention')
ctx['state_file_changed'](None, file, None, None)
assert next(i for i in menus[-1].children if i.label == 'Atualizar').enabled
print('Tray: external state publications reload without network OK')

# Ícones: todo papel usado no menu tem SVG versionado, e o cabeçalho usa o
# ícone do estado do painel. Um nome sem arquivo sumiria do menu sem erro.
ctx['_menu_key'] = None
menus.clear()
full = dict(data, state='updates', repo=1, aur=1, flatpak=1, artcraft=1,
            repo_updates=['a 1-1 -> 1-2'], aur_updates=['b 1-1 -> 1-2'],
            flatpak_updates=['c'], artcraft_updates=['d'], checked_at=now.isoformat())
ctx['check_error'] = 'timeout'
ctx['rebuild_menu'](full)
ctx['check_error'] = ''
def walk(items):
    for item in items:
        yield item
        yield from walk(item.children)
images = [i.image for i in walk(menus[-1].children) if i.image]
assert images[0].endswith('/full-upgrade-tray-updates.svg')
assert len(images) >= 15 and all(Path(img).is_file() for img in images)
used = {Path(img).name for img in images}
shipped = {p.name for p in (ROOT / 'assets/icons').glob('full-upgrade-menu-*.svg')}
assert shipped <= used | {'full-upgrade-menu-report.svg', 'full-upgrade-menu-log-folder.svg'}, shipped - used
assert ctx['menu_image']('full-upgrade-menu-nao-existe') is None

# Tingimento: a cor neutra vira a do tema numa cópia em cache, o original fica.
ctx['ICON_COLOR'] = '#e6e0e9'
tinted = ctx['tinted_icon']('full-upgrade-tray-idle')
assert tinted.startswith(ctx['ICON_CACHE_DIR']) and '/e6e0e9/' in tinted
assert '#e6e0e9' in Path(tinted).read_text() and '#bebebe' not in Path(tinted).read_text()
assert '#bebebe' in (ROOT / 'assets/icons/full-upgrade-tray-idle.svg').read_text()
assert ctx['tinted_icon']('full-upgrade-tray-idle') == tinted
ctx['ICON_COLOR'] = 'vermelho'
ctx['Gtk'].Menu = lambda: (_ for _ in ()).throw(RuntimeError('sem display'))
assert ctx['icon_color']() == '#bebebe'
print('Tray: Material icons shipped, state icon in header and theme tint OK')

# Cópia órfã em ~/.local (install.sh antigo) não pode vencer o pacote.
tmp = Path(tempfile.mkdtemp())
(tmp / 'sys').mkdir(); (tmp / 'xdg/icons/hicolor/scalable/apps').mkdir(parents=True)
(tmp / 'sys/full-upgrade-tray-idle.svg').write_text('novo')
(tmp / 'xdg/icons/hicolor/scalable/apps/full-upgrade-tray-idle.svg').write_text('velho')
os_mod = ctx['os']
old_env = os_mod.environ.get('XDG_DATA_HOME')
os_mod.environ['XDG_DATA_HOME'] = str(tmp / 'xdg')
ctx.update(FU_ROOT=str(tmp / 'sem-root'), SYSTEM_ICON_DIR=str(tmp / 'sys'))
assert ctx['icon_source']('full-upgrade-tray-idle') == str(tmp / 'sys/full-upgrade-tray-idle.svg')
(tmp / 'sys/full-upgrade-tray-idle.svg').unlink()
assert ctx['icon_source']('full-upgrade-tray-idle').endswith('xdg/icons/hicolor/scalable/apps/full-upgrade-tray-idle.svg')
if old_env is None:
    os_mod.environ.pop('XDG_DATA_HOME')
else:
    os_mod.environ['XDG_DATA_HOME'] = old_env
print('Tray: packaged icons win over orphaned user-local copies OK')
