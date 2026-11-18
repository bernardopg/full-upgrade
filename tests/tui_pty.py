#!/usr/bin/env python3
"""Dirige o --config-tui num pseudo-terminal real (stdin/stdout são TTY).

Uso: tui_pty.py CONFIG_FILE TECLA... — cada argumento é enviado como bytes
(escapes \\x1b, \\r etc. interpretados), com uma pausa entre eles para o TUI
redesenhar. Sai com o código de retorno do processo; a tela final vai para o
stdout. Usado por tests/tui_pty.bats.
"""
import os, pty, select, signal, struct, sys, time, fcntl, termios

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cfg, keys = sys.argv[1], sys.argv[2:]
driver = f'''
set -uo pipefail
export LOG_FILE=/dev/null QUIET=1 COLUMNS=100
source "{root}/lib/globals.sh"; source "{root}/lib/ui.sh"; source "{root}/lib/core.sh"
source "{root}/lib/json.sh"; source "{root}/lib/catalog.sh"; source "{root}/lib/config.sh"
source "{root}/lib/tui.sh"
FU_CONFIG_DIR="$(dirname "{cfg}")"; FU_CONFIG_FILE="{cfg}"
config_tui_main
'''
pid, fd = pty.fork()
if pid == 0:
    # Rodando em background (bats --jobs, `&`) o SIGINT chega herdado como
    # ignorado, e um Bash não instala trap para sinal ignorado na entrada: o
    # Ctrl-C do teste seria engolido. Num terminal de verdade ele é o padrão.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.execvp("bash", ["bash", "-c", driver])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
out = bytearray()

def pump(t):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            out.extend(data)
    return True

def pump_until(pred, t):
    """Lê até pred(out) ou EOF, no máximo t segundos (folga para runner lento/kcov)."""
    end = time.time() + t
    while time.time() < end and not pred():
        if not pump(0.1):
            return False
    return True

# Espera o rodapé do primeiro desenho: sob kcov ou CI carregado o Bash demora a
# subir, e uma tecla enviada antes do raw mode vira eco/sinal no tty cru.
def pump_quiet(quiet=0.3, limit=20):
    """Lê até o TUI ficar `quiet`s sem desenhar (no máximo `limit`s). Uma
    pausa fixa falhava com a máquina carregada: a tecla seguinte chegava antes
    do redesenho e um ESC sozinho virava início de sequência."""
    end = time.time() + limit
    while time.time() < end:
        before = len(out)
        if not pump(quiet):
            return False
        if len(out) == before:
            return True
    return True

pump_until(lambda: b"sair" in out, 60)
pump_quiet()
for k in keys:
    os.write(fd, k.encode().decode("unicode_escape").encode("latin-1"))
    if not pump_quiet():
        break
deadline = time.time() + 60
# Espera o processo terminar (EOF no pty) em vez de uma pausa fixa.
while pump(0.5):
    if time.time() > deadline:
        break
# O EOF do pty chega quando o terminal escravo fecha, um pouco ANTES de o
# processo terminar; com a máquina carregada esse intervalo cresce. Um único
# waitpid(WNOHANG) logo após o EOF via "ainda rodando" e matava com -9 um TUI
# que já tinha saído certo. Dá até 30s para o processo ser colhido.
reaped, status = 0, 0
end = time.time() + 30
while time.time() < end:
    try:
        reaped, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        reaped, status = pid, 0
    if reaped:
        break
    time.sleep(0.1)
if not reaped:
    os.kill(pid, 9); os.waitpid(pid, 0); status = 9 << 8
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(status) if status else 0)
