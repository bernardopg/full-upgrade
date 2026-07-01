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
  # 'idea' (JetBrains em /opt) é um app manual sem step de atualização dedicado.
  run _manual_apps_has_step idea
  [ "$status" -ne 0 ]
}

@test "_manual_apps_has_step: nome vazio não é coberto" {
  run _manual_apps_has_step ""
  [ "$status" -ne 0 ]
}

@test "_manual_apps_kind: app coberto vira covered" {
  run _manual_apps_kind droid
  [ "$output" = "covered" ]
}

@test "_manual_apps_kind: backups manuais viram backup" {
  run _manual_apps_kind dumpcap.manual.20260628-215302
  [ "$output" = "backup" ]
  run _manual_apps_kind antigravity.manual-backup-20260628213513
  [ "$output" = "backup" ]
  run _manual_apps_kind nomacs-original
  [ "$output" = "backup" ]
}

@test "_manual_apps_kind: tshark/sharkd viram auxiliares" {
  run _manual_apps_kind tshark
  [ "$output" = "auxiliary" ]
  run _manual_apps_kind sharkd
  [ "$output" = "auxiliary" ]
}

@test "_manual_apps_kind: app real sem step vira candidate" {
  run _manual_apps_kind codexbar
  [ "$output" = "candidate" ]
  run _manual_apps_kind idea-2026.1.3
  [ "$output" = "candidate" ]
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

@test "_manual_write_prefix: destino escrevível não exige sudo (prefixo vazio)" {
  tmp="$(mktemp)"
  run _manual_write_prefix "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_manual_write_prefix: destino não escrevível + sudo disponível => imprime sudo" {
  # Diretório inexistente => não escrevível para qualquer uid (inclui root no CI)
  local tmp="$BATS_TEST_TMPDIR/nao-existe/app"
  has() { [[ "$1" == sudo ]]; }
  sudo() { [[ "$*" == "-n true" ]]; }
  run _manual_write_prefix "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "sudo" ]
}

@test "_manual_write_prefix: destino não escrevível + sem sudo => retorna 1" {
  local tmp="$BATS_TEST_TMPDIR/nao-existe/app"
  has() { return 1; }
  run _manual_write_prefix "$tmp"
  [ "$status" -ne 0 ]
}

# ── update_* (self-updaters; mocks de comandos externos) ──────────────────────
# Helpers comuns: neutraliza I/O e rede por padrão.
_ma_silence() { log() { :; }; log_raw() { :; }; }

@test "update_droid: ausente => return 0 (skip)" {
  _ma_silence; has() { return 1; }
  run update_droid
  [ "$status" -eq 0 ]
}

@test "update_droid: já atualizado => return 0" {
  _ma_silence
  has() { [[ "$1" == droid ]]; }
  droid() { echo "droid 1.2.3"; }
  run_network_cmd() { echo "already up-to-date"; return 0; }
  run update_droid
  [ "$status" -eq 0 ]
}

@test "update_droid: falha no --check => RC_WARN" {
  _ma_silence
  has() { [[ "$1" == droid ]]; }
  droid() { echo "droid 1.2.3"; }
  run_network_cmd() { return 1; }
  run update_droid
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_droid: update real bem-sucedido => return 0" {
  _ma_silence
  has() { [[ "$1" == droid ]]; }
  droid() { echo "droid 2.0.0"; }
  run_network_cmd() { echo "downloading update"; return 0; }
  run update_droid
  [ "$status" -eq 0 ]
}

@test "update_coderabbit: ausente => 0; falha => RC_WARN; sucesso => 0" {
  _ma_silence
  has() { return 1; }
  run update_coderabbit; [ "$status" -eq 0 ]

  has() { [[ "$1" == coderabbit ]]; }
  coderabbit() { echo "coderabbit 1.0"; }
  run_network_cmd() { return 1; }
  run update_coderabbit; [ "$status" -eq "$RC_WARN" ]

  run_network_cmd() { echo ok; return 0; }
  run update_coderabbit; [ "$status" -eq 0 ]
}

@test "update_kiro_cli: ausente => 0; falha => RC_WARN; sucesso => 0" {
  _ma_silence
  has() { return 1; }
  run update_kiro_cli; [ "$status" -eq 0 ]

  has() { [[ "$1" == kiro-cli ]]; }
  kiro-cli() { echo "kiro-cli 0.1"; }
  run_network_cmd() { return 1; }
  run update_kiro_cli; [ "$status" -eq "$RC_WARN" ]

  run_network_cmd() { echo ok; return 0; }
  run update_kiro_cli; [ "$status" -eq 0 ]
}

@test "update_snyk: ausente => 0" {
  _ma_silence; has() { return 1; }
  run update_snyk; [ "$status" -eq 0 ]
}

@test "update_snyk: gerenciado por npm => 0 (skip)" {
  _ma_silence
  has() { [[ "$1" == snyk || "$1" == curl ]]; }
  command() { if [[ "$1" == -v && "$2" == snyk ]]; then echo /usr/lib/node_modules/snyk/bin/snyk; else builtin command "$@"; fi; }
  readlink() { echo /usr/lib/node_modules/snyk/bin/snyk; }
  run update_snyk
  [ "$status" -eq 0 ]
}

@test "update_zap: ausente => 0 (skip)" {
  _ma_silence
  command() { if [[ "$1" == -v ]]; then return 1; else builtin command "$@"; fi; }
  run update_zap
  [ "$status" -eq 0 ]
}

@test "update_gk: ausente => 0; sem curl/unzip => 0" {
  _ma_silence
  has() { return 1; }
  run update_gk; [ "$status" -eq 0 ]

  has() { [[ "$1" == gk ]]; }   # gk existe mas curl/unzip não
  run update_gk; [ "$status" -eq 0 ]
}
