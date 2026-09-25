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
