#!/usr/bin/env bats
# tests/tldr.bats — contrato do refresh de cache Tealdeer.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/reference.sh"
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  TLDR_ARGS_FILE="${BATS_TEST_TMPDIR}/tldr-args"
  export TLDR_ARGS_FILE
}

_make_tldr() {
  cat > "${STUB_BIN}/tldr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TLDR_ARGS_FILE}"
printf '%s\n' "${TLDR_OUTPUT:-cache atualizado}"
exit "${TLDR_EXIT:-0}"
EOF
  chmod +x "${STUB_BIN}/tldr"
}

@test "tldr: ausente não falha nem tenta atualizar" {
  run update_tldr_cache

  [ "$status" -eq 0 ]
  [ ! -e "$TLDR_ARGS_FILE" ]
}

@test "tldr: refresh bem-sucedido chama somente --update" {
  _make_tldr
  export TLDR_OUTPUT="Downloaded 100 pages"

  run update_tldr_cache

  [ "$status" -eq 0 ]
  [ "$(<"$TLDR_ARGS_FILE")" = "--update" ]
}

@test "tldr: falha transitória de rede vira RC_WARN e preserva o cache" {
  _make_tldr
  export TLDR_EXIT=1
  export TLDR_OUTPUT="Could not resolve host: github.com"

  run update_tldr_cache

  [ "$status" -eq "$RC_WARN" ]
  [ "$(<"$TLDR_ARGS_FILE")" = "--update" ]
}

@test "tldr: erro local do cliente também não derruba o run" {
  _make_tldr
  export TLDR_EXIT=2
  export TLDR_OUTPUT="configuração inválida"

  run update_tldr_cache

  [ "$status" -eq "$RC_WARN" ]
  [ "$(<"$TLDR_ARGS_FILE")" = "--update" ]
}

@test "catálogo: tldr é mutante, de rede e tem timeout" {
  local row
  row="$(step_catalog | grep '^Atualizar cache do tldr|')"

  [ -n "$row" ]
  [ "$(cut -d'|' -f2 <<<"$row")" = "reference" ]
  [[ ",$(cut -d'|' -f3 <<<"$row")," == *,network,* ]]
  [ "$(cut -d'|' -f4 <<<"$row")" = "mutating" ]
  [ "$(cut -d'|' -f5 <<<"$row")" -eq 120 ]
}
