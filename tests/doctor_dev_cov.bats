#!/usr/bin/env bats
# tests/doctor_dev_cov.bats — Doctor do ambiente Python (pip check, venvs do
# pipx e do uv) e da integridade do pacman (-Qkq com falsos positivos). PATH
# isolado; `python` repassa só `-c`/scripts ao Python real.

load test_helper
load stub_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
}

_python_pip() {
  # $1 = rc do `pip check`; saída em $PIP_CHECK_OUT.
  stub_script python "if [[ \"\$1\" == -m && \"\$2\" == pip ]]; then
  case \"\$3\" in --version) echo 'pip 25.0' ;; check) printf '%s\n' \"\$PIP_CHECK_OUT\"; exit $1 ;; esac
  exit 0
fi
exec python3 \"\$@\""
}

# ── doctor_python_env ─────────────────────────────────────────────────────────

@test "python_env: pip check limpo e sem pipx/uv" {
  _python_pip 0
  run doctor_python_env
  [ "$status" -eq 0 ]
  [[ "$output" == *"sem dependências Python quebradas"* ]]
  [[ "$output" == *"pipx e uv não instalados"* ]]
}

@test "python_env: dependências quebradas classificadas por origem viram warn" {
  export PIP_CHECK_OUT="pygount 1.8.0 has requirement chardet<6, but you have chardet 6.0.
foo 1.0 requires bar, which is not installed."
  _python_pip 1
  _classify_pip_origins() { printf 'pygount\tsystem\nfoo\tuser\n'; }
  doctor_python_env >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "python_env: saída do pip check fora do formato preserva o dump" {
  export PIP_CHECK_OUT="algo inesperado"
  _python_pip 1
  run doctor_python_env
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"encontrou dependências Python quebradas"* ]]
}

@test "python_env: venv do pipx e ferramenta uv sem interpreter viram TODO" {
  _python_pip 0
  stub_script pipx 'echo "{\"venvs\":{\"ok\":{\"metadata\":{\"python_path\":\"/bin/sh\"}},\"quebrado\":{\"metadata\":{\"python_path\":\"/nao/existe/python\"}}}}"'
  stub_script uv 'echo "[{\"name\":\"ruff\",\"python\":\"/nao/existe/py\"}]"'
  doctor_python_env >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}

@test "python_env: pipx e uv saudáveis" {
  _python_pip 0
  stub_script pipx 'echo "{\"venvs\":{\"ok\":{\"metadata\":{\"python_path\":\"/bin/sh\"}}}}"'
  stub_script uv 'echo "[{\"name\":\"ruff\",\"python\":\"/bin/sh\"}]"'
  run doctor_python_env
  [ "$status" -eq 0 ]
  [[ "$output" == *"todas as venvs com interpreter válido"* ]]
  [[ "$output" == *"uv tools: interpreters OK"* ]]
}

# ── doctor_pacman_health ──────────────────────────────────────────────────────

@test "pacman_health: sem pacman, limpo e só falsos positivos" {
  run doctor_pacman_health
  [[ "$output" == *"pacman não encontrado"* ]]
  stub pacman 0 ""
  run doctor_pacman_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"nenhum pacote com arquivo faltando"* ]]
  stub pacman 1 "intel-ucode /boot/intel-ucode.img
python-foo /usr/lib/python3.14/site-packages/foo/__pycache__/a.cpython-314.pyc"
  run doctor_pacman_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"apenas falsos positivos conhecidos (2 ignorados)"* ]]
}

@test "pacman_health: arquivo real faltando vira TODO; sem permissão vira warn" {
  stub_privilege
  stub pacman 1 "foo /usr/bin/foo
intel-ucode /boot/intel-ucode.img"
  doctor_pacman_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "1 arquivo(s)/pacote(s) com problema via sudo pacman -Qkq (+ 1 falso(s) positivo(s) filtrado(s))" ]]
  rm "$STUB_BIN/sudo"; hash -r
  stub pacman 1 "foo: /etc/foo (Permission denied)"
  run doctor_pacman_health
  [ "$status" -eq "$RC_WARN" ]
  stub pacman 3 ""
  run doctor_pacman_health
  [ "$status" -eq "$RC_WARN" ]
}

