#!/usr/bin/env bats
# tests/render_cov.bats — telas e renderizações sem terminal: --config, telas
# do TUI (lista, menu, detalhe, ajuda, revisão) dirigidas por teclas, e a caixa
# de resumo do --healthcheck. Nada é gravado fora de $BATS_TEST_TMPDIR.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/config.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/tui.sh"
  NO_COLOR=1
  export HOME="${BATS_TEST_TMPDIR}/home" XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/home/.config"
  mkdir -p "$XDG_CONFIG_HOME/full-upgrade"
  FU_CONFIG_DIR="$XDG_CONFIG_HOME/full-upgrade"
  FU_CONFIG_FILE="$FU_CONFIG_DIR/config"
}

# ── show_config ───────────────────────────────────────────────────────────────

@test "show_config: sem arquivo usa defaults e lista as seções" {
  run show_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"Configuração do full-upgrade"* ]]
  [[ "$output" == *"não existe — usando defaults"* ]]
  [[ "$output" == *"FULL_UPGRADE_DISABLED_INTEGRATIONS"* ]]
}

@test "show_config: com arquivo aponta chave com erro de digitação" {
  printf '%s\n' 'SNAPSHOT_KEPP=3' 'FULL_UPGRADE_SKIP="Atualizar Bun"' > "$FU_CONFIG_FILE"
  run show_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"carregado"* ]]
  [[ "$output" == *"SNAPSHOT_KEPP"* ]]
}

# ── TUI dirigido por teclas ───────────────────────────────────────────────────

_tui_init() {
  TUI_ROWS=30 TUI_COLS=100 TUI_SIZE_DIRTY=0 TUI_QUIT=0 TUI_FLASH="" TUI_FLASH_BAK=""
  TUI_DRAW_DETAIL=0 TUI_FILTER="" TUI_FILTER_MODE=0
  tput() { case "$1" in lines) echo 30 ;; cols) echo 100 ;; esac; }
  tui_enter_screen menu
}

# Desenha a tela atual como o laço principal faz.
_tui_draw() {
  case "$TUI_MODE" in
    menu) tui_draw_menu ;;
    steps) tui_draw_list "steps" ;;
    params) tui_draw_list "parâmetros" ;;
    help) tui_draw_help ;;
  esac
  if (( TUI_DRAW_DETAIL == 1 )); then tui_draw_detail; TUI_DRAW_DETAIL=0; fi
}

# Em contexto `|| true` o errexit do bats não derruba o `(( ))` falso do TUI.
_tui_press() { { TUI_KEY="$1"; tui_handle_key; _tui_draw; } || true; }

@test "tui: menu, lista de steps, navegação, toggle e detalhe" {
  _tui_init
  out="$(_tui_draw || true)"
  [[ "$out" == *"menu principal"* ]]
  { _tui_press char:1; _tui_press down; _tui_press pgdn; _tui_press end
    _tui_press home; _tui_press space; _tui_press char:d; } > "$BATS_TEST_TMPDIR/screen"
  [ "$TUI_MODE" = steps ]
  [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = skip ] || [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = run ]
  grep -q "steps" "$BATS_TEST_TMPDIR/screen"
  grep -q "categoria/efeito" "$BATS_TEST_TMPDIR/screen"
}

@test "tui: End deixa o último parâmetro visível acima do rodapé" {
  # Regressão: a rolagem contava a linha de títulos como item e o último
  # parâmetro ficava fora da tela, coberto pelas dicas do rodapé.
  _tui_init
  _tui_press char:2 >/dev/null
  local last="${TUI_NAME[${TUI_VIEW[$(( ${#TUI_VIEW[@]} - 1 ))]}]}"
  _tui_press end > "$BATS_TEST_TMPDIR/screen"
  grep -q -- "$last" "$BATS_TEST_TMPDIR/screen"
  # E nenhuma linha de item é desenhada na região do rodapé (linhas 29-30).
  tui_visible_rows_var
  [ $(( TUI_HEAD_H + 1 + TUI_VIS )) -le $(( TUI_ROWS - 2 )) ]
}

@test "tui: parâmetros com enum, bool, filtro vivo e volta ao menu" {
  _tui_init
  { _tui_press char:2; _tui_press right; _tui_press left; _tui_press down
    _tui_press space; _tui_press char:/; TUI_KEY="char:S"; tui_filter_key || true; _tui_draw || true
    _tui_press esc; _tui_press esc; _tui_press esc; _tui_press esc; } > "$BATS_TEST_TMPDIR/screen"
  grep -q "parâmetros" "$BATS_TEST_TMPDIR/screen"
  [ "$TUI_MODE" = menu ]
}

