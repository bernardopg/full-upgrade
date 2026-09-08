#!/usr/bin/env bats
# tests/healthcheck.bats — coletores do inventário de setup (--healthcheck, R3)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_healthcheck_libs
  NO_COLOR=1
  COLUMNS=120
}

@test "config_file_value: lê configuração sem executar comandos" {
  marker="${BATS_TEST_TMPDIR}/executado"
  FU_CONFIG_FILE="${BATS_TEST_TMPDIR}/config"
  printf 'touch %q\nTIMESHIFT_CLOUD_BACKUP=1\n' "$marker" >"$FU_CONFIG_FILE"
  run config_file_value TIMESHIFT_CLOUD_BACKUP
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  [ ! -e "$marker" ]
}

@test "config_file_value: ignora comentário inline fora de aspas" {
  FU_CONFIG_FILE="${BATS_TEST_TMPDIR}/config-comment"
  printf 'TIMESHIFT_CLOUD_BACKUP="1" # comentário\n' >"$FU_CONFIG_FILE"
  run config_file_value TIMESHIFT_CLOUD_BACKUP
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ── hc_os_release_field ───────────────────────────────────────────────────────

@test "hc_os_release_field: lê PRETTY_NAME do /etc/os-release real" {
  run hc_os_release_field PRETTY_NAME
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "hc_os_release_field: chave inexistente => <desconhecida>" {
  run hc_os_release_field CHAVE_QUE_NAO_EXISTE_XYZ
  [ "$output" = "<desconhecida>" ]
}

# ── hc_kernel_fields ──────────────────────────────────────────────────────────

@test "hc_kernel_fields: kernel rodando == instalado => reboot 0" {
  # Fixture: pacman stub que diz linux 6.18.49-3 instalado.
  stub_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_bin"
  cat >"${stub_bin}/pacman" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-Qq") echo "linux"; echo "linux-firmware" ;;
  "-Q linux") echo "linux 6.18.49-3" ;;
esac
EOF
  chmod +x "${stub_bin}/pacman"
  PATH="$stub_bin:$PATH" run hc_kernel_fields "6.18.49-3-lts"
  # uname -lts casa com o pacote por prefixo normalizado (não é reboot)
  [ "$output" = "6.18.49-3-lts|6.18.49-3|0" ]
}

@test "hc_kernel_fields: kernel divergente => reboot pendente" {
  stub_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_bin"
  cat >"${stub_bin}/pacman" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-Qq") echo "linux" ;;
  "-Q linux") echo "linux 6.19.1-1" ;;
esac
EOF
  chmod +x "${stub_bin}/pacman"
  PATH="$stub_bin:$PATH" run hc_kernel_fields "6.18.49-3-lts"
  [ "$output" = "6.18.49-3-lts|6.19.1-1|1" ]
}

@test "hc_kernel_fields: sem pacman => instalado ? e reboot 0" {
  stub_bin="${BATS_TEST_TMPDIR}/sem-pacman"
  mkdir -p "$stub_bin"
  ln -sf "$(command -v tr)" "$stub_bin/tr"
  PATH="$stub_bin" run hc_kernel_fields "6.18.49-3-lts"
  [ "$output" = "6.18.49-3-lts|?|0" ]
}

@test "hc_kernel_fields: múltiplos kernels, prefere o que casa com o rodando" {
  stub_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_bin"
  cat >"${stub_bin}/pacman" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-Qq") echo "linux"; echo "linux-lts" ;;
  "-Q linux") echo "linux 99.0-1" ;;
  "-Q linux-lts") echo "linux-lts 6.18.49-3" ;;
esac
EOF
  chmod +x "${stub_bin}/pacman"
  PATH="$stub_bin:$PATH" run hc_kernel_fields "6.18.49-3-lts"
  # uname -lts casa com o pacote por prefixo normalizado (não é reboot)
  [ "$output" = "6.18.49-3-lts|6.18.49-3|0" ]
}

# ── hc_desktop_fields / hc_tty_info / hc_terminal_info ────────────────────────

@test "hc_desktop_fields: session deduz de WAYLAND_DISPLAY sem XDG_SESSION_TYPE" {
  XDG_CURRENT_DESKTOP="" XDG_SESSION_TYPE="" WAYLAND_DISPLAY="wayland-1" DISPLAY="" \
    run hc_desktop_fields
  [[ "$output" == *"|wayland" ]]
}

@test "hc_desktop_fields: sem nada => session tty" {
  XDG_CURRENT_DESKTOP="" XDG_SESSION_TYPE="" WAYLAND_DISPLAY="" DISPLAY="" \
    run hc_desktop_fields
  [[ "$output" == *"|tty" ]]
}

@test "hc_tty_info: XDG_VTNR tem prioridade" {
  XDG_VTNR=7 run hc_tty_info
  [ "$output" = "tty7" ]
}

