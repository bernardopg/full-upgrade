#!/usr/bin/env python3
"""Roda um script Bash num pseudo-terminal (stdin é TTY) e envia respostas.

Uso: pty_run.py SCRIPT [RESPOSTA...] — cada resposta é escrita como bytes
(escapes \\r, \\n etc. interpretados) quando o processo para de produzir
saída. Imprime tudo o que o processo escreveu e sai com o código dele. Usado
pelos testes de prompts "[s/N]", que só aparecem quando [[ -t 0 ]].
"""
import os, pty, select, signal, sys, time

script, answers = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    # Rodando em background (bats --jobs, `&`) o SIGINT chega herdado como
    # ignorado, e um Bash não instala trap para sinal ignorado na entrada: o
    # Ctrl-C do teste seria engolido. Num terminal de verdade ele é o padrão.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    os.execvp("bash", ["bash", "-c", script])
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

def pump_quiet(quiet=0.4, limit=15):
    """Lê até o processo ficar `quiet`s sem escrever (no máximo `limit`s): o
    prompt seguinte só aparece depois do trabalho anterior, mais lento quando a
    máquina está carregada."""
    end = time.time() + limit
    while time.time() < end:
        before = len(out)
        if not pump(quiet):
            return False
        if len(out) == before:
            return True
    return True

alive = pump_quiet()
for a in answers:
    if not alive:
        break
    os.write(fd, a.encode().decode("unicode_escape").encode("latin-1"))
    alive = pump_quiet()
# Espera o processo terminar (EOF no pty), com teto para não pendurar o teste.
end = time.time() + 20
while alive and time.time() < end:
    alive = pump(0.5)
_, status = os.waitpid(pid, 0)
sys.stdout.write(out.decode("utf-8", "replace"))
sys.exit(os.waitstatus_to_exitcode(status))
