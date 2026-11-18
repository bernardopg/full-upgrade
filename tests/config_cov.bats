#!/usr/bin/env bats
# tests/config_cov.bats — aviso de chave com erro de digitação, valores com
# escape e aspas simples no parser do arquivo, exemplo do config fora do
# projeto e embutido, origem do token do GitHub no --config e steps custom.

load test_helper

setup() {
  load_libs
  source "${FU_LIB}/config.sh"
  export FU_CONFIG_FILE="$BATS_TEST_TMPDIR/config" FU_CONFIG_DIR="$BATS_TEST_TMPDIR/cfgdir"
  mkdir -p "$FU_CONFIG_DIR"
  GITHUB_TOKEN_FILE="$BATS_TEST_TMPDIR/nao-existe"
}

@test "typos: chave parecida com uma conhecida gera aviso" {
  printf 'MIRROR_TOLL=auto\n' > "$FU_CONFIG_FILE"
  run config_warn_typos
  [[ "$output" == *"possível erro de digitação"* ]]
  [[ "$output" == *"MIRROR_TOLL → talvez MIRROR_TOOL?"* ]]
}

@test "config_file_value: escapes em aspas duplas, aspas simples e barra fora de aspas" {
  printf 'A="x\\"y"\nB='"'"'um # dois'"'"'\nC=a\\ b\n' > "$FU_CONFIG_FILE"
  [ "$(config_file_value A)" = 'x"y' ]
  [ "$(config_file_value B)" = 'um # dois' ]
  [ "$(config_file_value C)" = 'a\' ]
}

@test "exemplo: do diretório de config e embutido quando não há arquivo" {
  FU_ROOT="$BATS_TEST_TMPDIR/sem-exemplo"
  echo "# exemplo do usuário" > "$FU_CONFIG_DIR/config.example"
  [ "$(print_config_example)" = "# exemplo do usuário" ]
  rm "$FU_CONFIG_DIR/config.example"
  run print_config_example
  [[ "$output" == "# full-upgrade — configuração do usuário"* ]]
}

@test "--config: token via ambiente, arquivo aberto demais e dica sem exemplo" {
  FU_ROOT="$BATS_TEST_TMPDIR/sem-exemplo"
  GITHUB_TOKEN=x run show_config
  [[ "$output" == *"via ambiente (GITHUB_TOKEN/GH_TOKEN)"* ]]
  [[ "$output" == *"full-upgrade --config-example >"* ]]
  unset GITHUB_TOKEN GH_TOKEN
  GITHUB_TOKEN_FILE="$BATS_TEST_TMPDIR/token"; echo ghp_x > "$GITHUB_TOKEN_FILE"; chmod 644 "$GITHUB_TOKEN_FILE"
  run show_config
  [[ "$output" == *"IGNORADO: permissão aberta demais"* ]]
}

@test "custom_step_or_skip: função ausente pula; presente roda" {
  step_skip() { echo "skip:$1:$2"; }
  run_step() { echo "run:$1:$2"; }
  ENABLE_CUSTOM_TOOLS=1
  run custom_step_or_skip "Passo" funcao_que_nao_existe
  [ "$output" = "skip:Passo:função funcao_que_nao_existe não carregada de steps.d/" ]
  minha_funcao() { :; }
  run custom_step_or_skip "Passo" minha_funcao
  [ "$output" = "run:Passo:minha_funcao" ]
}
