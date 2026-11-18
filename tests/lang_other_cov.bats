#!/usr/bin/env bats
# tests/lang_other_cov.bats — Go tools com versão nova e com falha, .NET tool já
# na última e com erro, gems do usuário só gerenciadas pelo Arch e Arduino sem
# bibliotecas pendentes. `go`, `dotnet`, `gem` e `arduino-cli` são funções ou
# stubs; nada é instalado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/lang_other.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.local/bin"
}

@test "go: versão nova instalada e módulo que falha" {
  : > "$HOME/.local/bin/ok-tool"; : > "$HOME/.local/bin/ruim-tool"; chmod +x "$HOME/.local/bin/"*
  go() {
    case "$1 ${2:-}" in
      "env GOPATH") echo "$BATS_TEST_TMPDIR/sem-gopath" ;;
      "version -m")
        local v=v1.0.0; [[ -e "$BATS_TEST_TMPDIR/instalado" ]] && v=v1.1.0
        printf '%s\n\tpath\texample.com/%s\n\tmod\texample.com/%s\t%s\n' "$3" "${3##*/}" "${3##*/}" "$v" ;;
    esac
  }
  go_tool_needs_update() { return 0; }
  run_logged() { [[ "$*" == *ruim-tool* ]] && return 1; touch "$BATS_TEST_TMPDIR/instalado"; }
  run update_go_tools
  [ "$status" -eq 1 ]
  [[ "$output" == *"versões novas: ok-tool v1.0.0→v1.1.0"* ]]
  [[ "$output" == *"Falha ao atualizar módulo(s) Go: example.com/ruim-tool"* ]]
}

@test ".NET: tool já na última e tool com erro" {
  dotnet() {
    case "$1 $2" in
      "tool list") printf 'Package Id  Version  Commands\n----\nx\ndotnet-ef 9.0 ef\ndotnet-bad 1.0 bad\n' ;;
      "tool update") [[ "$4" == dotnet-ef ]] && { echo "Tool 'dotnet-ef' is already the latest version"; return 1; }; echo "erro de rede"; return 1 ;;
    esac
  }
  run update_dotnet_tools
  [[ "$output" == *"dotnet-ef: já na versão mais recente"* ]]
  [[ "$output" == *"ERRO ao atualizar dotnet-bad"* ]]
}

@test "gems do usuário: todas atualizadas e só gerenciadas pelo Arch" {
  mkdir -p "$HOME/.gem"
  stub_script gem 'case "$*" in
  "env home") echo /usr/lib/ruby/gems/3.4.0 ;;
  "env user_gemhome") echo "$HOME/.gem" ;;
  outdated) [[ -n "${USER_OUTDATED:-}" ]] && echo "$USER_OUTDATED" ;;
  "list --local") echo "rake (13.0.0)" ;;
  list) echo "rake (13.0.0)" ;;
esac'
  run update_gem_user
  [[ "$output" == *"Gems do usuário: todas atualizadas"* ]]
  USER_OUTDATED="rake (13.0.0 < 13.2.1)" run update_gem_user
  [[ "$output" == *"todas gerenciadas pelo Arch"* ]]
}

@test "arduino: tudo atualizado" {
  stub_script arduino-cli 'case "$*" in "lib list --updatable") echo "Name Installed Available" ;; esac'
  run update_arduino
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cores e bibliotecas Arduino: todos atualizados"* ]]
}
