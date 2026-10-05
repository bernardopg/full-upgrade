#!/usr/bin/env bats
# tests/build.bats — metadados do artefato standalone de release.
#
# Todo build aqui escreve em FULL_UPGRADE_BUILD_OUT (dentro do tmpdir do teste),
# nunca no dist/ do repo. Antes estes testes sobrescreviam o artefato de trabalho
# do desenvolvedor — e, sob `bats --jobs`, disputavam o mesmo arquivo entre si,
# fazendo o teste do override falhar de forma intermitente.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  OUT="${BATS_TEST_TMPDIR}/standalone.sh"
}

@test "build: override de release prevalece sobre git describe" {
  run env FULL_UPGRADE_BUILD_VERSION=v9.8.7 FULL_UPGRADE_BUILD_OUT="$OUT" \
    bash "${ROOT}/build.sh"

  [ "$status" -eq 0 ]
  run bash "$OUT" --version
  [ "$status" -eq 0 ]
  [ "$output" = "9.8.7" ]
}

@test "build: rejeita override de versão inválido" {
  run env FULL_UPGRADE_BUILD_VERSION='release/latest' FULL_UPGRADE_BUILD_OUT="$OUT" \
    bash "${ROOT}/build.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"FULL_UPGRADE_BUILD_VERSION inválida"* ]]
}

# Regressão: a validação do override morava DENTRO do bloco redirecionado para o
# arquivo de saída, então o redirect truncava o standalone antes de a checagem
# falhar — um build inválido destruía o artefato anterior e deixava um arquivo
# vazio no lugar.
@test "build: override inválido não destrói o artefato já existente" {
  env FULL_UPGRADE_BUILD_VERSION=v9.8.7 FULL_UPGRADE_BUILD_OUT="$OUT" \
    bash "${ROOT}/build.sh" >/dev/null

  run env FULL_UPGRADE_BUILD_VERSION='release/latest' FULL_UPGRADE_BUILD_OUT="$OUT" \
    bash "${ROOT}/build.sh"
  [ "$status" -ne 0 ]

  # O artefato anterior segue íntegro e executável.
  [ -s "$OUT" ]
  [ -x "$OUT" ]
  run bash "$OUT" --version
  [ "$status" -eq 0 ]
  [ "$output" = "9.8.7" ]
}

@test "build: não deixa temporário para trás no diretório de saída" {
  env FULL_UPGRADE_BUILD_OUT="$OUT" bash "${ROOT}/build.sh" >/dev/null

  run bash -c 'ls "$1".* 2>/dev/null | wc -l' _ "$OUT"
  [ "$output" = "0" ]
}

# Regressão real (pacote 3.48.8): o filtro de cabeçalho apagava QUALQUER linha
# `#!/usr/bin/env bash`, inclusive a do wrapper git que o step do Hermes gera por
# heredoc. Sem shebang o Python do Hermes recusava executá-lo (`Exec format
# error`) e o update falhava sem stderr capturado.
@test "build: preserva shebang de scripts gerados por heredoc" {
  env FULL_UPGRADE_BUILD_OUT="$OUT" bash "${ROOT}/build.sh" >/dev/null

  run grep -A1 "cat > \"\${HERMES_GIT_WRAPPER}/git\" <<'GITWRAPPER'" "$OUT"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = '#!/usr/bin/env bash' ]
  # Só o shebang da linha 1 de cada módulo sai: o standalone mantém o próprio
  # e todos os que aparecem fora da linha 1 nas fontes.
  local inner
  inner="$(awk 'FNR > 1 && /^#!\/usr\/bin\/env bash$/' "${ROOT}"/lib/*.sh "${ROOT}"/lib/steps/*.sh "${ROOT}"/lib/steps/*/*.sh "${ROOT}"/steps.d/*.sh | wc -l)"
  [ "$(grep -c '^#!/usr/bin/env bash$' "$OUT")" -eq $(( inner + 1 )) ]
}
