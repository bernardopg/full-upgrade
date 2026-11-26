#!/usr/bin/env bats
# tests/doctor_systemd.bats — regressões de auditoria systemd --user

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
}

@test "systemd_user_scope_status: sem XDG_RUNTIME_DIR é parcial" {
  unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "no-runtime" ]
}

@test "systemd_user_scope_status: runtime sem bus é parcial" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  unset DBUS_SESSION_BUS_ADDRESS
  mkdir -p "$XDG_RUNTIME_DIR"

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "no-bus" ]
}

@test "systemd_user_scope_status: bus por env torna checagem disponível" {
  unset XDG_RUNTIME_DIR
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$BATS_TEST_TMPDIR/bus"

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "available" ]
}

@test "systemd_user_scope_status: bus padrão no runtime torna checagem disponível" {
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
  unset DBUS_SESSION_BUS_ADDRESS
  mkdir -p "$XDG_RUNTIME_DIR"
  touch "$XDG_RUNTIME_DIR/bus"

  run systemd_user_scope_status
  [ "$status" -eq 0 ]
  [ "$output" = "available" ]
}

# ── doctor_failed_systemd_units: reclassificação de app-autostart ──────────────
# Units app-<nome>@autostart.service são geradas pelo systemd-xdg-autostart-
# generator (a partir de .desktop em ~/.config/autostart) com Restart=no. Ficam
# "failed" quando o app de sessão é fechado/KILLado — artefato do generator, não
# serviço quebrado. Se só há app-autostart, vira informativo (rc 0, não RC_TODO).

_setup_failed_units() {
  # $1 = saída de `systemctl --failed` (sistema); $2 = saída --user
  # Mocka systemctl e systemd_user_scope_status (que lê env/socket).
  has() { [[ "$1" == systemctl ]]; }
  systemctl() {
    # O doctor chama: systemctl --failed ...  e  systemctl --user --failed ...
    # e também list-units --state=auto-restart (loop de restart).
    local _loop
    if [[ "$1" == "--user" ]]; then _loop="${_MOCK_USER_LOOP:-}"; else _loop="${_MOCK_SYS_LOOP:-}"; fi
    if [[ " $* " == *" list-units "* ]]; then printf '%s' "$_loop"; return 0; fi
    if [[ " $* " == *" show "* ]]; then
      local _u _l _a _sub
      while read -r _u _l _a _sub _ || [[ -n "${_u:-}" ]]; do
        [[ -n "$_u" ]] || continue
        printf 'Id=%s\nSubState=%s\nNRestarts=%s\n\n' "$_u" "$_sub" "${_MOCK_NRESTARTS:-0}"
      done <<<"$_loop"
      return 0
    fi
    if [[ "$1" == "--user" ]]; then
      printf '%s' "$_MOCK_USER_FAILED"
    else
      printf '%s' "$_MOCK_SYS_FAILED"
    fi
  }
  systemd_user_scope_status() { printf 'available'; }
  export _MOCK_SYS_FAILED="$1" _MOCK_USER_FAILED="$2"
}

@test "failed_units: sem units falhadas => rc 0" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma unit systemd falhada"* ]]
}

@test "failed_units: unit de serviço real falhada => RC_TODO" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" "nginx.service loaded failed failed failed"
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"nginx.service"* ]]
}

@test "failed_units: só app-autostart => rc 0 (informativo, não TODO)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" "app-9router@autostart.service loaded failed failed 9Router"
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"unit(s) gerada(s) para app de sessão em estado failed"* ]]
  [[ "$output" == *"app-9router@autostart.service"* ]]
  [[ "$output" == *"Nenhuma unit de serviço real falhada"* ]]
}

@test "failed_units: scope transitório de app => rc 0 (informativo, não TODO)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" "app-orca-87907.scope loaded failed failed app-orca-87907.scope"
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-orca-87907.scope"* ]]
  [[ "$output" == *"Nenhuma unit de serviço real falhada"* ]]
}

@test "failed_units: scope de systemd-run (t3code-*.scope) => rc 0 (informativo)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" "t3code-claude-62154908.scope loaded failed failed [systemd-run] claude"
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"t3code-claude-62154908.scope"* ]]
  [[ "$output" == *"Nenhuma unit de serviço real falhada"* ]]
}

@test "failed_units: app-autostart + unit real => RC_TODO (a real prevalece)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" \
    $'app-foo@autostart.service loaded failed failed Foo\nnginx.service loaded failed failed failed'
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"nginx.service"* ]]
  [[ "$output" == *"app-foo@autostart.service"* ]]
}

@test "failed_units: unit de sistema falhada + app-autostart => RC_TODO" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "docker.service loaded failed failed failed" \
    "app-bar@autostart.service loaded failed failed Bar"
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"docker.service"* ]]
}

# ── loop de restart: unit em auto-restart nunca fica "failed" ─────────────────

_setup_loop_journal() {
  # $1 = falhas por unit no journal do boot atual
  export _MOCK_FAILS="$1"
  journalctl() {
    local i
    for (( i=0; i<_MOCK_FAILS; i++ )); do echo "x.service: Failed with result 'exit-code'."; done
  }
}

@test "failed_units: unit --user em loop de restart => RC_TODO com contagem" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  export _MOCK_USER_LOOP="bw-autounlock.service loaded activating auto-restart Bitwarden"
  _setup_loop_journal 31
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"bw-autounlock.service (usuário): 31 falha(s) neste boot"* ]]
  [[ "$output" != *"Nenhuma unit systemd falhada"* ]]
}

@test "failed_units: uma retentativa isolada em auto-restart não é loop" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  export _MOCK_SYS_LOOP="net.service loaded activating auto-restart Net"
  _setup_loop_journal 1
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhuma unit systemd falhada"* ]]
}

@test "failed_units: unit falhada + loop somam no motivo" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "nginx.service loaded failed failed nginx" ""
  export _MOCK_SYS_LOOP="net.service loaded activating auto-restart Net"
  _setup_loop_journal 5
  doctor_failed_systemd_units >/dev/null || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"1 unit(s) sistema"*"+ 1 em loop de restart"* ]]
}

@test "failed_units: oneshot em loop pego na fase activating (NRestarts>0)" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  export _MOCK_USER_LOOP="bw-autounlock.service loaded activating start Bitwarden"
  export _MOCK_NRESTARTS=9
  _setup_loop_journal 12
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"bw-autounlock.service (usuário): 12 falha(s)"* ]]
}

@test "failed_units: start normal em andamento (NRestarts=0) não é loop" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  export _MOCK_USER_LOOP="slow.service loaded activating start Slow"
  export _MOCK_NRESTARTS=0
  _setup_loop_journal 9
  run doctor_failed_systemd_units
  [ "$status" -eq 0 ]
}

@test "failed_units: oneshot que enfim passou após muitos restarts ainda é loop" {
  QUIET=0 LOG_FILE=/dev/null
  _setup_failed_units "" ""
  export _MOCK_USER_LOOP="bw-autounlock.service loaded inactive dead Bitwarden"
  export _MOCK_NRESTARTS=16
  _setup_loop_journal 43
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"bw-autounlock.service (usuário): 43 falha(s)"* ]]
}

@test "systemd_restart_candidates: ordem livre de propriedades e último bloco sem linha vazia" {
  run systemd_restart_candidates <<<$'NRestarts=0\nId=a.service\nSubState=running\n\nSubState=auto-restart\nId=b.service\nNRestarts=0\n\nId=c.service\nNRestarts=4\nSubState=dead'
  [ "$output" = $'b.service\nc.service' ]
}
