#!/usr/bin/env bats
# tests/ui_summary.bats — regressões do agrupamento do resumo

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
}

@test "summary_group_specs: agrupa containers, flatpak e docker em Contêineres" {
  run summary_group_specs
  [ "$status" -eq 0 ]
  [[ "$output" == *"Contêineres|containers flatpak docker snap"* ]]
}

@test "summary_group_specs: agrupa editor e shell num único Shell / Editor" {
  run summary_group_specs
  [ "$status" -eq 0 ]
  count="$(printf '%s\n' "$output" | grep -c '^Shell / Editor|')"
  [ "$count" -eq 1 ]
  [[ "$output" == *"Shell / Editor|editor shell"* ]]
}

@test "summary_group_specs: toda categoria do catálogo aparece em algum grupo" {
  missing="$(
    while IFS='|' read -r _name cat _rest; do
      [[ -n "$cat" ]] || continue
      summary_category_in_groups "$cat" || printf '%s\n' "$cat"
    done < <(step_catalog)
  )"

  [ -z "$missing" ]
}
