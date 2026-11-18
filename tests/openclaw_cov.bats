#!/usr/bin/env bats
# tests/openclaw_cov.bats — update_openclaw de ponta a ponta com o binário e o
# npm stubados: ausente, já na última pelo dry-run (inclusive com targetVersion
# null resolvido no registry), update ok, "já atualizado", falha parcial de
# plugin e falha do update. PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/60-openclaw.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  unset OPENCLAW_BIN
  run_network_cmd() { "$@"; }
  stub_script openclaw 'case "$*" in
  --version) echo "OpenClaw 2026.11.1" ;;
  "update --dry-run --json") echo "${DRY:-}" ;;
  update) echo "${UPD_OUT:-ok}"; exit "${UPD_RC:-0}" ;;
esac'
}

@test "ausente: só verifica o gateway" {
  rm "$STUB_BIN/openclaw"; hash -r
  stub_script systemctl 'echo failed'
  run update_openclaw
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"OpenClaw não encontrado"* ]]
}

@test "dry-run: já na última, inclusive com targetVersion null resolvido no npm" {
  DRY='{"currentVersion":"2026.11.1","targetVersion":"2026.11.1"}' run update_openclaw
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenClaw 2026.11.1 já na versão mais recente; pulando reinstalação"* ]]
  stub npm 0 '"2026.11.1"'
  DRY='{"currentVersion":"2026.11.1","targetVersion": null}' run update_openclaw
  [[ "$output" == *"pulando reinstalação"* ]]
  ! stub_calls openclaw | grep -qx update
}

@test "update: sucesso, já atualizado, falha parcial de plugin e falha" {
  DRY='{"currentVersion":"2026.11.1","targetVersion":"2026.11.2"}' UPD_OUT=$'\e[32mUpdated\e[0m\n\nfeito' run update_openclaw
  [ "$status" -eq 0 ]
  [[ "$output" == *"OpenClaw atualizado com sucesso"* ]]
  [[ "$output" == *"feito"* ]]
  UPD_OUT="Already up to date" run update_openclaw
  [[ "$output" == *"já na versão mais recente."* ]]
  UPD_OUT="Failed to update plugin x" update_openclaw >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "OpenClaw: falha parcial ao atualizar plugins" ]
  UPD_OUT="erro" UPD_RC=5 run update_openclaw
  [ "$status" -eq 5 ]
}
