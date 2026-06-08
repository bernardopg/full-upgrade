#!/usr/bin/env bats
# tests/catalog.bats — parser e filtros de lib/catalog.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
}

# ── catalog_match_token ───────────────────────────────────────────────────────

@test "catalog_match_token: casa pela categoria" {
  run catalog_match_token "doctor" "network,read" "doctor"
  [ "$status" -eq 0 ]
}

@test "catalog_match_token: casa por uma das tags" {
  run catalog_match_token "doctor" "network,read" "network"
  [ "$status" -eq 0 ]
}

@test "catalog_match_token: não casa token ausente" {
  run catalog_match_token "doctor" "network,read" "docker"
  [ "$status" -ne 0 ]
}

@test "catalog_match_token: não casa substring parcial de tag" {
  run catalog_match_token "doctor" "network,read" "net"
  [ "$status" -ne 0 ]
}

# ── catalog_info_for_step ─────────────────────────────────────────────────────

@test "catalog_info_for_step: retorna metadados de um step conhecido" {
  run catalog_info_for_step "Validar sudo"
  [ "$status" -eq 0 ]
  # formato: categoria|tags|efeito|timeout|cmd_deps|func_name|desc
  [[ "$output" == core\|* ]]
  [[ "$output" == *"|start_sudo_keepalive|"* ]]
}

@test "catalog_info_for_step: step inexistente retorna sentinela unknown" {
  run catalog_info_for_step "Step que não existe no catálogo"
  [ "$output" = "unknown||||||" ]
}

@test "catalog_info_for_step: 7 campos separados por pipe" {
  result="$(catalog_info_for_step "Validar sudo")"
  # conta os separadores: 7 campos => 6 pipes
  pipes="${result//[^|]/}"
  [ "${#pipes}" -eq 6 ]
}

# ── catalog_has_token ─────────────────────────────────────────────────────────

@test "catalog_has_token: categoria existente no catálogo" {
  run catalog_has_token "doctor"
  [ "$status" -eq 0 ]
}

@test "catalog_has_token: token inexistente" {
  run catalog_has_token "token_que_nao_existe_xyz"
  [ "$status" -ne 0 ]
}

# ── count_effective_steps ─────────────────────────────────────────────────────

@test "count_effective_steps: sem skip conta todos os steps" {
  FULL_UPGRADE_SKIP=""
  run count_effective_steps
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "count_effective_steps: skip decrementa o total" {
  FULL_UPGRADE_SKIP=""
  total_antes="$(count_effective_steps)"
  add_skip_step "Validar sudo"
  total_depois="$(count_effective_steps)"
  [ "$total_depois" -eq $((total_antes - 1)) ]
}

# ── apply_only_category ───────────────────────────────────────────────────────

@test "apply_only_category: mantém steps core mesmo filtrando outra categoria" {
  FULL_UPGRADE_SKIP=""
  apply_only_category "doctor"
  # 'core' nunca é adicionado ao skip por apply_only_category
  run _step_skip_requested "Validar sudo"
  [ "$status" -ne 0 ]
}

@test "apply_only_category: adiciona ao skip steps fora da categoria pedida" {
  FULL_UPGRADE_SKIP=""
  apply_only_category "doctor"
  # 'Atualizar Flatpak' (categoria flatpak) deve ir para o skip
  run _step_skip_requested "Atualizar Flatpak"
  [ "$status" -eq 0 ]
}