# ── doctor_gem_shadow e doctor_pacman_hooks ──────────────────────────────────

@test "gem_shadow: sem gem, sem separação e gem do usuário sombreando o Arch" {
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.gem"
  run doctor_gem_shadow
  [[ "$output" == *"gem não disponível"* ]]
  stub_script gem "case \"\$*\" in 'env home') echo '$HOME/.gem' ;; 'env user_gemhome') echo '$HOME/.gem' ;; esac"
  run doctor_gem_shadow
  [[ "$output" == *"Sem separação"* ]]
  stub_script gem "case \"\$*\" in
    'env home') echo /usr/lib/ruby/gems/3.4.0 ;;
    'env user_gemhome') echo '$HOME/.gem' ;;
    'list --local') [[ \"\$GEM_HOME\" == /usr/* ]] && echo 'rake (13.0.0)' || echo 'rake (13.2.1)' ;;
  esac"
  doctor_gem_shadow >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "1 gem(s) do usuário sombreando o sistema" ]
  stub_script gem "case \"\$*\" in 'env home') echo /usr/lib/ruby ;; 'env user_gemhome') echo '$HOME/.gem' ;; 'list --local') echo 'rake (13.0.0)' ;; esac"
  run doctor_gem_shadow
  [[ "$output" == *"Sem gems do usuário sombreando"* ]]
}

@test "pacman_hooks: sem journalctl, sem erros e hook com falha" {
  run doctor_pacman_hooks
  [[ "$output" == *"journalctl não encontrado"* ]]
  stub_script journalctl 'case "$1" in --list-boots) echo " 0 abc123 Mon" ;; *) exit 0 ;; esac'
  run doctor_pacman_hooks
  [ "$status" -eq 0 ]
  stub_script journalctl 'case "$1" in --list-boots) echo " 0 abc123 Mon" ;; *) echo "[1.0] ALPM-scriptlet: erro" ;; esac'
  doctor_pacman_hooks >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "1 erro(s) em hook(s) ALPM no boot atual" ]
}

# ── doctor_js_conflicts ───────────────────────────────────────────────────────

@test "js_conflicts: prefixo do sistema e incomum viram warn; HOME é ok" {
  export HOME="$BATS_TEST_TMPDIR/home"
  stub npm 0 ""
  npm_global_prefix() { echo /usr; }
  doctor_js_conflicts >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  npm_global_prefix() { echo /srv/npm; }; unset status
  doctor_js_conflicts >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  npm_global_prefix() { echo "$HOME/.npm-global"; }
  run doctor_js_conflicts
  [ "$status" -eq 0 ]
  [[ "$output" == *"sem conflitos detectados"* ]]
}

@test "js_conflicts: pacote em npm e pnpm globais vira warn" {
  export HOME="$BATS_TEST_TMPDIR/home"
  npm_global_prefix() { echo "$HOME/.npm-global"; }
  stub_script npm 'echo "{\"dependencies\":{\"typescript\":{},\"eslint\":{}}}"'
  stub_script pnpm 'echo "[{\"dependencies\":{\"typescript\":{}}}]"'
  run doctor_js_conflicts
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"1 pacote(s) instalado(s) em ambos"* ]]
  stub_script pnpm 'echo "[{\"dependencies\":{\"vite\":{}}}]"'
  run doctor_js_conflicts
  [[ "$output" == *"sem pacotes duplicados"* ]]
}

@test "js_conflicts: pnpm do corepack com sombra no store global vira TODO" {
  export HOME="$BATS_TEST_TMPDIR/home"
  d="$BATS_TEST_TMPDIR/node/lib/node_modules/corepack/shims"; mkdir -p "$d"
  printf '#!/usr/bin/env bash\necho "[{\\"dependencies\\":{\\"pnpm\\":{\\"version\\":\\"9.0.0\\"}}}]"\n' > "$d/pnpm"
  chmod +x "$d/pnpm"; ln -s "$d/pnpm" "$STUB_BIN/pnpm"; hash -r
  pnpm_global_shadow_managers() { echo pnpm; }
  doctor_js_conflicts >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}
