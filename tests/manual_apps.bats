#!/usr/bin/env bats
# tests/manual_apps.bats — funções puras dos steps de apps manuais
# (lib/steps/manual_apps.sh). Não mutam nada; só lógica de classificação.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/manual_apps.sh"
}

@test "_manual_apps_has_step: reconhece app coberto por step (droid)" {
  run _manual_apps_has_step droid
  [ "$status" -eq 0 ]
}

@test "_manual_apps_has_step: reconhece marcador de diretório /opt (zaproxy)" {
  run _manual_apps_has_step zaproxy
  [ "$status" -eq 0 ]
}

@test "_manual_apps_has_step: app sem step retorna não-zero" {
  run _manual_apps_has_step gk
  [ "$status" -ne 0 ]
}

@test "_manual_apps_has_step: nome vazio não é coberto" {
  run _manual_apps_has_step ""
  [ "$status" -ne 0 ]
}

@test "catálogo: steps de apps manuais presentes e bem-formados" {
  run step_catalog
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizar Factory droid|manual|"* ]]
  [[ "$output" == *"Atualizar Snyk CLI|manual|"* ]]
  [[ "$output" == *"Atualizar add-ons do OWASP ZAP|manual|"* ]]
  [[ "$output" == *"Doctor: apps manuais (fora de pacote)|doctor|"* ]]
}

@test "catálogo: categoria manual mapeia para o grupo Apps manuais" {
  run _group_label_for_category manual
  [ "$status" -eq 0 ]
  [ "$output" = "Apps manuais" ]
}
