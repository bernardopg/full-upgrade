#!/usr/bin/env bats
# tests/release_notes.bats — notas completas para releases com push direto.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  EXTRACT="${ROOT}/scripts/extract-release-notes.sh"
  CHANGELOG="${BATS_TEST_TMPDIR}/CHANGELOG.md"
  cat > "$CHANGELOG" <<'EOF'
# Changelog

## [Unreleased]

### Corrigido

- Ainda não lançado.

## [3.34.0] - 2026-08-13

### Adicionado

- Feature enviada direto na main.

### Corrigido

- Correção enviada direto na main.

## [3.33.1] - 2026-08-09

### Corrigido

- Correção antiga.
EOF
}

@test "release notes: extrai só o corpo da versão pedida" {
  run "$EXTRACT" v3.34.0 "$CHANGELOG"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Feature enviada direto na main"* ]]
  [[ "$output" == *"Correção enviada direto na main"* ]]
  [[ "$output" != *"Ainda não lançado"* ]]
  [[ "$output" != *"Correção antiga"* ]]
  [[ "$output" != *"## [3.34.0]"* ]]
}

@test "release notes: aceita versão sem prefixo v" {
  run "$EXTRACT" 3.33.1 "$CHANGELOG"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Correção antiga"* ]]
}

@test "release notes: falha quando a versão não existe" {
  run "$EXTRACT" v9.9.9 "$CHANGELOG"

  [ "$status" -eq 1 ]
  [[ "$output" == *"seção [9.9.9] não encontrada"* ]]
}

@test "release notes: falha quando a seção versionada está vazia" {
  cat > "$CHANGELOG" <<'EOF'
## [Unreleased]

## [1.2.3] - 2026-08-13

## [1.2.2] - 2026-08-12

- anterior
EOF

  run "$EXTRACT" 1.2.3 "$CHANGELOG"

  [ "$status" -eq 1 ]
  [[ "$output" == *"seção [1.2.3] está vazia"* ]]
}