@test "tui: ajuda e saída sem pendências" {
  _tui_init
  { _tui_press char:3; _tui_press enter; _tui_press char:q; } > "$BATS_TEST_TMPDIR/screen"
  grep -qi "teclas" "$BATS_TEST_TMPDIR/screen"
  [ "$TUI_QUIT" -eq 1 ]
}

@test "tui: menu por Enter em cada item" {
  _tui_init
  local i
  for i in 0 1 2; do
    tui_enter_screen menu; TUI_SEL=$i
    _tui_press enter >/dev/null
  done
  [ "$TUI_MODE" = help ]
}

@test "config_tui_main: sem TTY explica as alternativas e sai 2" {
  run config_tui_main </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"precisa de um terminal interativo"* ]]
}

# ── hc_render_summary_box ─────────────────────────────────────────────────────

@test "hc_render_summary_box: sem dados não desenha; com dados mostra o resumo" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/healthcheck.sh"
  run hc_render_summary_box
  [ "$status" -eq 1 ]
  HC_SUMMARY_DISTRO="Arch Linux" HC_SUMMARY_KF="7.3.4-arch1-2|7.3.5-arch1-1" \
  HC_SUMMARY_DT="Hyprland|wayland" HC_SUMMARY_CPU="Ryzen 7" HC_SUMMARY_MEM="31 GiB" \
  HC_SUMMARY_DISK="/: 80%" HC_SUMMARY_PM=6 HC_SUMMARY_TS="5 snapshots|2026-11-17" \
  HC_SUMMARY_CB="restic" HC_SUMMARY_TTY="pts/1" HC_SUMMARY_TERM="kitty" \
    run hc_render_summary_box
  [ "$status" -eq 0 ]
  [[ "$output" == *"Arch Linux"* ]]
}

# ── explain_step, _category_label, tray_print_status ─────────────────────────

@test "explain_step: step conhecido e desconhecido" {
  run explain_step "Doctor: saúde de rede"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Categoria: doctor"* ]]
  [[ "$output" == *"Função: doctor_network_health"* ]]
  run explain_step "Step que não existe"
  [ "$status" -eq 1 ]
}

@test "_category_label: toda categoria do catálogo tem rótulo; desconhecida vira Outros" {
  local c
  for c in core backup repair packages firmware lang-js lang-py lang-rust lang-other ai ide tools editor shell security cleanup autofix final doctor; do
    [ "$(_category_label "$c")" != "Outros" ]
  done
  [ "$(_category_label inexistente)" = "Outros" ]
}

@test "tray_print_status: sem estado e com estado completo" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/tray.sh"
  TRAY_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  run tray_print_status
  [[ "$output" == *"Sem estado ainda"* ]]
  printf '%s\n' '{"state":"updates","repo":2,"aur":1,"flatpak":0,"artcraft":0,"todo":0,"fail":0,"reboot":"","checked_at":"2026-11-17T10:00:00-03:00","last_run_at":"","log_file":"/x.log"}' > "$TRAY_STATE_FILE"
  tray_daemon_status() { echo parado; }
  tray_systemd_unit_status() { echo desabilitada; }
  run tray_print_status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updates     : 2 repo + 1 AUR + 0 Flatpak + 0 Artcraft"* ]]
  [[ "$output" == *"Último run  : desconhecido"* ]]
  [[ "$output" == *"Daemon      : parado"* ]]
}

# ── Revisão e gravação pelo TUI ───────────────────────────────────────────────

@test "tui: revisão paginada aplica as alterações e grava o config" {
  _tui_init
  { _tui_press char:1; _tui_press space; _tui_press esc; } >/dev/null
  local -a keys=(down up enter)
  local i=0
  tui_read_key() { TUI_KEY="${keys[$i]}"; i=$((i + 1)); }
  { TUI_KEY=char:s; tui_handle_key || true; } > "$BATS_TEST_TMPDIR/screen"
  grep -q "revisão" "$BATS_TEST_TMPDIR/screen"
  grep -q "FULL_UPGRADE_SKIP" "$FU_CONFIG_FILE"
}

@test "tui: revisão sem pendências e cancelada com Esc" {
  _tui_init
  TUI_KEY=char:s; tui_handle_key || true
  [ "$TUI_FLASH" = "nada a salvar" ] || [[ "$TUI_FLASH" == *"nada"* ]]
  { _tui_press char:1; _tui_press space; _tui_press esc; } >/dev/null
  tui_read_key() { TUI_KEY=esc; }
  { TUI_KEY=char:s; tui_handle_key || true; } >/dev/null
  [ ! -s "$FU_CONFIG_FILE" ]
  tui_read_key() { TUI_KEY=char:q; }
  { TUI_KEY=char:s; tui_handle_key || true; } >/dev/null
  [ "$TUI_QUIT" -eq 1 ]
}
