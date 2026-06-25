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

@test "_group_label_for_category: mapeia categoria do catálogo ao rótulo do grupo" {
  run _group_label_for_category pacman
  [ "$status" -eq 0 ]
  [ "$output" = "Sistema / Pacman" ]
}

@test "_group_label_for_category: editor e shell caem no mesmo rótulo" {
  [ "$(_group_label_for_category editor)" = "Shell / Editor" ]
  [ "$(_group_label_for_category shell)" = "Shell / Editor" ]
}

@test "_group_label_for_category: categoria desconhecida cai em Outros" {
  run _group_label_for_category categoria-inexistente-xyz
  [ "$status" -eq 0 ]
  [ "$output" = "Outros" ]
}

@test "ui_pad: preenche com espaços até a largura alvo" {
  run ui_pad "abc" 6
  [ "$status" -eq 0 ]
  [ "$output" = "abc   " ]
}

@test "ui_pad: texto maior que a largura não é cortado nem alterado" {
  run ui_pad "abcdefgh" 4
  [ "$status" -eq 0 ]
  [ "$output" = "abcdefgh" ]
}

@test "ui_pad: conta caracteres (não bytes) — acento PT-BR alinha" {
  # 'café' tem 4 caracteres mas 5 bytes em UTF-8; o pad deve usar 4.
  run ui_pad "café" 6
  [ "$status" -eq 0 ]
  [ "$output" = "café  " ]
}
