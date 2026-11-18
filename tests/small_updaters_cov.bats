#!/usr/bin/env bats
# tests/small_updaters_cov.bats — updaters curtos: npm (self), corepack, Snap,
# Neovim (Lazy e Mason) e Oh My Zsh. Cada ferramenta é stub; PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_js.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/packages.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/editor.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/shell.sh"
  stub_path_init
  stub_privilege
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  QUIET=0 STEP_REASON=""
  export HOME="$BATS_TEST_TMPDIR/home" XDG_DATA_HOME="$BATS_TEST_TMPDIR/home/.local/share"
  mkdir -p "$HOME"
  npm_global_writable() { return 0; }
}

_npm_view() {
  # $1 = versão publicada (vazio = registry indisponível); $2 = rc do install
  stub_script npm "case \"\$*\" in
    --version) echo 10.0.0 ;;
    'view npm version'|'view corepack version') [[ -n '$1' ]] && echo '$1' ;;
    install*) echo 'added 1 package'; exit ${2:-0} ;;
  esac"
}

@test "update_npm_self: registry fora, já atual, sistema e atualização" {
  _npm_view ""
  run update_npm_self
  [[ "$output" == *"não foi possível verificar"* ]]
  _npm_view 10.0.0
  run update_npm_self
  [[ "$output" == *"já na versão mais recente"* ]]
  _npm_view 11.0.0
  npm_global_writable() { return 1; }
  run update_npm_self
  [[ "$output" == *"gerenciado pelo sistema"* ]]
  npm_global_writable() { return 0; }
  run update_npm_self
  [ "$status" -eq 0 ]
  grep -q "^npm install -g npm@11.0.0" "$STUB_LOG"
}

@test "update_corepack: mesmas regras do npm" {
  stub corepack 0 "0.30.0"
  _npm_view ""
  run update_corepack
  [[ "$output" == *"não foi possível verificar"* ]]
  _npm_view 0.30.0
  run update_corepack
  [[ "$output" == *"já na versão mais recente"* ]]
  _npm_view 0.31.0 1
  run update_corepack
  [ "$status" -eq 1 ]
  grep -q "^npm install -g corepack@0.31.0" "$STUB_LOG"
  npm_global_writable() { return 1; }
  run update_corepack
  [ "$status" -eq 0 ]
}

@test "update_snap: nenhum snap, refresh ok e loop ausente vira warn" {
  stub snap 0 "No snaps are installed yet."
  run update_snap
  [[ "$output" == *"Nenhum snap instalado"* ]]
  stub_script snap 'case "$1" in list) echo "core 1"; ;; refresh) exit 0 ;; esac'
  run update_snap
  [ "$status" -eq 0 ]
  stub_script snap 'case "$1" in list) echo "core 1" ;; refresh) echo "cannot mount squashfs image using \"squashfs\""; exit 1 ;; esac'
  stub modprobe 1
  update_snap >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"snapd sem módulo loop"* ]]
}

@test "update_snap: carrega o loop e o refresh repetido funciona; outro erro devolve rc" {
  stub_script snap 'case "$1" in list) echo "core 1" ;; refresh) [[ -e "$BATS_TEST_TMPDIR/loop" ]] && exit 0; echo "cannot mount squashfs"; exit 1 ;; esac'
  stub_script modprobe 'touch "$BATS_TEST_TMPDIR/loop"'
  run update_snap
  [ "$status" -eq 0 ]
  stub_script snap 'case "$1" in list) echo "core 1" ;; refresh) echo "erro qualquer"; exit 3 ;; esac'
  run update_snap
  [ "$status" -eq 3 ]
}

@test "update_nvim_lazy e update_nvim_mason: sem nvim, sem plugin e sincronização" {
  run update_nvim_lazy
  [ "$status" -eq 1 ]
  run update_nvim_mason
  [ "$status" -eq 1 ]
  stub nvim 0 ""
  run update_nvim_lazy
  [[ "$output" == *"Lazy.nvim não instalado"* ]]
  run update_nvim_mason
  [[ "$output" == *"Mason.nvim não instalado"* ]]
  mkdir -p "$XDG_DATA_HOME/nvim/lazy/a" "$XDG_DATA_HOME/nvim/lazy/b" "$XDG_DATA_HOME/nvim/mason"
  run update_nvim_lazy
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 plugins presentes"* ]]
  run update_nvim_mason
  [ "$status" -eq 0 ]
  stub_script nvim 'case "$*" in --version) exit 0 ;; *) exit 1 ;; esac'
  update_nvim_mason >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [[ "$STEP_REASON" == "Mason: falha"* ]]
}

