#!/usr/bin/env bats
# tests/final_check_managers.bats — verificação final dos gerenciadores de
# linguagem. Todos os gerenciadores são stubs no PATH do tmpdir: nenhum comando
# real (npm/pnpm/cargo/gem/flatpak) é executado.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_other.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"

  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$BIN"
  PATH="${BIN}:${PATH}"
  STEP_REASON=""

  # Todos os gerenciadores nascem stubados e silenciosos. Sem isso, um teste que
  # stuba só o npm deixaria cargo/gem/flatpak reais rodarem (I/O de rede lento).
  local m
  for m in pnpm cargo-install-update gem flatpak; do
    stub "$m" ""
  done
  # Isola o prefixo secundário do ~/.npm-global real da máquina de teste.
  NPM_CONFIG_PREFIX="${BATS_TEST_TMPDIR}/npm-sec"
  stub_npm
}

# O npm precisa responder a dois subcomandos diferentes: `config get prefix`
# (usado por npm_global_writable, que porteia o bloco npm) e `outdated`. O
# conteúdo de outdated vem de um arquivo que cada teste sobrescreve.
stub_npm() {
  NPM_PREFIX="${BATS_TEST_TMPDIR}/npm-prefix"
  mkdir -p "${NPM_PREFIX}/lib/node_modules"
  : > "${BIN}/npm-outdated.txt"
  : > "${BIN}/npm-outdated-sec.txt"
  {
    echo '#!/usr/bin/env bash'
    echo 'case "$*" in'
    echo "  *'config get prefix'*) printf '%s\\n' \"${NPM_PREFIX}\" ;;"
    echo "  *'--prefix'*) cat \"${BIN}/npm-outdated-sec.txt\" ;;"
    echo "  *outdated*) cat \"${BIN}/npm-outdated.txt\" ;;"
    echo 'esac'
  } > "${BIN}/npm"
  chmod +x "${BIN}/npm"
}

npm_outdated_lines() {
  printf '%s\n' "$1" > "${BIN}/npm-outdated.txt"
}

# Cria o prefixo secundário stubado e define as linhas de outdated dele.
npm_sec_outdated_lines() {
  mkdir -p "${NPM_CONFIG_PREFIX}/lib/node_modules"
  printf '%s\n' "$1" > "${BIN}/npm-outdated-sec.txt"
}

# Cria um executável fake que imprime $2 e sai com $3 (default 0).
stub() {
  local name="$1" out="$2" rc="${3:-0}"
  {
    echo '#!/usr/bin/env bash'
    printf 'cat <<%s\n%s\n%s\n' "'EOF'" "$out" "EOF"
    echo "exit ${rc}"
  } > "${BIN}/${name}"
  chmod +x "${BIN}/${name}"
}

@test "_count_lines: string vazia conta 0" {
  run _count_lines ""
  [ "$output" = "0" ]
}

@test "_count_lines: só espaços em branco conta 0" {
  run _count_lines "$(printf '  \n \n')"
  [ "$output" = "0" ]
}

@test "_count_lines: conta apenas linhas com conteúdo" {
  run _count_lines "$(printf 'a\n\nb\n')"
  [ "$output" = "2" ]
}

@test "final_check_managers: tudo em dia devolve ok" {
  run final_check_managers
  [ "$status" -eq 0 ]
}

@test "final_check_managers: npm global desatualizado vira todo" {
  # npm outdated -g --parseable emite uma linha por pacote desatualizado.
  npm_outdated_lines "/home/u/.npm-global/lib/node_modules/foo:foo@2.0.0:foo@1.0.0:foo@2.0.0"

  run final_check_managers
  [ "$status" -eq "$RC_TODO" ]
}

@test "final_check_managers: motivo do todo cita o gerenciador e a contagem" {
  npm_outdated_lines "/x/foo:foo@2:foo@1:foo@2"

  final_check_managers || true
  [[ "$STEP_REASON" == *"npm global (1)"* ]]
}

@test "final_check_managers: prefixo secundário desatualizado vira todo" {
  npm_sec_outdated_lines "/home/u/.npm-global/lib/node_modules/kimi:kimi@2:kimi@1:kimi@2"

  local rc=0
  final_check_managers || rc=$?
  [ "$rc" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"npm global secundário (1)"* ]]
}

@test "final_check_managers: prefixo secundário igual ao ativo não duplica aviso" {
  NPM_CONFIG_PREFIX="${NPM_PREFIX}"
  npm_outdated_lines "/x/foo:foo@2:foo@1:foo@2"

  final_check_managers || true
  [[ "$STEP_REASON" == *"npm global (1)"* ]]
  [[ "$STEP_REASON" != *"secundário"* ]]
}

@test "final_check_managers: prefixo secundário inexistente é ignorado" {
  rm -rf "${NPM_CONFIG_PREFIX}"

  run final_check_managers
  [ "$status" -eq 0 ]
}

@test "final_check_managers: cargo conta só binários com 'Needs update' Yes" {
  stub cargo-install-update "$(printf 'Package  Installed  Latest  Needs update\nfoo  v1  v2  Yes\nbar  v1  v1  No\n')"

  final_check_managers || true
  [[ "$STEP_REASON" == *"cargo (1)"* ]]
}

@test "final_check_managers: flatpak pendente entra no motivo" {
  stub flatpak "org.exemplo.App"

  final_check_managers || true
  [[ "$STEP_REASON" == *"flatpak (1)"* ]]
}

@test "final_check_managers: pendências em vários gerenciadores somam no motivo" {
  npm_outdated_lines "/x/foo:foo@2:foo@1:foo@2"
  stub flatpak "org.exemplo.App"

  final_check_managers || true
  [[ "$STEP_REASON" == *"npm global (1)"* ]]
  [[ "$STEP_REASON" == *"flatpak (1)"* ]]
}

@test "final_check_managers: pnpm global sem manifest não vira pendência (falso positivo)" {
  # pnpm -g outdated emite ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND no stdout (exit 0)
  # quando o global não tem package.json: significa "sem pacotes globais",
  # não "desatualizado".
  stub pnpm 'ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND No package.json was found in "/home/u/.local/share/pnpm/global/5".'

  run final_check_managers
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm global"* ]]
}

@test "final_check_managers: pnpm global realmente desatualizado continua virando pendência" {
  # Guarda de regressão: o filtro do manifest não pode engolir uma lista real.
  stub pnpm "foo 1.0.0 -> 2.0.0"

  final_check_managers || true
  [[ "$STEP_REASON" == *"pnpm global"* ]]
}
