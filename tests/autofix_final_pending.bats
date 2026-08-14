#!/usr/bin/env bats
# tests/autofix_final_pending.bats — retry AUR de autofix_final_pending
# (lib/steps/cleanup.sh) e o sidecar de falhas de build (lib/core.sh).

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/lib/steps/cleanup.sh"

  MOCKDIR="$(mktemp -d)"
  BINDIR="$MOCKDIR/bin"
  mkdir -p "$BINDIR"
  PATH="$BINDIR:$PATH"

  # Estado de run isolado: o sidecar é nomeado por RUN_ID dentro de LOG_DIR.
  LOG_DIR="$MOCKDIR/logs"
  mkdir -p "$LOG_DIR"
  RUN_ID="testrun"
  AUTO_FIX_FINAL_PENDING=1
  QUIET=0
  export LOG_FILE="/dev/null"

  # Sem pendências oficiais: o foco dos testes é o ramo AUR.
  stub checkupdates ""
}

teardown() {
  rm -rf "$MOCKDIR"
}

# cria um executável falso que ecoa "$2" e sai 0, registrando a chamada
stub() {
  local name="$1" out="$2" rc="${3:-0}"
  cat > "$BINDIR/$name" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$MOCKDIR/${name}.calls"
printf '%s' '${out}'
[[ -n '${out}' ]] && printf '\n'
exit ${rc}
EOF
  chmod +x "$BINDIR/$name"
}

@test "aur_build_failed_file: caminho por RUN_ID dentro de LOG_DIR" {
  run aur_build_failed_file
  [ "$output" = "${LOG_DIR}/full-upgrade-testrun.aur-build-failed" ]
}

@test "autofix_final_pending: pendência só de pacote com build quebrado => pula retry" {
  # Falha de compilação é determinística: recompilar do zero no mesmo run só
  # queima minutos para falhar igual (medido: 1m43s com pcsx2 vs ffmpeg 8).
  stub paru "pcsx2 2.6.3-2 -> 2.6.3-3"
  AUR_HELPER=paru
  printf 'pcsx2\n' > "$(aur_build_failed_file)"

  run autofix_final_pending
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"retry pulado"* ]]
  [[ "$output" == *"pcsx2"* ]]
  # o retry (paru -Sua) não pode ter sido invocado
  ! grep -q -- "-Sua" "$MOCKDIR/paru.calls"
}

@test "autofix_final_pending: pendência de outro pacote ainda tenta retry" {
  stub paru "outro-pkg 1.0 -> 1.1"
  AUR_HELPER=paru
  printf 'pcsx2\n' > "$(aur_build_failed_file)"

  run autofix_final_pending
  # o retry deve ter acontecido para o pacote não-quebrado
  grep -q -- "-Sua" "$MOCKDIR/paru.calls"
  # e o pacote com build quebrado entra como --ignore
  grep -q -- "--ignore=pcsx2" "$MOCKDIR/paru.calls"
}

@test "autofix_final_pending: sem sidecar, comportamento de retry é o de sempre" {
  stub paru "pcsx2 2.6.3-2 -> 2.6.3-3"
  AUR_HELPER=paru
  [ ! -e "$(aur_build_failed_file)" ]

  run autofix_final_pending
  grep -q -- "-Sua" "$MOCKDIR/paru.calls"
}

@test "autofix_final_pending: desligado não faz nada" {
  AUTO_FIX_FINAL_PENDING=0
  run autofix_final_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"desligado"* ]]
}
