#!/usr/bin/env bats
# tests/lang_js.bats — helpers puros de steps/lang_js.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  # `npm_global_prefix` real chama `npm config get prefix` (I/O + ambiente);
  # nos testes substituímos por um stub que devolve um caminho do tmpdir.
  # Usamos _npm_prefix (não `prefix`) para não colidir com o `local prefix`
  # declarado dentro das funções testadas (evita shadowing).
  log() { :; }
}

@test "npm_global_writable: true quando lib/node_modules é gravável em \$HOME" {
  _npm_prefix="$BATS_TEST_TMPDIR/npm-home"
  mkdir -p "$_npm_prefix/lib/node_modules"
  npm_global_prefix() { printf '%s' "$_npm_prefix"; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_global_writable: false quando prefixo é root/pacman (não gravável)" {
  _npm_prefix="$BATS_TEST_TMPDIR/npm-root"
  mkdir -p "$_npm_prefix/lib/node_modules"
  chmod a-w "$_npm_prefix/lib/node_modules"
  npm_global_prefix() { printf '%s' "$_npm_prefix"; }
  run npm_global_writable
  [ "$status" -ne 0 ]
  chmod u+w "$_npm_prefix/lib/node_modules"
}

@test "npm_global_writable: prefixo vazio não bloqueia (retorna true)" {
  npm_global_prefix() { :; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_global_writable: sem lib/node_modules checa gravabilidade do próprio prefix" {
  _npm_prefix="$BATS_TEST_TMPDIR/npm-flat"
  mkdir -p "$_npm_prefix"
  npm_global_prefix() { printf '%s' "$_npm_prefix"; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_audit_prefix: prefixo /usr sinaliza conflito com pacman (RC_WARN)" {
  npm_global_prefix() { printf '%s' '/usr'; }
  run npm_audit_prefix
  [ "$status" -eq "$RC_WARN" ]
}

@test "npm_audit_prefix: prefixo em \$HOME é seguro (0)" {
  # npm_audit_prefix só inspeciona a string do prefixo (não testa o filesystem),
  # então um caminho /home/* literal basta — não precisa existir em disco.
  npm_global_prefix() { printf '%s' '/home/usuario/.npm-global'; }
  run npm_audit_prefix
  [ "$status" -eq 0 ]
}

@test "npm_allow_scripts_packages: extrai pacotes bloqueados pelo npm" {
  out="$(printf '%s\n' \
    'npm warn allow-scripts 2 packages have install scripts not yet covered by allowScripts:' \
    'npm warn allow-scripts   better-sqlite3@12.11.1 (install: prebuild-install || node-gyp rebuild --release)' \
    'npm warn allow-scripts   @scope/native-addon@1.2.3 (install: node-gyp rebuild)' \
    'npm warn allow-scripts' \
    'changed 2 packages in 1s' \
    | npm_allow_scripts_packages)"
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 2 ]
  [[ "$out" == *"better-sqlite3"* ]]
  [[ "$out" == *"@scope/native-addon"* ]]
}

# ── npm_audit_prefix (decisão de severidade por prefixo) ──────────────────────
@test "npm_audit_prefix: prefixo / => recusa (rc 1)" {
  log() { :; }; remediation() { :; }
  npm_global_prefix() { echo "/"; }
  run npm_audit_prefix
  [ "$status" -eq 1 ]
}

@test "npm_audit_prefix: /usr ou /usr/local => RC_WARN" {
  log() { :; }; remediation() { :; }
  npm_global_prefix() { echo "/usr"; }
  run npm_audit_prefix; [ "$status" -eq "$RC_WARN" ]
  npm_global_prefix() { echo "/usr/local"; }
  run npm_audit_prefix; [ "$status" -eq "$RC_WARN" ]
}

@test "npm_audit_prefix: prefixo no HOME => 0" {
  log() { :; }; remediation() { :; }
  npm_global_prefix() { echo "$HOME/.local"; }
  run npm_audit_prefix
  [ "$status" -eq 0 ]
}

@test "npm_audit_prefix: caminho incomum => RC_WARN" {
  log() { :; }; remediation() { :; }
  npm_global_prefix() { echo "/opt/weird"; }
  run npm_audit_prefix
  [ "$status" -eq "$RC_WARN" ]
}

@test "npm_audit_prefix: prefixo vazio => 0 (não detectado)" {
  log() { :; }; remediation() { :; }
  npm_global_prefix() { echo ""; }
  run npm_audit_prefix
  [ "$status" -eq 0 ]
}

# ── npm_allow_scripts_packages (parser de warnings) ───────────────────────────
@test "npm_allow_scripts_packages: extrai nomes sem versão, dedup e ordena" {
  in=$'npm warn allow-scripts better-sqlite3@11.0.0\nnpm warn allow-scripts esbuild@0.20.0\nnpm warn allow-scripts better-sqlite3@11.0.0\noutra linha irrelevante'
  run npm_allow_scripts_packages <<<"$in"
  [ "${lines[0]}" = "better-sqlite3" ]
  [ "${lines[1]}" = "esbuild" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "npm_allow_scripts_packages: scoped package preserva escopo" {
  in='npm warn allow-scripts @org/native@2.1.0'
  run npm_allow_scripts_packages <<<"$in"
  [ "$output" = "@org/native" ]
}

@test "npm_allow_scripts_packages: sem warnings => vazio" {
  run npm_allow_scripts_packages <<<"tudo ok aqui"
  [ -z "$output" ]
}

# ── npm_global_writable ───────────────────────────────────────────────────────
@test "npm_global_writable: prefixo desconhecido => 0 (não bloqueia)" {
  npm_global_prefix() { echo ""; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

@test "npm_global_writable: diretório gravável => 0" {
  local d="$BATS_TEST_TMPDIR/npmpfx"; mkdir -p "$d/lib/node_modules"
  npm_global_prefix() { echo "$d"; }
  run npm_global_writable
  [ "$status" -eq 0 ]
}

# ── update_pnpm_self ─────────────────────────────────────────────────────────

@test "update_pnpm_self: já atualizado não chama self-update" {
  local called="$BATS_TEST_TMPDIR/pnpm-called"
  npm() { printf '11.12.0\n'; }
  pnpm() {
    [[ "${1:-}" == "--version" ]] && { printf '11.12.0\n'; return 0; }
    : > "$called"
    return 99
  }
  run update_pnpm_self
  [ "$status" -eq 0 ]
  [ ! -e "$called" ]
}

@test "update_pnpm_self: falha do self-update usa fallback global e verifica versão" {
  local state="$BATS_TEST_TMPDIR/pnpm-version"
  printf '11.11.0\n' > "$state"
  pnpm_global_project_dir() { printf '%s\n' "$BATS_TEST_TMPDIR/pnpm-global"; }
  mkdir -p "$BATS_TEST_TMPDIR/pnpm-global"
  npm() {
    if [[ "${1:-}" == "view" ]]; then
      printf '11.12.0\n'
    elif [[ "${1:-}" == "install" ]]; then
      printf '11.12.0\n' > "$state"
      return 0
    fi
  }
  pnpm() {
    if [[ "${1:-}" == "--version" ]]; then
      read -r _v < "$state"; printf '%s\n' "$_v"; return 0
    fi
    if [[ "${1:-}" == "self-update" ]]; then
      printf "Cannot use 'in' operator to search for 'integrity' in undefined\n"
      return 1
    fi
    return 99
  }
  run update_pnpm_self
  [ "$status" -eq 0 ]
  [ "$(<"$state")" = "11.12.0" ]
}

@test "update_pnpm_self: falha do self-update e fallback continua sendo falha" {
  pnpm_global_project_dir() { printf '%s\n' "$BATS_TEST_TMPDIR/pnpm-global"; }
  mkdir -p "$BATS_TEST_TMPDIR/pnpm-global"
  npm() {
    [[ "${1:-}" == "view" ]] && { printf '11.12.0\n'; return 0; }
    return 7
  }
  pnpm() {
    [[ "${1:-}" == "--version" ]] && { printf '11.11.0\n'; return 0; }
    return 7
  }
  run update_pnpm_self
  [ "$status" -eq 7 ]
}
