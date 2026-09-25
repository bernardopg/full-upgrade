#!/usr/bin/env bats
# tests/opencode.bats — atualização do opencode (H1).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  QUIET=0
  STEP_REASON=""
}

@test "opencode: ausente retorna 0" {
  has() { return 1; }
  run update_opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "opencode: upgrade ok retorna 0 e loga versões" {
  has() { [[ "$1" == opencode ]]; }
  opencode() {
    case "$1" in
      --version) printf '0.5.0\n' ;;
      upgrade)   printf 'upgraded\n' ;;
    esac
  }
  run_network_cmd() { opencode upgrade; return 0; }
  run update_opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode atual"* ]]
  [[ "$output" == *"opencode agora"* ]]
}

@test "opencode: falha de rede vira RC_WARN" {
  has() { [[ "$1" == opencode ]]; }
  opencode() { [[ "$1" == --version ]] && printf '0.5.0\n'; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run update_opencode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}

@test "opencode: falha não-rede do upgrade vira RC_WARN (não fatal)" {
  has() { [[ "$1" == opencode ]]; }
  opencode() { [[ "$1" == --version ]] && printf '0.5.0\n'; }
  run_network_cmd() { printf 'erro qualquer\n'; return 1; }
  run update_opencode
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao atualizar"* ]]
}

@test "opencode-style: 'Upgrade failed' com rc 0 vira RC_WARN (kilo)" {
  has() { [[ "$1" == kilo ]]; }
  kilo() { [[ "$1" == --version ]] && printf '7.3.16\n'; }
  run_network_cmd() { printf '■  Upgrade failed\n■  bash: linha 1: `<!DOCTYPE html>\n'; return 0; }
  curl() { echo '<!DOCTYPE html>'; }
  run update_kilo
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"kilo (Kilo Code CLI): falha ao atualizar"* ]]
  [[ "$output" == *"não devolveu um script bash"* ]]
}

@test "kilo: upgrade nativo quebrado cai para o instalador oficial" {
  has() { [[ "$1" == kilo ]]; }
  kilo() { [[ "$1" == --version ]] && printf '7.8.1\n'; }
  run_network_cmd() {
    if [[ "$1" == kilo ]]; then printf '■  Upgrade failed\n'; return 0; fi
    printf '#!/usr/bin/env bash\necho instalado\n'
  }
  run update_kilo
  [ "$status" -eq 0 ]
  [[ "$output" == *"instalado"* ]]
}

@test "opencode-style: mimo usa o mesmo fluxo de upgrade" {
  has() { [[ "$1" == mimo ]]; }
  mimo() { [[ "$1" == --version ]] && printf '0.1.14\n'; }
  run_network_cmd() { printf '●  From 0.1.3 → 0.1.14\n└  Done\n'; return 0; }
  run update_mimo
  [ "$status" -eq 0 ]
  [[ "$output" == *"mimo (MiMo Code) agora: 0.1.14"* ]]
}
