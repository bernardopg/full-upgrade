#!/usr/bin/env bats
# tests/commitlint.bats — portão local de Conventional Commits e instalação dos
# hooks usados pelo fluxo de push direto na main.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  VALIDATOR="${ROOT}/scripts/validate-commit-msg.sh"
  MSG="${BATS_TEST_TMPDIR}/COMMIT_EDITMSG"
}

_validate() {
  printf '%s\n' "$1" > "$MSG"
  run "$VALIDATOR" "$MSG"
}

@test "commitlint local: aceita tipo, escopo e breaking change convencionais" {
  _validate 'feat(ai)!: altera contrato do updater'
  [ "$status" -eq 0 ]
}

@test "commitlint local: aceita todos os tipos da configuração" {
  local type
  for type in feat fix docs style refactor perf test build ci chore revert; do
    printf '%s: mensagem válida\n' "$type" > "$MSG"
    "$VALIDATOR" "$MSG"
  done
}

@test "commitlint local: rejeita formato sem tipo e separador" {
  _validate 'corrige o updater'
  [ "$status" -ne 0 ]
  [[ "$output" == *"formato não convencional"* ]]
}

@test "commitlint local: rejeita tipo fora do enum do JSON" {
  _validate 'feature: tipo inventado'
  [ "$status" -ne 0 ]
  [[ "$output" == *"não permitido"* ]]
}

@test "commitlint local: rejeita cabeçalho acima de 100 caracteres" {
  local subject
  printf -v subject '%*s' 96 ''
  subject="${subject// /x}"
  _validate "fix: ${subject}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"excede 100"* ]]
}

@test "commitlint local: ignora mensagens geradas pelo Git como o commitlint oficial" {
  local message
  for message in 'Merge branch main' 'Revert "feat: algo"' 'fixup! feat: algo' 'squash! fix: algo'; do
    printf '%s\n' "$message" > "$MSG"
    "$VALIDATOR" "$MSG"
  done
}

@test "commitlint local: lê tipos e limite da configuração, sem valores duplicados" {
  local config="${BATS_TEST_TMPDIR}/commitlint.json"
  cat > "$config" <<'JSON'
{"rules":{"type-enum":[2,"always",["custom"]],"header-max-length":[2,"always",20]}}
JSON
  printf 'custom: mensagem\n' > "$MSG"
  run env COMMITLINT_CONFIG="$config" "$VALIDATOR" "$MSG"
  [ "$status" -eq 0 ]

  printf 'fix: mensagem\n' > "$MSG"
  run env COMMITLINT_CONFIG="$config" "$VALIDATOR" "$MSG"
  [ "$status" -ne 0 ]
}

@test "commitlint local: configuração inválida falha explicitamente" {
  local config="${BATS_TEST_TMPDIR}/commitlint.json"
  printf '{json quebrado\n' > "$config"
  printf 'fix: mensagem\n' > "$MSG"

  run env COMMITLINT_CONFIG="$config" "$VALIDATOR" "$MSG"
  [ "$status" -eq 2 ]
  [[ "$output" == *"não foi possível ler"* ]]
}

@test "install-hooks: instala commit-msg e pre-push gerenciados" {
  local hooks="${BATS_TEST_TMPDIR}/hooks"
  run env FULL_UPGRADE_HOOK_DIR="$hooks" "${ROOT}/scripts/install-hooks.sh"
  [ "$status" -eq 0 ]
  [ -x "${hooks}/commit-msg" ]
  [ -x "${hooks}/pre-push" ]
  grep -q 'validate-commit-msg.sh' "${hooks}/commit-msg"
  grep -q 'preflight.sh' "${hooks}/pre-push"
}

@test "install-hooks: nunca sobrescreve hook customizado" {
  local hooks="${BATS_TEST_TMPDIR}/hooks"
  mkdir -p "$hooks"
  printf '#!/bin/sh\necho custom\n' > "${hooks}/pre-push"
  local before
  before="$(sha256sum "${hooks}/pre-push")"

  run env FULL_UPGRADE_HOOK_DIR="$hooks" "${ROOT}/scripts/install-hooks.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hook customizado já existe"* ]]
  [ "$(sha256sum "${hooks}/pre-push")" = "$before" ]
  [ ! -e "${hooks}/commit-msg" ]
}
