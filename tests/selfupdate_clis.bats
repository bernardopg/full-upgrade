#!/usr/bin/env bats
# tests/selfupdate_clis.bats — lógica pura dos steps self-download (grok, jcode,
# qodercli, qoderwake, kimchi, cua-driver). Não executa updaters reais nem rede:
# valida só a decisão "output do --check indica que já está atualizado?" e a
# leitura do campo update_available do JSON do cua-driver.

load test_helper

setup() { load_libs; }

# Réplica do predicado usado em _selfupdate_check_apply: considera "atualizado"
# quando o texto do --check casa o regex de "já na última versão".
_is_uptodate_text() {
  printf '%s' "$1" | grep -qiE 'up[- ]?to[- ]?date|already[^[:cntrl:]]*latest|no updates?|nenhuma atualiza'
}

# Predicado do cua-driver: JSON com update_available:true → precisa aplicar.
_json_update_available() {
  printf '%s' "$1" | grep -qiE '"update_available"[[:space:]]*:[[:space:]]*true'
}

@test "check textual: 'up to date' é reconhecido como atualizado" {
  run _is_uptodate_text "grok is up to date (0.2.87)"
  [ "$status" -eq 0 ]
}

@test "check textual: 'already on latest' é reconhecido como atualizado" {
  run _is_uptodate_text "You are already on the latest version"
  [ "$status" -eq 0 ]
}

@test "check textual: PT-BR 'nenhuma atualização' é reconhecido" {
  run _is_uptodate_text "nenhuma atualização disponível"
  [ "$status" -eq 0 ]
}

@test "check textual: anúncio de nova versão NÃO conta como atualizado" {
  run _is_uptodate_text "A new version of Grok Build is available: 0.1.218 -> 0.2.87"
  [ "$status" -ne 0 ]
}

@test "check textual: campo 'latest' com versão diferente NÃO conta como atualizado" {
  run _is_uptodate_text "Grok Build - v0.2.87 (latest: 0.2.88) [stable]"
  [ "$status" -ne 0 ]
}

@test "cua-driver JSON: update_available:true dispara apply" {
  run _json_update_available '{ "current_version": "0.6.0", "update_available": true }'
  [ "$status" -eq 0 ]
}

@test "cua-driver JSON: update_available:false não dispara apply" {
  run _json_update_available '{ "current_version": "0.7.0", "update_available": false }'
  [ "$status" -ne 0 ]
}

@test "catálogo: os 6 steps self-download estão registrados com func própria" {
  local out
  out="$(step_catalog)"
  for f in update_grok update_jcode update_qodercli update_qoderwake update_kimchi update_cua_driver; do
    printf '%s\n' "$out" | grep -q "|${f}|" || {
      echo "func ausente no catálogo: $f"
      return 1
    }
  done
}

# Stub do cua-driver no PATH: check-update anuncia 0.28.3, apply devolve o que
# CUA_APPLY_OUT/CUA_APPLY_RC mandarem. Nada toca rede nem ~/.cua-driver.
_stub_cua_driver() {
  source "${FU_LIB}/steps/tools.sh"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/cua-driver" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "cua-driver 0.28.2" ;;
  "check-update --json") echo '{ "current_version": "0.28.2", "update_available": true }' ;;
  "update --apply") printf '%s\n' "$CUA_APPLY_OUT"; exit "$CUA_APPLY_RC" ;;
  "skills update") echo "skills ok" ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/cua-driver"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "cua-driver: release retirada pelo upstream não vira aviso" {
  _stub_cua_driver
  export CUA_APPLY_RC=1
  export CUA_APPLY_OUT="error: cua-driver-rs-v0.28.3 was withdrawn and must not be installed; pin a different release"
  run update_cua_driver
  [ "$status" -eq 0 ]
}

@test "cua-driver: falha real do apply vira aviso com motivo" {
  _stub_cua_driver
  export CUA_APPLY_RC=1 CUA_APPLY_OUT="error: checksum mismatch"
  STEP_REASON=""
  update_cua_driver || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"rc=1"* ]]
}
