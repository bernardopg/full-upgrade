#!/usr/bin/env python3
"""Check the shipped Mason command in real Neovim, with a local registry stub."""
from pathlib import Path
import re
import shutil
import subprocess

if not shutil.which('nvim'):
    raise SystemExit('SKIP: Neovim is not installed')
source = (Path(__file__).resolve().parents[1] / 'lib/steps/editor.sh').read_text()
command = re.search(r'nvim --headless "(\+lua .*?)" \+qa', source).group(1)[1:]
preload = """lua
local r={refresh=function() return true end,
get_installed_packages=function() return {
{name='current',get_installed_version=function() return '1' end,get_latest_version=function() return '1' end},
{name='old',get_installed_version=function() return '1' end,get_latest_version=function() return '2' end}
} end};
package.preload['mason-registry']=function() return r end;
vim.api.nvim_create_user_command('MasonInstall',function(opts)
assert(opts.args=='old', 'only outdated tools should be installed'); print('installed old')
end,{nargs='+'})
""".replace('\n', ' ')
result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-c', preload, '-c', command, '-c', 'qa'], capture_output=True, text=True)
assert result.returncode == 0 and 'installed old' in result.stderr, result.stderr
failure = "lua package.preload['mason-registry']=function() return {refresh=function() return false end} end"
result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-c', failure, '-c', command, '-c', 'qa'], capture_output=True, text=True)
assert result.returncode != 0 and 'registry refresh failed' in result.stderr, result.stderr
print('Mason: outdated tools installed, registry failures propagate OK')
