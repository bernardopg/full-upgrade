#!/usr/bin/env bats
# tests/repair_cov.bats — sombra de binário em /usr/local/bin (diretório
# descartável), scopes transitórios do systemd --user e chaves inválidas do
# coredump.conf (arquivo descartável). PATH isolado; sudo só executa o stub.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/repair.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export REPAIR_LOCAL_BIN_DIR="$BATS_TEST_TMPDIR/local-bin"; mkdir -p "$REPAIR_LOCAL_BIN_DIR"
}

@test "shadowing: sem binário do pacote, do pacote, gerenciado fora do pacman e movido" {
  touch "$REPAIR_LOCAL_BIN_DIR/wireshark"
  run repair_command_shadowing wireshark "$BATS_TEST_TMPDIR/nao-existe"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Binario gerenciado não encontrado"* ]]
  touch "$BATS_TEST_TMPDIR/wireshark"
  stub pacman 0 ""
  run repair_command_shadowing wireshark "$BATS_TEST_TMPDIR/wireshark"
  [[ "$output" == *"gerenciado por pacote; nada a reparar"* ]]
  stub pacman 1 ""
  run repair_command_shadowing wireshark "$BATS_TEST_TMPDIR/wireshark"
  [ "$status" -eq 1 ]
  [[ "$output" == *"não e gerenciado pelo pacman"* ]]
  stub_script pacman '[[ "$2" == "$BATS_TEST_TMPDIR/wireshark" ]]'
  run repair_command_shadowing wireshark "$BATS_TEST_TMPDIR/wireshark"
  [ "$status" -eq 0 ]
  [ ! -e "$REPAIR_LOCAL_BIN_DIR/wireshark" ]
  ls "$REPAIR_LOCAL_BIN_DIR"/wireshark.manual.*
}

@test "shadowing conhecido verifica wireshark e dumpcap" {
  run repair_known_command_shadowing
  [[ "$output" == *"Sem sombra local para wireshark"* ]]
  [[ "$output" == *"Sem sombra local para dumpcap"* ]]
}

@test "scopes: sessão indisponível, nenhum failed e reset-failed falho" {
  stub_script systemctl 'case "$*" in *--failed*) echo "${FAILED:-}" ;; *reset-failed*) exit "${RESET_RC:-0}" ;; esac'
  systemd_user_scope_status() { echo unavailable; }
  run repair_stale_user_app_scopes
  [[ "$output" == *"Sessão systemd --user indisponível"* ]]
  systemd_user_scope_status() { echo available; }
  run repair_stale_user_app_scopes
  [[ "$output" == *"Nenhum scope transitório em estado failed"* ]]
  FAILED="app-x.scope loaded failed failed X" RESET_RC=1 repair_stale_user_app_scopes >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "não foi possível limpar scopes transitórios" ]
}

@test "portais XDG: sessão indisponível, nenhum failed, reativa e falha" {
  stub_script systemctl 'case "$*" in
    *--failed*) echo "${FAILED:-}" ;;
    *reset-failed*) echo "reset $*" >> "$BATS_TEST_TMPDIR/calls" ;;
    *" start "*) echo "start $*" >> "$BATS_TEST_TMPDIR/calls"; exit "${START_RC:-0}" ;;
    *is-active*) exit "${START_RC:-0}" ;;
  esac'
  systemd_user_scope_status() { echo unavailable; }
  run repair_failed_xdg_portals
  [[ "$output" == *"reparo de portais pulado"* ]]
  systemd_user_scope_status() { echo available; }
  FAILED="app-x.scope loaded failed failed X" run repair_failed_xdg_portals
  [[ "$output" == *"Nenhum portal XDG em estado failed"* ]]
  FAILED="xdg-document-portal.service loaded failed failed flatpak document portal service" \
    run repair_failed_xdg_portals
  [ "$status" -eq 0 ]
  [[ "$output" == *"xdg-document-portal.service: ativo."* ]]
  grep -q "reset --user reset-failed xdg-document-portal.service" "$BATS_TEST_TMPDIR/calls"
  grep -q "start --user start xdg-document-portal.service" "$BATS_TEST_TMPDIR/calls"
  STEP_REASON=""
  FAILED="xdg-desktop-portal-hyprland.service loaded failed failed X" START_RC=1 \
    repair_failed_xdg_portals >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "portal XDG não voltou: xdg-desktop-portal-hyprland.service" ]
}

@test "coredump.conf: sem chave inválida, mktemp falho e cópia falha" {
  f="$BATS_TEST_TMPDIR/coredump.conf"
  printf '[Coredump]\nStorage=external\n' > "$f"
  COREDUMP_CONFIG_PATHS="$f" run repair_coredump_obsolete_keys
  [[ "$output" == *"Nenhuma diretiva inválida"* ]]
  printf '[Coredump]\nMaxAge=3d\n' > "$f"
  mktemp() { return 1; }
  COREDUMP_CONFIG_PATHS="$f" repair_coredump_obsolete_keys >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "mktemp falhou ao reparar coredump.conf" ]
  unset -f mktemp; unset status
  stub sudo 1 ""
  COREDUMP_CONFIG_PATHS="$f" repair_coredump_obsolete_keys >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "falha ao reparar $f; backup: "* ]]
  grep -q '^MaxAge=3d' "$f"
}
