#!/usr/bin/env bats
# tests/healthcheck_cov.bats — ramos do --healthcheck que dependem da máquina:
# uptime, TTY, terminal pela cadeia de processos, plugins DMS com git, GPU,
# Timeshift com sudo -n, backup em nuvem, fetch e as duas renderizações com
# coletores falsos. PATH isolado; git real só em repositórios descartáveis.

load test_helper
load stub_helper

setup() {
  GIT_REAL="$(type -P git)"
  load_healthcheck_libs
  stub_path_init
  NO_COLOR=1 COLUMNS=120
  export FU_CONFIG_FILE="$BATS_TEST_TMPDIR/config"
  unset PRIV_CMD TERM_PROGRAM KITTY_WINDOW_ID ALACRITTY_WINDOW_ID XDG_VTNR
}

# ── uptime, TTY e terminal ───────────────────────────────────────────────────

@test "uptime: dias, horas e minutos" {
  export HC_UPTIME_FILE="$BATS_TEST_TMPDIR/uptime"
  echo "190000.5 1" > "$HC_UPTIME_FILE"
  [ "$(hc_uptime_human)" = "2d 4h" ]
  echo "7300 1" > "$HC_UPTIME_FILE"
  [ "$(hc_uptime_human)" = "2h 1m" ]
  echo "lixo" > "$HC_UPTIME_FILE"
  [ "$(hc_uptime_human)" = "0m" ]
}

@test "tty: VT ativo do sysfs, tty corrente e indefinido" {
  export HC_TTY_ACTIVE_FILE="$BATS_TEST_TMPDIR/active"
  echo tty2 > "$HC_TTY_ACTIVE_FILE"
  [ "$(hc_tty_info)" = "tty2" ]
  HC_TTY_ACTIVE_FILE="$BATS_TEST_TMPDIR/nao-existe"
  stub tty 0 "/dev/pts/7"
  [ "$(hc_tty_info)" = "/dev/pts/7" ]
  stub tty 1 "not a tty"
  [ "$(hc_tty_info)" = "<indefinido>" ]
}

@test "terminal: ascendente com nome de terminal conhecido é reconhecido" {
  ln -s "$(type -P bash)" "$STUB_BIN/tmux"
  # O `; true` impede o Bash de fazer exec no filho: o pai continua sendo "tmux".
  # O filho carrega o arquivo (não a função exportada) para o kcov medir as linhas.
  run "$STUB_BIN/tmux" -c "bash -c 'for m in globals ui core healthcheck; do source $FU_LIB/\$m.sh; done; hc_terminal_info'; true"
  [ "$output" = "tmux" ]
}

# ── DMS ───────────────────────────────────────────────────────────────────────

@test "dms_plugins: clone limpo, modificado e sem git" {
  ln -s "$GIT_REAL" "$STUB_SAFE/git"; hash -r
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
  export DMS_PLUGINS_DIR="$BATS_TEST_TMPDIR/plugins"
  for p in limpo sujo; do
    mkdir -p "$DMS_PLUGINS_DIR/$p"
    git -C "$DMS_PLUGINS_DIR/$p" init -q
    echo a > "$DMS_PLUGINS_DIR/$p/f"
    git -C "$DMS_PLUGINS_DIR/$p" add f
    git -C "$DMS_PLUGINS_DIR/$p" commit -qm "versão inicial"
  done
  echo b > "$DMS_PLUGINS_DIR/sujo/f"
  mkdir -p "$DMS_PLUGINS_DIR/solto"
  run hc_dms_plugins
  [[ "$output" == *"limpo|main|limpo|versão inicial"* ]]
  [[ "$output" == *"sujo|main|modificado|versão inicial"* ]]
  [[ "$output" == *"solto|-|-|sem git"* ]]
}

# ── GPU, Timeshift, nuvem e fetch ─────────────────────────────────────────────

@test "gpu: lspci sem placa cai no nvidia-smi" {
  stub lspci 0 "00:00.0 Host bridge: Intel"
  stub nvidia-smi 0 "NVIDIA GeForce RTX 4060"
  [ "$(hc_gpu_info)" = "NVIDIA GeForce RTX 4060" ]
}

@test "timeshift raw: lista do usuário, sem privilégio e via sudo -n" {
  stub timeshift 0 "1  >  2026-11-01_10-00-00  O"
  [[ "$(hc_timeshift_raw_list)" == *"2026-11-01"* ]]
  stub timeshift 1 "E: Must be run as root"
  [ "$(hc_timeshift_raw_list)" = "E: Must be run as root" ]
  export PRIV_CMD=sudo
  stub_script sudo '[[ "$1" == -n ]] && shift; [[ "$1" == timeshift ]] && echo "0 > 2026-11-02_09-00-00 D"'
  [[ "$(hc_timeshift_raw_list)" == *"2026-11-02"* ]]
  stub sudo 1 "sudo: a password is required"
  [ "$(hc_timeshift_raw_list)" = "E: Must be run as root" ]
}

@test "timeshift summary: ok com snapshots e sudo-necessário" {
  stub timeshift 0 "0 > 2026-11-02_09-00-00 D"
  [ "$(hc_timeshift_summary)" = "ok|1|2026-11-02_09-00-00" ]
  stub timeshift 1 "E: Must be run as root"
  [ "$(hc_timeshift_summary)" = "sudo-necessário||" ]
}

