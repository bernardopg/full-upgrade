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