@test "update_omz: ausente, atualizado e rede fora" {
  export ZSH="$BATS_TEST_TMPDIR/omz"
  run update_omz
  [ "$status" -eq 1 ]
  mkdir -p "$ZSH/tools"; touch "$ZSH/tools/upgrade.sh"
  stub zsh 0 "Updating Oh My Zsh
Hooray! Oh My Zsh has been updated
https://discord.gg/ohmyzsh"
  run update_omz
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hooray!"* ]]
  [[ "$output" != *"discord.gg"* ]]
  stub zsh 1 "fatal: unable to access: Could not resolve host: github.com"
  update_omz >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

# ── Android CLI, Arduino, Yazi, bootctl, preflight de disco, _retry ──────────

@test "update_android_cli: tudo ok, SDK ausente e falha parcial" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/tools.sh"
  run update_android_cli
  [[ "$output" == *"não encontrado"* ]]
  mkdir -p "$HOME/Android/Sdk"
  stub_script android "case \"\$*\" in info) echo 'sdk: $HOME/Android/Sdk' ;; -V) echo 'android 1.2' ;; *) exit 0 ;; esac"
  run update_android_cli
  [ "$status" -eq 0 ]
  grep -q "^android sdk update" "$STUB_LOG"
  stub_script android 'case "$*" in "skills update --all") exit 1 ;; info) echo "sdk: /nao/existe" ;; *) exit 0 ;; esac'
  update_android_cli >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "android update falhou em: skills" ]
}

@test "update_arduino: ausente, índices ok com libs pendentes e falha" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_other.sh"
  run update_arduino
  [[ "$output" == *"não encontrado"* ]]
  stub_script arduino-cli 'case "$*" in "lib list --updatable") printf "Name\nfoo 1.0\n" ;; *) echo ok ;; esac'
  run update_arduino
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 biblioteca(s) Arduino ainda atualizável"* ]]
  stub_script arduino-cli 'case "$*" in "lib list --updatable") echo Name ;; upgrade) exit 1 ;; esac'
  run update_arduino
  [ "$status" -eq 1 ]
}

@test "update_yazi_plugins: sem package.toml, ok, modificado e erro" {
  export XDG_CONFIG_HOME="$HOME/.config"
  run update_yazi_plugins
  [[ "$output" == *"Sem plugins gerenciados"* ]]
  mkdir -p "$XDG_CONFIG_HOME/yazi"; printf 'use = "a"\nuse = "b"\n' > "$XDG_CONFIG_HOME/yazi/package.toml"
  stub ya 0 ""
  run update_yazi_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizando 2 plugin(s) Yazi"* ]]
  stub ya 1 "You have modified the contents of the plugin"
  update_yazi_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  stub ya 2 "boom"
  run update_yazi_plugins
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_bootctl: ausente, não instalado, já atualizado e atualizado" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/firmware.sh"
  run update_bootctl
  [[ "$output" == *"bootctl não encontrado"* ]]
  stub_script bootctl 'case "$1" in is-installed) exit 1 ;; esac'
  run update_bootctl
  [ "$status" -eq 0 ]
  stub_script bootctl 'case "$1" in is-installed) exit 0 ;; update) echo "Skipping, same boot loader version in place already."; exit 1 ;; esac'
  run update_bootctl
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemd-boot: já atualizado"* ]]
  stub_script bootctl 'case "$1" in is-installed) exit 0 ;; update) echo "Copied"; exit 0 ;; esac'
  run update_bootctl
  [ "$status" -eq 0 ]
}

@test "preflight_disk_space: espaço suficiente e baixo" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/preflight.sh"
  stub findmnt 0 "/"
  stub_script df 'printf "Avail\n%sM\n" "${DF_AVAIL:-50000}"'
  run preflight_disk_space
  [ "$status" -eq 0 ]
  [[ "$output" == *"(OK)"* ]]
  DF_AVAIL=100 run preflight_disk_space
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Espaço baixo em /"* ]]
}

@test "_retry: sucesso na segunda tentativa, erro de rede vira warn, outro erro mantém rc" {
  sleep() { :; }
  stub_script flaky '[[ -e "$BATS_TEST_TMPDIR/ok" ]] && exit 0; touch "$BATS_TEST_TMPDIR/ok"; exit 1'
  run _retry 2 flaky
  [ "$status" -eq 0 ]
  stub rede 6 "curl: (6) Could not resolve host: x"
  run _retry 2 rede
  [ "$status" -eq "$RC_WARN" ]
  stub quebra 7 "erro de verdade"
  run _retry 2 quebra
  [ "$status" -eq 7 ]
}