@test "hc_terminal_info: TERM_PROGRAM reconhecido vence" {
  TERM_PROGRAM=ghostty run hc_terminal_info
  [ "$output" = "ghostty" ]
}

@test "hc_terminal_info: KITTY_WINDOW_ID => kitty" {
  TERM_PROGRAM="" KITTY_WINDOW_ID=1 run hc_terminal_info
  [ "$output" = "kitty" ]
}

# ── hc_dms_* ──────────────────────────────────────────────────────────────────

@test "hc_dms_plugins: lista plugins de um diretório fixture" {
  dir="${BATS_TEST_DIRNAME}/fixtures/hc-dms-plugins"
  DMS_PLUGINS_DIR="$dir" run hc_dms_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"plugin-fake|"* ]]
}

@test "hc_dms_plugins: diretório ausente => vazio" {
  DMS_PLUGINS_DIR="${BATS_TEST_TMPDIR}/nao-existe" run hc_dms_plugins
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hc_dms_active: diretório de plugins presente => ativo" {
  dir="${BATS_TEST_DIRNAME}/fixtures/hc-dms-plugins"
  DMS_PLUGINS_DIR="$dir" run hc_dms_active
  [ "$status" -eq 0 ]
}

# ── specs ─────────────────────────────────────────────────────────────────────

@test "hc_cpu_info: modelo e núcleos não vazios" {
  run hc_cpu_info
  [[ "$output" == *"|"* ]]
}

@test "hc_mem_info: três campos numéricos" {
  run hc_mem_info
  local total avail swap
  total="${output%%|*}"
  [ "$total" -gt 0 ]
}

@test "hc_disk_info: três campos (tamanho|livre|fstype)" {
  run hc_disk_info
  local count
  count="$(grep -o '|' <<<"$output" | wc -l)"
  [ "$count" -eq 2 ]
}

@test "hc_mib_human: 38784 MiB => GiB" {
  run hc_mib_human 38784
  [[ "$output" == *"GiB" ]]
}

@test "hc_mib_human: 512 MiB continua MiB" {
  run hc_mib_human 512
  [ "$output" = "512 MiB" ]
}

@test "mem_field: campo N de string com pipe" {
  run mem_field "a|b|c" 2
  [ "$output" = "b" ]
  run mem_field "a|b|c" 3
  [ "$output" = "c" ]
  run mem_field "a|b|c" 1
  [ "$output" = "a" ]
}

# ── gerenciadores e ferramentas ───────────────────────────────────────────────

@test "hc_pm_list: emite ao menos pacman em máquina Arch (ou vazio em CI)" {
  run hc_pm_list
  [ "$status" -eq 0 ]
  # Não força pacman (CI pode não ter), mas formato tem 3 campos quando há.
  if [ -n "$output" ]; then
    local first
    first="$(head -1 <<<"$output")"
    [ "$(grep -o '|' <<<"$first" | wc -l)" -eq 2 ]
  fi
}

@test "hc_pm_catalog: inclui os gerenciadores principais" {
  run hc_pm_catalog
  [[ "$output" == *"pacman|"* ]]
  [[ "$output" == *"paru|"* ]]
  [[ "$output" == *"flatpak|"* ]]
  [[ "$output" == *"npm|"* ]]
  [[ "$output" == *"cargo|"* ]]
}

@test "hc_tool_list: formato nome|estado|caminho para todas" {
  run hc_tool_list
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  # Cada linha tem exatamente 2 separadores e estado presente|ausente.
  local count=0 line state
  while IFS= read -r line; do
    [ "$(grep -o '|' <<<"$line" | wc -l)" -eq 2 ]
    state="$(cut -d'|' -f2 <<<"$line")"
    [[ "$state" == "presente" || "$state" == "ausente" ]]
    count=$(( count + 1 ))
  done <<<"$output"
  [ "$count" -ge 15 ]
}

# ── timeshift ─────────────────────────────────────────────────────────────────

@test "hc_parse_timeshift_list: conta snapshots e extrai o mais recente" {
  run hc_parse_timeshift_list "Mode:     RSYNC
0>  2025-04-14_10-31-44   Backup (Manual)     568.53 GB
1>  2025-04-21_10-32-01   Backup (Manual)     568.53 GB"
  [ "$output" = "2|2025-04-21_10-32-01" ]
}

@test "hc_parse_timeshift_list: sem snapshots => 0|vazio" {
  run hc_parse_timeshift_list "No snapshots found"
  [ "$output" = "0|" ]
}

@test "hc_parse_timeshift_list: saída vazia => 0|vazio" {
  run hc_parse_timeshift_list ""
  [ "$output" = "0|" ]
}

@test "hc_parse_timeshift_list: formato com espaço entre N e >" {
  run hc_parse_timeshift_list "0 > 2026-08-31 13-44-56  Backup"
  # Com separador de espaço, o timestamp sai como está (sem normalização).
  [ "$output" = "1|2026-08-31 13-44-56" ]
}

