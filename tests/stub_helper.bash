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
  mv nproc od paste printf python python3 readlink realpath rm rmdir sed seq sh
  sha256sum sleep sort stat tac tail tar tee timeout touch tr true truncate
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
