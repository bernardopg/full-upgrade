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
