#!/usr/bin/env bats
# tests/kimi.bats — atualização do Kimi CLI (H5).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  QUIET=0
  STEP_REASON=""
}

@test "kimi: ausente retorna 0" {
  has() { return 1; }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "kimi: npm global no prefixo ativo => RC 0 e menciona cobertura do step npm" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.18.0\n'; }
  npm() { printf '@moonshot-ai/kimi-code@0.18.0\n'; }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"kimi atual: 0.18.0"* ]]
  [[ "$output" == *"coberto por 'Atualizar npm global'"* ]]
}

@test "kimi: npm global em prefixo estrangeiro já na latest => no-op RC 0" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.37.1\n'; }
  command() {
    if [[ "$1" == -v && "$2" == kimi ]]; then
      printf '/home/u/.npm-global/bin/kimi\n'
      return 0
    fi
    builtin command "$@"
  }
  readlink() {
    printf '/home/u/.npm-global/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs\n'
  }
  local args_file="${BATS_TEST_TMPDIR}/npm.args"
  : >"$args_file"
  npm() {
    [[ "$1" == "view" ]] && { printf '0.37.1\n'; return 0; }
    printf '%s\n' "$*" >>"$args_file"
    return 1
  }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"já na versão mais recente (0.37.1)"* ]]
  [[ "$(cat "$args_file")" != *"install"* ]]
}

@test "kimi: npm global em prefixo estrangeiro => npm install -g --prefix lá" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.36.1\n'; }
  command() {
    if [[ "$1" == -v && "$2" == kimi ]]; then
      printf '/home/u/.npm-global/bin/kimi\n'
      return 0
    fi
    builtin command "$@"
  }
  readlink() {
    printf '/home/u/.npm-global/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs\n'
  }
  local args_file="${BATS_TEST_TMPDIR}/npm.args"
  : >"$args_file"
  npm() {
    [[ "$1" == "view" ]] && { printf '0.37.1\n'; return 0; }
    printf '%s\n' "$*" >>"$args_file"
    printf 'added 1 package in 2s\n'
  }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"fora do npm ativo"* ]]
  [[ "$output" == *"kimi agora: 0.36.1"* ]]
  local args
  args="$(cat "$args_file")"
  [[ "$args" == *"--prefix /home/u/.npm-global"* ]]
  [[ "$args" == *"@moonshot-ai/kimi-code@latest"* ]]
}

@test "kimi: prefixo estrangeiro com scripts bloqueados => RC_TODO + remediação --allow-scripts" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.36.1\n'; }
  command() {
    if [[ "$1" == -v && "$2" == kimi ]]; then
      printf '/home/u/.npm-global/bin/kimi\n'
      return 0
    fi
    builtin command "$@"
  }
  readlink() {
    printf '/home/u/.npm-global/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs\n'
  }
  npm() {
    [[ "$1" == "ls" || "$1" == "view" ]] && { [[ "$1" == "view" ]] && printf '0.37.1\n'; return 0; }
    printf 'npm warn install-scripts 2 packages had install scripts blocked\n'
    printf 'npm warn install-scripts   @moonshot-ai/kimi-code@0.37.1 (postinstall: node scripts/postinstall.mjs)\n'
    printf 'npm warn install-scripts   node-pty@1.1.0 (install: node scripts/prebuild.js)\n'
  }
  run update_kimi
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"bloqueou script(s) de install em: @moonshot-ai/kimi-code node-pty"* ]]
  [[ "$output" == *"--allow-scripts=@moonshot-ai/kimi-code,node-pty"* ]]
}

@test "kimi: prefixo estrangeiro com falha de npm => RC_WARN" {
  has() { [[ "$1" == kimi ]]; }
  kimi() { [[ "$1" == --version ]] && printf '0.36.1\n'; }
  command() {
    if [[ "$1" == -v && "$2" == kimi ]]; then
      printf '/home/u/.npm-global/bin/kimi\n'
      return 0
    fi
    builtin command "$@"
  }
  readlink() {
    printf '/home/u/.npm-global/lib/node_modules/@moonshot-ai/kimi-code/dist/main.mjs\n'
  }
  npm() {
    [[ "$1" == "view" ]] && { printf '0.37.1\n'; return 0; }
    printf 'npm error code E404\n' >&2
    return 1
  }
  run update_kimi
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao atualizar"* ]]
}

@test "kimi: standalone com updater oficial OK => RC 0" {
  has() { [[ "$1" == kimi ]]; }
  kimi() {
    if [[ "$1" == --version ]]; then printf '0.36.1\n'; return 0; fi
    [[ "$1" == update ]] && printf 'Kimi Code updated to 0.37.1\n'
  }
  npm() { :; }
  run update_kimi
  [ "$status" -eq 0 ]
  [[ "$output" == *"updater oficial 'kimi update'"* ]]
  [[ "$output" == *"kimi agora: 0.36.1"* ]]
}

@test "kimi: standalone com layout não suportado pelo updater => RC_TODO" {
  has() { [[ "$1" == kimi ]]; }
  kimi() {
    if [[ "$1" == --version ]]; then printf '0.36.1\n'; return 0; fi
    [[ "$1" == update ]] && printf 'Detected install source: unsupported package manager or layout.\nTo update manually, run: npm install -g @moonshot-ai/kimi-code@0.37.1\n'
  }
  npm() { :; }
  run update_kimi
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"não reconhece esta instalação"* ]]
}
