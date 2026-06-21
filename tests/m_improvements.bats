#!/usr/bin/env bats
# tests/m_improvements.bats — regressões das melhorias M2–M8

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/json.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
}

@test "snapshot_keep_count: default 5 e valores inválidos caem para 5" {
  unset SNAPSHOT_KEEP
  run snapshot_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]

  SNAPSHOT_KEEP=0 run snapshot_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]

  SNAPSHOT_KEEP=abc run snapshot_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "5" ]
}

@test "snapper_full_upgrade_ids_to_delete: mantém os N mais recentes do full-upgrade" {
  run bash -c 'source tests/test_helper.bash; load_libs; source "$FU_LIB/steps/cleanup.sh"; snapper_full_upgrade_ids_to_delete 2 <<EOF
10|manual snapshot
11|full-upgrade pré-upgrade 2026-01-01 10:00
12|full-upgrade pré-upgrade 2026-01-02 10:00
13|full-upgrade pré-upgrade 2026-01-03 10:00
14|outro full-upgrade texto estranho
EOF'
  [ "$status" -eq 0 ]
  [ "$output" = "11" ]
}

@test "summary_group_total_seconds: soma tempos de todas as categorias do grupo" {
  STEP_CATEGORIES=(flatpak docker snap editor shell doctor)
  STEP_RESULTS=(ok warn skip ok todo ok)
  STEP_TIMES=(3 7 0 2 5 11)

  run summary_group_total_seconds "flatpak docker snap"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]

  run summary_group_total_seconds "editor shell"
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "summary_slowest_steps: emite top N não-skip em ordem decrescente" {
  STEP_NAMES=(a b c d)
  STEP_RESULTS=(ok skip warn todo)
  STEP_TIMES=(4 100 9 5)

  run summary_slowest_steps 3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'9\tc\twarn' ]
  [ "${lines[1]}" = $'5\td\ttodo' ]
  [ "${lines[2]}" = $'4\ta\tok' ]
}

@test "summary_category_totals_json: inclui agregação por grupo no JSON" {
  STEP_CATEGORIES=(flatpak docker editor shell)
  STEP_RESULTS=(ok warn ok todo)
  STEP_TIMES=(3 7 2 5)

  run summary_category_totals_json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"Contêineres":{"duration_seconds":10,"ok":1,"warn":1,"todo":0,"fail":0,"skip":0}'* ]]
  [[ "$output" == *'"Shell / Editor":{"duration_seconds":7,"ok":1,"warn":0,"todo":1,"fail":0,"skip":0}'* ]]
}

