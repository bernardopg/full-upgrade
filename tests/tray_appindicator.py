#!/usr/bin/env python3
"""Runnable checks for the embedded tray menu, without a desktop session."""
import ast
import datetime
import json
from pathlib import Path
import subprocess
import textwrap
from types import SimpleNamespace

source = (Path(__file__).resolve().parents[1] / 'lib/tray.sh').read_text()
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
    def set_sensitive(self, value): self.enabled = value
    def set_image(self, value): self.image = value
    def set_always_show_image(self, value): pass
    def connect(self, *args): pass
    def show_all(self): pass
    def show(self): pass
    def set_submenu(self, menu): self.children = menu.children

menus, notices = [], []
ctx = dict(json=json, datetime=datetime, textwrap=textwrap,
           os=__import__('os'), checking=False, check_error='', _menu_key=None,
           STATE_GLYPH={'idle': '●'}, LOG_DIR='', SELF='full-upgrade',
           Gtk=SimpleNamespace(Menu=Item, ImageMenuItem=Item, SeparatorMenuItem=Item,
                               Image=SimpleNamespace(new_from_icon_name=lambda icon, size: icon),
                               IconSize=SimpleNamespace(MENU=1), main_quit=lambda: None),
           indicator=SimpleNamespace(set_menu=menus.append))
exec(compile(functions, '<tray>', 'exec'), ctx)
entries = [('Aviso %d: ' % i) + 'autenticação expirada; abra pi e execute /login ' * 4 for i in range(35)]
data = {'state': 'attention', 'todo': 35, 'doctor_pending': entries}
ctx['rebuild_menu'](data)
menu = menus[-1]
pending = next(i for i in menu.children if i.label.startswith('Avisos'))
lines = [i.label for i in pending.children if i.label]
assert len(lines) > 35 and max(map(len, lines)) <= 30
# No entry count cap or truncated tail: compare the complete wrapped output.
assert lines == [line for entry in entries for line in textwrap.wrap(entry, 30, break_on_hyphens=False)]
assert next(i for i in menu.children if i.label == 'Atualizar').image
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