@test "hc_timeshift_summary: timeshift ausente => ausente" {
  stub_bin="${BATS_TEST_TMPDIR}/vazio"
  mkdir -p "$stub_bin"
  PATH="$stub_bin" PRIV_CMD=sudo run hc_timeshift_summary
  [ "$output" = "ausente||" ]
}

# ── backup em nuvem ───────────────────────────────────────────────────────────

@test "hc_cloud_backup_lines: config ativo mas restic ausente => em-uso-incompleto" {
  FU_CONFIG_FILE="${BATS_TEST_TMPDIR}/cfg-cloud"
  cat >"$FU_CONFIG_FILE" <<'EOF'
TIMESHIFT_CLOUD_BACKUP=1
TIMESHIFT_CLOUD_REPOSITORY="rclone:fake:repo"
EOF
  stub_bin="${BATS_TEST_TMPDIR}/bin-sem-restic"
  mkdir -p "$stub_bin"
  ln -sf "$(command -v awk)" "$stub_bin/awk"
  PATH="$stub_bin" run hc_cloud_backup_lines
  [[ "$output" == *"em-uso-incompleto|Timeshift → Restic (rclone)|config ativo mas restic/rclone ausentes"* ]]
}

@test "hc_cloud_backup_lines: sem config nem tools => vazio" {
  FU_CONFIG_FILE="${BATS_TEST_TMPDIR}/cfg-vazio"
  : >"$FU_CONFIG_FILE"
  stub_bin="${BATS_TEST_TMPDIR}/vazio"
  mkdir -p "$stub_bin"
  ln -sf "$(command -v awk)" "$stub_bin/awk"
  PATH="$stub_bin" run hc_cloud_backup_lines
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── fetch ─────────────────────────────────────────────────────────────────────

@test "hc_fetch_tool: sem fastfetch nem neofetch => sintetizado" {
  stub_bin="${BATS_TEST_TMPDIR}/vazio"
  PATH="$stub_bin" run hc_fetch_tool
  [ "$output" = "sintetizado" ]
}

@test "hc_synthetic_fetch: emite linhas OS/Kernel/CPU/RAM" {
  stub_bin="${BATS_TEST_TMPDIR}/vazio"
  PATH="$stub_bin:$PATH" run hc_synthetic_fetch
  [[ "$output" == *"OS:"* ]]
  [[ "$output" == *"Kernel:"* ]]
  [[ "$output" == *"CPU:"* ]]
  [[ "$output" == *"RAM:"* ]]
}

@test "hc_dms_plugin_summary: categoriza plugins limpos, modificados e sem git" {
  local plugins=$'alpha|main|limpo|ok\nbeta|dev|modificado|WIP\ngamma|-|-|sem git'
  run hc_dms_plugin_summary "$plugins"
  [ "$status" -eq 0 ]
  [ "$output" = "3|1|1|1" ]
}

@test "hc_render_json: preserva a nota de cada plugin DMS" {
  local dir="${BATS_TEST_DIRNAME}/fixtures/hc-dms-plugins"
  DMS_PLUGINS_DIR="$dir" run hc_render_json
  [ "$status" -eq 0 ]
  assert_json "$output" "d['dms']['plugins'][0]['note'] == 'sem git'"
}

# ── integração ────────────────────────────────────────────────────────────────

@test "hc_render_pretty: roda sem TTY e contém seções esperadas" {
  SCRIPT_VERSION="test"
  run hc_render_pretty
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sistema"* ]]
  [[ "$output" == *"Desktop e sessão"* ]]
  [[ "$output" == *"Specs"* ]]
  [[ "$output" == *"Gerenciadores de pacotes"* ]]
  [[ "$output" == *"Timeshift"* ]]
  [[ "$output" == *"Backup em nuvem"* ]]
  [[ "$output" == *"Resumo do healthcheck"* ]]
}

@test "hc_render_json: saída é JSON válido e tem chaves essenciais" {
  SCRIPT_VERSION="test"
  JSON_SUMMARY=1 run hc_render_json
  [ "$status" -eq 0 ]
  assert_json "$output" "'tool' in d and d['tool']=='full-upgrade'"
  assert_json "$output" "'kernel' in d and 'running' in d['kernel']"
  assert_json "$output" "'desktop' in d and 'terminal' in d['desktop']"
  assert_json "$output" "'timeshift' in d and 'snapshots' in d['timeshift']"
  assert_json "$output" "isinstance(d['cloud_backup'], list)"
  assert_json "$output" "isinstance(d['dms']['plugins'], list)"
}

@test "hc_render_summary_box: contém veredito" {
  SCRIPT_VERSION="test"
  run hc_render_pretty
  [[ "$output" == *"Veredito"* ]]
}
