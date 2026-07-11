#!/usr/bin/env bats
# tests/openclaw.bats — helper puro do gate de update do OpenClaw (steps.d).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/60-openclaw.sh"
}

@test "openclaw_update_available: versões iguais => não há update (rc 1)" {
  run openclaw_update_available '{"currentVersion":"2026.6.10","targetVersion":"2026.6.10"}'
  [ "$status" -eq 1 ]
}

@test "openclaw_update_available: versões diferentes => há update (rc 0)" {
  run openclaw_update_available '{"currentVersion":"2026.6.10","targetVersion":"2026.7.1"}'
  [ "$status" -eq 0 ]
}

@test "openclaw_update_available: JSON sem campos => indeterminado, não pula (rc 0)" {
  run openclaw_update_available '{"foo":"bar"}'
  [ "$status" -eq 0 ]
}

@test "openclaw_update_available: tolera espaços no JSON" {
  run openclaw_update_available '{ "currentVersion" : "1.0.0" , "targetVersion" : "1.0.0" }'
  [ "$status" -eq 1 ]
}

@test "openclaw_update_available: target null usa fallback igual" {
  run openclaw_update_available '{"currentVersion":"2026.6.11","targetVersion":null}' '2026.6.11'
  [ "$status" -eq 1 ]
}

@test "openclaw_update_available: target null usa fallback mais novo" {
  run openclaw_update_available '{"currentVersion":"2026.6.11","targetVersion":null}' '2026.6.12'
  [ "$status" -eq 0 ]
}

@test "openclaw_registry_version: extrai versão de JSON array do npm 12" {
  run openclaw_registry_version <<< '["2026.6.11"]'
  [ "$output" = "2026.6.11" ]
}

@test "openclaw_update_has_partial_failure: detecta plugin desabilitado após falha" {
  run openclaw_update_has_partial_failure <<< 'Disabled "brave" after plugin update failure; Failed to update brave'
  [ "$status" -eq 0 ]
}

@test "openclaw_update_has_partial_failure: update limpo não casa" {
  run openclaw_update_has_partial_failure <<< 'Gateway: restarted and verified.'
  [ "$status" -ne 0 ]
}
