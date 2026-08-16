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

# ── rodapé "Próximos passos" (alinhamento) ────────────────────────────────────

_summary_footer_fixture() {
  QUIET=0; LOG_FILE=/dev/null; COLUMNS=80; JSON_SUMMARY=0
  JSONL_FILE="${BATS_TEST_TMPDIR}/run.jsonl"; : > "$JSONL_FILE"
  STEP_NAMES=("Doctor: crashes recorrentes (coredump)" "Verificação final de gerenciadores")
  STEP_RESULTS=("todo" "todo")
  STEP_TIMES=(0 10)
  STEP_REASONS=("crash recorrente: WebKitWebProcess (3x) e outros processos para forçar a quebra" "pendências após update: pnpm global")
  STEP_CATEGORIES=("doctor" "final")
  STEP_START=(0 0)
}

@test "print_summary: itens de próximos passos mantêm o alinhamento do marcador" {
  _summary_footer_fixture
  run print_summary
  [ "$status" -eq 0 ]
  plain="$(printf '%s\n' "$output" | sed -E 's/\x1b\[[0-9;]*m//g')"
  # só a seção do rodapé (o corpo agrupado usa o mesmo marcador)
  footer="$(printf '%s\n' "$plain" | sed -n '/Próximos passos:/,$p')"
  # todo item começa com "    →  " (marcador + DOIS espaços), inclusive os que quebram
  count_ok="$(printf '%s\n' "$footer" | grep -c '^    →  ')"
  [ "$count_ok" -eq 2 ]
  count_bad="$(printf '%s\n' "$footer" | grep -c '^    → [^ ]' || true)"
  [ "$count_bad" -eq 0 ]
}

@test "print_summary: continuação da quebra alinha sob o nome do step" {
  _summary_footer_fixture
  run print_summary
  [ "$status" -eq 0 ]
  plain="$(printf '%s\n' "$output" | sed -E 's/\x1b\[[0-9;]*m//g')"
  footer="$(printf '%s\n' "$plain" | sed -n '/Próximos passos:/,$p')"
  # a continuação do motivo longo fica recuada em 7 (largura de "    →  ")
  cont="$(printf '%s\n' "$footer" | grep -E '^ {7}[^ ]' | head -1)"
  [ -n "$cont" ]
  [[ "$cont" == *"WebKitWebProcess"* ]]
}

# ── print_pkg_changes (alinhamento da coluna de versões) ──────────────────────

@test "print_pkg_changes: nomes padronizados alinham a coluna de versões" {
  QUIET=0; LOG_FILE=/dev/null; COLUMNS=100
  before="${BATS_TEST_TMPDIR}/before"; after="${BATS_TEST_TMPDIR}/after"
  printf '%s\n' "lld 22.1.8-1" "extra-cmake-modules 6.28.0-1" "containerd 2.3.3-1" > "$before"
  printf '%s\n' "containerd 2.3.4-1" > "$after"
  run print_pkg_changes "$before" "$after"
  [ "$status" -eq 0 ]
  plain="$(printf '%s\n' "$output" | sed -E 's/\x1b\[[0-9;]*m//g')"
  # coluna da versão idêntica em todas as linhas de pacote (nome curto e longo)
  cols="$(printf '%s\n' "$plain" | grep -E '^    [↑+−] ' \
    | awk '{ i = index($0, $3); print i }' | sort -u | wc -l)"
  [ "$cols" -eq 1 ]
}