@test "normalize_version/version_compare: helper comum trata v-prefix e sufixo git" {
  run normalize_version "v3.2.2-4-gabcdef"
  [ "$status" -eq 0 ]
  [ "$output" = "3.2.2" ]

  run version_compare "v3.2.10" "3.2.3"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "version_is_outdated: detecta instalado menor que latest" {
  run version_is_outdated "1.2.3" "1.2.4"
  [ "$status" -eq 0 ]

  run version_is_outdated "1.2.4" "1.2.4"
  [ "$status" -eq 1 ]
}

@test "remediation: imprime padrão reproduzível" {
  run remediation "sudo pacman -Syu"
  [ "$status" -eq 0 ]
  [ "$output" = "  Remediação: sudo pacman -Syu" ]
}

@test "resume_pending_steps: extrai só warn/todo/fail, em ordem, sem duplicar (L2)" {
  local j="${BATS_TEST_TMPDIR:-/tmp}/resume.jsonl"
  cat > "$j" <<'JSONL'
{"event":"run_start","run_id":"x"}
{"event":"step","step":"A ok","status":"ok"}
{"event":"step","step":"B warn","status":"warn"}
{"event":"step","step":"C skip","status":"skip"}
{"event":"step","step":"D todo","status":"todo"}
{"event":"step","step":"E fail","status":"fail"}
{"event":"step","step":"B warn","status":"warn"}
{"event":"run_end","run_id":"x"}
JSONL
  out="$(resume_pending_steps "$j")"
  [ "$out" = "B warn
D todo
E fail" ]
}

@test "resume_pending_steps: jsonl inexistente => rc 1" {
  run resume_pending_steps "/nao/existe.jsonl"
  [ "$status" -eq 1 ]
}

@test "resume_latest_real_jsonl: ignora dry-run e pega o run real mais recente (L2)" {
  local d="${BATS_TEST_TMPDIR:-/tmp}/logdir-$$"
  mkdir -p "$d"
  printf '%s\n' '{"event":"run_start","run_id":"real","dry_run":false}' > "$d/full-upgrade-real.jsonl"
  printf '%s\n' '{"event":"run_start","run_id":"dry","dry_run":true}'  > "$d/full-upgrade-dry.jsonl"
  touch -d '2026-06-21T10:00:00' "$d/full-upgrade-real.jsonl"
  touch -d '2026-06-21T11:00:00' "$d/full-upgrade-dry.jsonl"   # dry é mais novo
  LOG_DIR="$d" run resume_latest_real_jsonl
  [ "$status" -eq 0 ]
  [[ "$output" == *"full-upgrade-real.jsonl" ]]
  rm -rf "$d"
}

@test "journal_hint_for: applications.menu ausente dá dica de XDG menu" {
  out="$(journal_hint_for 'Error: "applications.menu" not found in QList(...)')"
  [[ "$out" == *"archlinux-xdg-menu"* ]]
}

@test "journal_hint_for: Bluetooth hci0 dá dica de transitório" {
  out="$(journal_hint_for 'Bluetooth: hci0: Opcode 0x0401 failed: -110')"
  [[ "$out" == *"Bluetooth"* ]]
}

@test "journal_hint_for: falha de auth sudo dá dica de PAM" {
  out="$(journal_hint_for 'pam_unix(sudo:auth): authentication failure; logname=bitter')"
  [[ "$out" == *"sudo/PAM"* ]]
}

@test "journal_hint_for: assinatura desconhecida não dá dica" {
  out="$(journal_hint_for 'kernel: some unrelated error xyz')"
  [ -z "$out" ]
}

@test "pending_is_held_cluster: reconhece toolchain Haskell/GHC" {
  run pending_is_held_cluster "haskell-aeson"
  [ "$status" -eq 0 ]
  run pending_is_held_cluster "ghc"
  [ "$status" -eq 0 ]
  run pending_is_held_cluster "ghc-libs"
  [ "$status" -eq 0 ]
  run pending_is_held_cluster "cabal-install"
  [ "$status" -eq 0 ]
}

@test "pending_is_held_cluster: pacote normal não é cluster segurado" {
  run pending_is_held_cluster "inkscape"
  [ "$status" -ne 0 ]
  run pending_is_held_cluster "python-tqdm"
  [ "$status" -ne 0 ]
  run pending_is_held_cluster "my-ghc-helper"
  [ "$status" -ne 0 ]
}

@test "final_pending_reason: separa pendências oficiais de AUR" {
  run final_pending_reason 2 0
  [ "$status" -eq 0 ]
  [ "$output" = "2 pacote(s) oficial(is) pendente(s) após sincronização da base; rode sudo pacman -Syu" ]

  run final_pending_reason 0 3
  [ "$status" -eq 0 ]
  [ "$output" = "3 pacote(s) AUR pendente(s); rode paru -Syu" ]
}

@test "build_warning_filter: suprime warnings allow-listed no terminal e mantém erros" {
  run build_warning_filter <<'EOF'
SetuptoolsDeprecationWarning: setup.py install is deprecated
already initialized constant RDoc::VERSION
ERROR: falha real
linha normal
EOF
  [ "$status" -eq 0 ]
  [[ "$output" != *"SetuptoolsDeprecationWarning"* ]]
  [[ "$output" != *"already initialized constant RDoc"* ]]
  [[ "$output" == *"2 warning(s) de build suprimido(s); veja o log completo."* ]]
  [[ "$output" == *"ERROR: falha real"* ]]
  [[ "$output" == *"linha normal"* ]]
}

@test "reboot_recommendation_from_reason: formata rodapé quando há motivo" {
  run reboot_recommendation_from_reason "kernel 7.0.11-arch1-1 → 7.0.12-arch1-1"
  [ "$status" -eq 0 ]
  [ "$output" = "Reboot recomendado: kernel 7.0.11-arch1-1 → 7.0.12-arch1-1" ]

  run reboot_recommendation_from_reason ""
  [ "$status" -eq 1 ]
}
