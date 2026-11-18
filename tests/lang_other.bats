#!/usr/bin/env bats
# tests/lang_other.bats — caminhos dos steps de lang_other.sh com mocks de
# comandos externos. Cobre early-exits e ramos de sucesso/falha sem I/O real.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_other.sh"
  log() { :; }; log_raw() { :; }; remediation() { :; }
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}

# ── update_go_tools ───────────────────────────────────────────────────────────
@test "update_go_tools: GOPATH/bin ausente => 0" {
  go() { [[ "$1" == env ]] && echo "$BATS_TEST_TMPDIR/inexistente"; }
  run update_go_tools
  [ "$status" -eq 0 ]
}

@test "update_go_tools: bin vazio => 0 (sem módulos)" {
  local gp="$BATS_TEST_TMPDIR/go"; mkdir -p "$gp/bin"
  go() { [[ "$1" == env ]] && echo "$gp"; }
  run update_go_tools
  [ "$status" -eq 0 ]
}

@test "update_go_tools: reinstala go install de ~/.local/bin no mesmo GOBIN" {
  mkdir -p "$HOME/.local/bin"
  : >"$HOME/.local/bin/arxiv-pp-cli"; : >"$HOME/.local/bin/gitleaks"; : >"$HOME/.local/bin/dev"; : >"$HOME/.local/bin/gk"
  chmod +x "$HOME/.local/bin/"*
  go() {
    case "$1 ${2:-}" in
      "env GOPATH") echo "$BATS_TEST_TMPDIR/inexistente" ;;
      "version -m")
        case "$3" in
          */arxiv-pp-cli) printf '%s\n\tpath\texample.com/arxiv/cmd/arxiv-pp-cli\n\tmod\texample.com/arxiv\tv0.0.1\n' "$3" ;;
          */gitleaks) printf '%s\n\tpath\tcommand-line-arguments\n' "$3" ;;
          */gk) printf '%s\n\tpath\tgkcli/cmd/installer-proxy\n\tmod\tgkcli\tv0.0.0-20260713140353-8a7aecbbd3d7\n' "$3" ;;
          */dev) printf '%s\n\tpath\texample.com/dev\n\tmod\texample.com/dev\t(devel)\n' "$3" ;;
        esac ;;
    esac
  }
  run_logged() { echo "$*" >>"$BATS_TEST_TMPDIR/calls"; }
  run update_go_tools
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/calls"
  [ "$output" = "env GOBIN=$HOME/.local/bin go install example.com/arxiv/cmd/arxiv-pp-cli@latest" ]
}

# ── update_dotnet_tools ───────────────────────────────────────────────────────
@test "update_dotnet_tools: nenhuma tool => 0" {
  dotnet() { :; }   # lista vazia
  run update_dotnet_tools
  [ "$status" -eq 0 ]
}

@test "update_dotnet_tools: tool já na última versão => 0" {
  dotnet() {
    case "$*" in
      *"tool list"*) printf 'Package\n----\nfoo 1.0 foo\n' ;;
      *"tool update"*) echo "Tool 'foo' is already the latest version." ;;
    esac
  }
  run update_dotnet_tools
  [ "$status" -eq 0 ]
}

# ── update_arduino ────────────────────────────────────────────────────────────
@test "update_arduino: ausente => 0" {
  has() { return 1; }
  run update_arduino
  [ "$status" -eq 0 ]
}

# ── update_gcloud ─────────────────────────────────────────────────────────────
@test "update_gcloud: falha de rede transitória => RC_WARN" {
  _retry() { return "$RC_WARN"; }
  run update_gcloud
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_gcloud: sucesso propaga rc 0" {
  _retry() { echo "Beginning update."; return 0; }
  run update_gcloud
  [ "$status" -eq 0 ]
}

# ── update_ghcup ──────────────────────────────────────────────────────────────
@test "update_ghcup: propaga rc do ghcup" {
  ghcup() { echo "[ upgrading ]"; return 0; }
  run update_ghcup
  [ "$status" -eq 0 ]
}

# ── go_tool_needs_update (U13) ────────────────────────────────────────────────
_go_stub_versions() {
  # $1 = toolchain do binário, $2 = versão gravada, $3 = GOVERSION atual, $4 = @latest
  export GT_BUILT="$1" GT_MOD="$2" GT_CUR="$3" GT_LATEST="$4"
  go() {
    case "$1 ${2:-}" in
      "version -m") printf '%s: %s\n\tpath\texample.com/x/cmd/x\n\tmod\texample.com/x\t%s\th1:abc\n' "$3" "$GT_BUILT" "$GT_MOD" ;;
      "env GOVERSION") echo "$GT_CUR" ;;
      "list -m") echo "$GT_LATEST" ;;
    esac
  }
}

@test "go_tool_needs_update: módulo e toolchain atuais => não reinstala" {
  _go_stub_versions go1.27.4-X:nodwarf5 v1.2.0 go1.27.4-X:nodwarf5 v1.2.0
  run go_tool_needs_update /bin/x
  [ "$status" -eq 1 ]
}

@test "go_tool_needs_update: versão nova do módulo => reinstala" {
  _go_stub_versions go1.27.4 v1.2.0 go1.27.4 v1.3.0
  run go_tool_needs_update /bin/x
  [ "$status" -eq 0 ]
}

@test "go_tool_needs_update: toolchain nova => reinstala mesmo com o módulo igual" {
  _go_stub_versions go1.27.3 v1.2.0 go1.27.4 v1.2.0
  run go_tool_needs_update /bin/x
  [ "$status" -eq 0 ]
}

@test "go_tool_needs_update: @latest indisponível => reinstala por segurança" {
  _go_stub_versions go1.27.4 v1.2.0 go1.27.4 ""
  run go_tool_needs_update /bin/x
  [ "$status" -eq 0 ]
}

@test "update_go_tools: ferramenta atual não chama go install" {
  mkdir -p "$HOME/.local/bin"; : >"$HOME/.local/bin/x"; chmod +x "$HOME/.local/bin/x"
  _go_stub_versions go1.27.4 v1.2.0 go1.27.4 v1.2.0
  go() {
    case "$1 ${2:-}" in
      "env GOPATH") echo "$BATS_TEST_TMPDIR/inexistente" ;;
      "version -m") printf '%s: %s\n\tpath\texample.com/x/cmd/x\n\tmod\texample.com/x\t%s\th1:abc\n' "$3" "$GT_BUILT" "$GT_MOD" ;;
      "env GOVERSION") echo "$GT_CUR" ;;
      "list -m") echo "$GT_LATEST" ;;
    esac
  }
  run_logged() { echo "$*" >>"$BATS_TEST_TMPDIR/calls"; }
  run update_go_tools
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/calls" ]
}

# Regressão: sem gems do sistema (lista vazia), `NR == FNR` tratava o outdated
# do usuário como lista do sistema e nenhuma gem do usuário era atualizada.
@test "gem_user_updatable: lista do sistema vazia não esconde as gems do usuário" {
  : > "$BATS_TEST_TMPDIR/arch"
  printf 'rake (13.0.0 < 13.2.1)\n' > "$BATS_TEST_TMPDIR/outdated"
  run gem_user_updatable "$BATS_TEST_TMPDIR/outdated" "$BATS_TEST_TMPDIR/arch"
  [ "$output" = rake ]
}
