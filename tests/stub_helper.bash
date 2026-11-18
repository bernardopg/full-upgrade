# tests/stub_helper.bash — PATH isolado para exercitar steps sem tocar a máquina.
#
# stub_path_init troca o PATH por dois diretórios: um com stubs criados pelo
# teste e outro só com utilitários seguros (coreutils, awk, sed, grep, jq,
# python3…). Qualquer outro comando — pacman, paru, npm, docker, sudo… — some
# do PATH: `has` responde falso e uma chamada direta falha com "não
# encontrado", em vez de rodar de verdade e mutar a máquina.
#
# Uso:
#   stub_path_init
#   stub pacman 0 "linux 7.3.4.arch1-2"     # rc e stdout fixos
#   stub_script docker 'case "$1" in info) exit 0;; esac'
#   run minha_funcao
#   stub_calls pacman                         # argumentos de cada chamada

STUB_SAFE_BINS=(
  awk basename bash cat chmod cmp comm cp cut date diff dirname du env expr
  false find getent grep gzip head id install jq ln ls md5sum mkdir mktemp
  mv nproc od paste printf python3 readlink realpath rm rmdir sed seq sh
  sha256sum sleep sort stat tac tail tar tee test timeout touch tr true truncate
  uname uniq wc xargs zstd
)

stub_path_init() {
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  STUB_SAFE="${BATS_TEST_TMPDIR}/safe-bin"
  STUB_LOG="${BATS_TEST_TMPDIR}/stub-calls"
  mkdir -p "$STUB_BIN" "$STUB_SAFE"
  : > "$STUB_LOG"
  local b p
  for b in "${STUB_SAFE_BINS[@]}"; do
    p="$(type -P "$b" 2>/dev/null)" || continue
    [[ "$p" == /* ]] && ln -sf "$p" "${STUB_SAFE}/${b}"
  done
  # `python` repassa scripts ao Python real, mas recusa `-m pip`: um teste que
  # esqueça de stubar o pip não pode rodar `pip check`/`pip install` da máquina
  # (no runner do CI o `pip check` real falha e mudava o resultado do teste).
  printf '%s\n' '#!/usr/bin/env bash' \
    '[[ "${1:-}" == -m && "${2:-}" == pip ]] && exit 127' \
    'exec python3 "$@"' > "${STUB_SAFE}/python"
  chmod +x "${STUB_SAFE}/python"
  # Sem pacman-conf no PATH isolado, a lista de IgnorePkg cai no parse do
  # pacman.conf: nunca o da máquina.
  export PACMAN_CONF_FILE="${BATS_TEST_TMPDIR}/pacman.conf"
  export STUB_BIN STUB_SAFE STUB_LOG
  export PATH="${STUB_BIN}:${STUB_SAFE}"
  hash -r
}

# stub NOME [RC] [STDOUT]: registra a chamada em STUB_LOG e sai com RC.
stub() {
  local name="$1" rc="${2:-0}" out="${3:-}"
  local outf="${STUB_BIN}/.${name}.out"
  printf '%s' "$out" > "$outf"
  cat > "${STUB_BIN}/${name}" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "${name}" "\$*" >> "${STUB_LOG}"
[[ -s "${outf}" ]] && { cat "${outf}"; echo; }
exit ${rc}
EOF
  chmod +x "${STUB_BIN}/${name}"
  hash -r
}

# stub_script NOME 'CORPO': stub com lógica própria ($1… são os argumentos).
stub_script() {
  local name="$1" body="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s %%s\\n" %q "$*" >> %q\n' "$name" "$STUB_LOG"
    printf '%s\n' "$body"
  } > "${STUB_BIN}/${name}"
  chmod +x "${STUB_BIN}/${name}"
  hash -r
}

# sudo/run0/doas que só executam o comando (que precisa estar stubado).
stub_privilege() {
  stub_script sudo 'while [[ "${1:-}" == -* ]]; do shift; done; exec "$@"'
}

# Linhas de STUB_LOG chamadas por NOME (sem o nome).
stub_calls() {
  grep "^$1 " "$STUB_LOG" | sed "s/^$1 //"
}

# pty_call 'MÓDULOS' 'COMANDO' [RESPOSTA...] — roda COMANDO num pseudo-terminal
# (stdin é TTY, então os prompts "[s/N]" aparecem) depois de carregar as libs
# base e os MÓDULOS (caminhos relativos a lib/, separados por espaço). Herda o
# PATH isolado e as funções exportadas com `export -f`. Saída em $output.
pty_call() {
  local mods="$1" cmd="$2" m src=""
  shift 2
  for m in globals.sh ui.sh core.sh json.sh catalog.sh $mods; do
    src+="source \"${FU_LIB}/${m}\"; "
  done
  # globals.sh prependa ~/.cargo/bin, ~/.local/bin… (augment_user_path): sem
  # restaurar o PATH isolado, o filho acharia o cargo/npm reais da máquina.
  src+="PATH=$(printf '%q' "$PATH"); hash -r; "
  run python3 -I "${BATS_TEST_DIRNAME}/pty_run.py" \
    "export LOG_FILE=/dev/null QUIET=0 NO_COLOR=1; ${src} ${cmd}" "$@"
}
