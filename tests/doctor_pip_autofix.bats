#!/usr/bin/env bats
# tests/doctor_pip_autofix.bats — auto-remediação de deps pip --user ausentes.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  QUIET=0
  STEP_REASON=""
  AUTO_FIX_PIP_DEPS=1
  PIP_CHECK_OUT=""
  PIP_INSTALL_ARGS="${BATS_TEST_TMPDIR}/pip-install.args"
  : >"$PIP_INSTALL_ARGS"
  PIP_INSTALL_RC=0
  # pacman/sudo NUNCA reais: o ramo de pacotes do sistema consulta o
  # repositório e instalaria com sudo. Repositório controlado pelo teste.
  REPO_PKGS=""
  PACMAN_S_ARGS="${BATS_TEST_TMPDIR}/pacman-S.args"
  : >"$PACMAN_S_ARGS"
  SUDO_OK=1
  # Depois do source das libs (que redefinem has/_doctor_sudo_ok).
  has() { [[ "$1" == pacman ]] && return 0; command -v "$1" >/dev/null 2>&1; }
  _doctor_sudo_ok() { (( SUDO_OK )); }
  PRIV_CMD=_priv
}

pacman() {
  case "$1" in
    -Si) [[ " $REPO_PKGS " == *" $2 "* ]] ;;
    -S) shift; printf '%s\n' "$*" >>"$PACMAN_S_ARGS"; return "${PACMAN_S_RC:-0}" ;;
    *) return 1 ;;
  esac
}
_priv() { [[ "$1" == -n ]] && shift; "$@"; }

# Mocka `python -m pip …` com o estado do teste e registra os installs.
python() {
  if [[ "$1" == "-m" && "$2" == "pip" ]]; then
    case "$3" in
      --version) return 0 ;;
      check)
        [[ -n "$PIP_CHECK_OUT" ]] && printf '%s\n' "$PIP_CHECK_OUT"
        [[ -z "$PIP_CHECK_OUT" ]] && return 0
        return 1
        ;;
      install)
        printf '%s\n' "$*" >>"$PIP_INSTALL_ARGS"
        return "$PIP_INSTALL_RC"
        ;;
    esac
  fi
  command python "$@"
}

# _classify_pip_origins roda `python3 -c`; origem controlada pelo teste.
python3() {
  if [[ "$1" == "-c" ]]; then
    while IFS= read -r _line; do
      [[ -n "$_line" ]] && printf '%s\t%s\n' "$_line" "$PIP_ORIGIN"
    done
    return 0
  fi
  command python3 "$@"
}

@test "autofix pip deps: flag desligada => nada a fazer" {
  AUTO_FIX_PIP_DEPS=0
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"desligado"* ]]
}

@test "autofix pip deps: pip check limpo => nada a remediar" {
  PIP_CHECK_OUT=""
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip check limpo"* ]]
}

@test "autofix pip deps: dep ausente de pacote user é instalada" {
  PIP_ORIGIN="user"
  PIP_CHECK_OUT="fvs 0.3.4 requires orjson, which is not installed."
  # Depois do install o check fica limpo (chaveia pelo arquivo de args).
  python() {
    if [[ "$1" == "-m" && "$2" == "pip" ]]; then
      case "$3" in
        --version) return 0 ;;
        check)
          if [[ -s "$PIP_INSTALL_ARGS" ]]; then
            return 0
          fi
          printf '%s\n' "$PIP_CHECK_OUT"
          return 1
          ;;
        install) printf '%s\n' "$*" >>"$PIP_INSTALL_ARGS"; return 0 ;;
      esac
    fi
    command python "$@"
  }
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip check limpo após remediação"* ]]
  [[ "$(cat "$PIP_INSTALL_ARGS")" == *"install --user --break-system-packages orjson"* ]]
}

@test "autofix pip deps: pacote de origem system é intocável" {
  PIP_ORIGIN="system"
  PIP_CHECK_OUT="pacman-pkg 1.0 requires somedep, which is not installed."
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a remediar"* ]]
  [ ! -s "$PIP_INSTALL_ARGS" ]
}

@test "autofix pip deps: dep ausente de pacote system existente no repo vai pelo pacman" {
  PIP_ORIGIN="system"
  PIP_CHECK_OUT="python-dateutil 4.0.0 requires tzdata, which is not installed."
  REPO_PKGS="python-tzdata"
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$(cat "$PACMAN_S_ARGS")" == *"--needed --noconfirm python-tzdata"* ]]
  # --asdeps faria da dep um órfão: a limpeza de órfãos a removeria no run.
  [[ "$(cat "$PACMAN_S_ARGS")" != *"--asdeps"* ]]
  [ ! -s "$PIP_INSTALL_ARGS" ]
}

@test "autofix pip deps: dep do repo sem sudo sem prompt vira TODO" {
  PIP_ORIGIN="system"
  PIP_CHECK_OUT="python-dateutil 4.0.0 requires tzdata, which is not installed."
  REPO_PKGS="python-tzdata"
  SUDO_OK=0
  autofix_pip_user_deps >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"pacman -S python-tzdata"* ]]
  [ ! -s "$PACMAN_S_ARGS" ]
}

@test "autofix pip deps: falha do pacman -S vira warn" {
  PIP_ORIGIN="system"
  PIP_CHECK_OUT="python-dateutil 4.0.0 requires tzdata, which is not installed."
  REPO_PKGS="python-tzdata"
  PACMAN_S_RC=1
  run autofix_pip_user_deps
  [ "$status" -eq "$RC_WARN" ]
}

@test "pip_req_arch_pkg: normaliza nome, extras, spec e marker" {
  run pip_req_arch_pkg "tzdata"
  [ "$output" = "python-tzdata" ]
  run pip_req_arch_pkg "Foo_Bar.baz[x]>=1,<2; python_version<'4'"
  [ "$output" = "python-foo-bar-baz" ]
  run pip_req_arch_pkg ">=1"
  [ -z "$output" ]
}

@test "autofix pip deps: conflito de versão não é auto-instalado" {
  PIP_ORIGIN="user"
  PIP_CHECK_OUT="pygount 1.6.1 has requirement chardet>=5.0, but you have chardet 7.4.3."
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a remediar"* ]]
  [ ! -s "$PIP_INSTALL_ARGS" ]
}

@test "autofix pip deps: spec com versão é preservada no install" {
  PIP_ORIGIN="user"
  PIP_CHECK_OUT="baz-tool 2 requires qux>=1,<2, which is not installed."
  python() {
    if [[ "$1" == "-m" && "$2" == "pip" ]]; then
      case "$3" in
        --version) return 0 ;;
        check)
          if [[ -s "$PIP_INSTALL_ARGS" ]]; then
            return 0
          fi
          printf '%s\n' "$PIP_CHECK_OUT"
          return 1
          ;;
        install) printf '%s\n' "$*" >>"$PIP_INSTALL_ARGS"; return 0 ;;
      esac
    fi
    command python "$@"
  }
  run autofix_pip_user_deps
  [ "$status" -eq 0 ]
  [[ "$(cat "$PIP_INSTALL_ARGS")" == *"qux>=1,<2"* ]]
}

@test "autofix pip deps: falha no install => RC_WARN" {
  PIP_ORIGIN="user"
  PIP_CHECK_OUT="fvs 0.3.4 requires orjson, which is not installed."
  PIP_INSTALL_RC=1
  run autofix_pip_user_deps
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Falha ao instalar"* ]]
}