@test "cloud backup: em uso com restic/rclone e remotes listados" {
  printf 'TIMESHIFT_CLOUD_BACKUP=1\nTIMESHIFT_CLOUD_REPOSITORY=rclone:od:fu\n' > "$FU_CONFIG_FILE"
  stub restic 0 ""
  stub_script rclone 'printf "od:\ngd:\n"'
  run hc_cloud_backup_lines
  [[ "$output" == *"em-uso|Timeshift → Restic (rclone)|repo: rclone:od:fu"* ]]
  [[ "$output" == *"rclone-remotes|od: gd:"* ]]
  [[ "$output" == *"instalado|restic"* ]]
  run hc_cloud_backup_json_lines
  [[ "$output" == '[{"kind":"em-uso"'* ]]
  [[ "$output" == *'{"kind":"instalado","detail":"rclone"}]' ]]
}

@test "fetch: fastfetch e neofetch quando presentes" {
  stub neofetch 0 "neo"
  [ "$(hc_run_fetch)" = "neo" ]
  stub fastfetch 0 "fast"
  [ "$(hc_run_fetch)" = "fast" ]
}

# ── Renderização com coletores falsos ────────────────────────────────────────

_fake_collectors() {
  hc_kernel_fields() { printf '7.3.4-arch1-1|7.3.5.arch1-1|1'; }
  hc_desktop_fields() { printf 'Hyprland|Hyprland|wayland'; }
  hc_tty_info() { printf 'tty1'; }
  hc_terminal_info() { printf 'kitty'; }
  hc_dms_active() { return 0; }
  hc_dms_plugins() { printf 'a|main|limpo|ok\nb|dev|modificado|wip\nc|-|-|sem git\n'; }
  hc_pm_list() { printf 'pacman|/usr/bin/pacman|Pacman v7\n'; }
  hc_tool_list() { printf 'restic|presente|/usr/bin/restic\nborg|ausente|\n'; }
  hc_timeshift_summary() { printf 'ok|3|2026-11-02_09-00-00'; }
  hc_cloud_backup_lines() { printf 'em-uso|Restic|repo: x\nem-uso-incompleto|Restic|faltam\nrclone-remotes|od:\ninstalado|restic\n'; }
  hc_run_fetch() { echo "fetch"; }
  hc_gpu_info() { printf 'GPU'; }
}

@test "pretty: reboot pendente, plugin modificado, snapshots e nuvem" {
  _fake_collectors
  stub pacman 0 ""; stub timeshift 0 ""
  run hc_render_pretty
  [ "$status" -eq 0 ]
  [[ "$output" == *"pendente (kernel novo instalado)"* ]]
  [[ "$output" == *"3 plugin(s): 1 limpo(s), 1 modificado(s), 1 sem git"* ]]
  [[ "$output" == *"b (branch dev · wip)"* ]]
  [[ "$output" == *"Mais recente"*"2026-11-02_09-00-00"* ]]
  [[ "$output" == *"Em uso (incompleto)"* ]]
  [[ "$output" == *"Remotes rclone"* ]]
  [[ "$output" == *"(reboot pendente)"* ]]
  [[ "$output" == *"3 snapshot(s)"* ]]
  [[ "$output" == *"setup íntegro"* ]]
}

@test "pretty: DMS sem plugins e Timeshift sem sudo" {
  _fake_collectors
  hc_dms_plugins() { :; }
  hc_timeshift_summary() { printf 'sudo-necessário||'; }
  run hc_render_pretty
  [[ "$output" == *"sem plugins instalados"* ]]
  [[ "$output" == *"inventário indisponível"* ]]
  [[ "$output" == *"pacman ausente"* ]]
}

@test "summary box: nuvem ligada sem restic/rclone derruba o veredito" {
  echo TIMESHIFT_CLOUD_BACKUP=1 > "$FU_CONFIG_FILE"
  stub pacman 0 ""
  HC_SUMMARY_DISTRO=Arch HC_SUMMARY_KF='k|k|0' HC_SUMMARY_DT='d|w|s' HC_SUMMARY_TS='ausente||'
  hc_render_summary_box > "$BATS_TEST_TMPDIR/out"
  output="$(cat "$BATS_TEST_TMPDIR/out")"
  [[ "$output" == *"TIMESHIFT_CLOUD_BACKUP=1 mas restic/rclone ausentes"* ]]
  [[ "$output" != *"setup íntegro"* ]]
}

@test "json: plugins do DMS e roteamento do healthcheck_main" {
  _fake_collectors
  run hc_render_json
  [[ "$output" == *'"plugins":[{"name":"a","branch":"main","state":"limpo","note":"ok"},'* ]]
  hc_render_json() { echo json; }
  hc_render_pretty() { echo pretty; }
  JSON_SUMMARY=1
  [ "$(healthcheck_main)" = json ]
  JSON_SUMMARY=0
  [ "$(healthcheck_main)" = pretty ]
}

@test "dms_active pelo diretório de plugins; fetch sintetizado; nuvem incompleta" {
  export DMS_PLUGINS_DIR="$BATS_TEST_TMPDIR/plugins"
  run hc_dms_active
  [ "$status" -eq 1 ]
  mkdir -p "$DMS_PLUGINS_DIR"
  run hc_dms_active
  [ "$status" -eq 0 ]
  run hc_run_fetch
  [[ "$output" == *"OS:"* ]]
  echo TIMESHIFT_CLOUD_BACKUP=1 > "$FU_CONFIG_FILE"
  run hc_cloud_backup_lines
  [[ "$output" == "em-uso-incompleto|"* ]]
}

@test "pretty: DMS não detectado e Timeshift ausente" {
  _fake_collectors
  hc_dms_active() { return 1; }
  hc_timeshift_summary() { printf 'ausente||'; }
  run hc_render_pretty
  [[ "$output" == *"não detectado"* ]]
  [[ "$output" == *"não instalado"* ]]
}
