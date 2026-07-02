#!/usr/bin/env bats
# tests/obs.bats — steps do OBS (steps.d/85-obs.sh): update de plugins
# user-scope e doctor de módulos. Sem mutação real: OBS_CONFIG_DIR aponta
# para um mock e pacman/flatpak são stubs no PATH.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/85-obs.sh"
  MOCKDIR="$(mktemp -d)"
  export LOG_FILE="/dev/null"

  # Stub de pacman: -Q obs-studio responde instalado; -Qq lista plugins.
  mkdir -p "$MOCKDIR/bin"
  cat > "$MOCKDIR/bin/pacman" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  -Q)  [[ "$2" == obs-studio ]] && { echo "obs-studio 32.1.2-7"; exit 0; }; exit 1 ;;
  -Qq) printf '%s\n' obs-studio obs-composite-blur ffmpeg-obs; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$MOCKDIR/bin/pacman"
  PATH="$MOCKDIR/bin:$PATH"

  OBS_CONFIG_DIR="$MOCKDIR/obs-studio"
  QUIET=0
}

teardown() {
  rm -rf "$MOCKDIR"
}

@test "_obs_install_kind: detecta instalação via pacman" {
  run _obs_install_kind
  [ "$status" -eq 0 ]
  [[ "$output" == "pacman 32.1.2-7" ]]
}

@test "update_obs_plugins: sem diretório de plugins => return 0" {
  mkdir -p "$OBS_CONFIG_DIR"
  run update_obs_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem plugins user-scope"* ]]
}

@test "update_obs_plugins: plugin sem git vira inventário manual" {
  mkdir -p "$OBS_CONFIG_DIR/plugins/meu-plugin/bin"
  run update_obs_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"instalados na mão"* ]]
  [[ "$output" == *"meu-plugin"* ]]
}

@test "update_obs_plugins: diretórios .disabled/.bak são ignorados" {
  mkdir -p "$OBS_CONFIG_DIR/plugins/velho-1.0.disabled-src"
  mkdir -p "$OBS_CONFIG_DIR/plugins/outro.bak"
  run update_obs_plugins
  [ "$status" -eq 0 ]
  [[ "$output" != *"velho-1.0"* ]]
  [[ "$output" != *"outro.bak"* ]]
}

@test "doctor_obs_modules: sem logs => return 0" {
  mkdir -p "$OBS_CONFIG_DIR"
  run doctor_obs_modules
  [ "$status" -eq 0 ]
  [[ "$output" == *"OBS nunca rodou"* ]]
}

@test "doctor_obs_modules: log limpo => ok" {
  mkdir -p "$OBS_CONFIG_DIR/logs"
  printf '%s\n' "12:00:00.000: Loaded module obs-composite-blur.so" \
    > "$OBS_CONFIG_DIR/logs/2026-07-02 12-00-00.txt"
  run doctor_obs_modules
  [ "$status" -eq 0 ]
  [[ "$output" == *"carregando limpos"* ]]
}

@test "doctor_obs_modules: módulo falhando o load => RC_TODO" {
  mkdir -p "$OBS_CONFIG_DIR/logs"
  printf '%s\n' \
    "12:00:00.000: os_dlopen(/usr/lib/obs-plugins/velho.so->velho.so): libobs.so.30: cannot open shared object file" \
    "12:00:00.001: Failed to load module file '/usr/lib/obs-plugins/velho.so'" \
    > "$OBS_CONFIG_DIR/logs/2026-07-02 12-00-00.txt"
  run doctor_obs_modules
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"falhando o load"* ]]
}

@test "doctor_obs_modules: crash recente => RC_WARN" {
  mkdir -p "$OBS_CONFIG_DIR/logs" "$OBS_CONFIG_DIR/crashes"
  printf '%s\n' "12:00:00.000: Loaded module ok.so" \
    > "$OBS_CONFIG_DIR/logs/2026-07-02 12-00-00.txt"
  touch "$OBS_CONFIG_DIR/crashes/Crash 2026-07-02 11-00-00.txt"
  run doctor_obs_modules
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"Crash do OBS"* ]]
}

@test "_obs_config_dir: OBS_CONFIG_DIR tem precedência" {
  OBS_CONFIG_DIR="/tmp/custom-obs"
  run _obs_config_dir
  [ "$output" = "/tmp/custom-obs" ]
}

@test "_obs_config_dir: sem override e sem nativo, cai no dir Flatpak existente" {
  unset OBS_CONFIG_DIR
  HOME="$MOCKDIR/home"
  XDG_CONFIG_HOME="$HOME/.config"
  mkdir -p "$HOME/.var/app/com.obsproject.Studio/config/obs-studio"
  # stub pacman sem obs-studio
  cat > "$MOCKDIR/bin/pacman" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$MOCKDIR/bin/pacman"
  run _obs_config_dir
  [ "$output" = "$HOME/.var/app/com.obsproject.Studio/config/obs-studio" ]
}
