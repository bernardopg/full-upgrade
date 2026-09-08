#!/usr/bin/env bash
# lib/healthcheck.sh — inventário read-only do setup da máquina (--healthcheck).
# Sourced pelo entrypoint (depois de config/catalog). Não executar direto.
#
# Contrato:
#   - 100% read-only: nada instala, move ou apaga. sudo apenas com -n (não
#     interativo) e só onde realmente precisa (inventário do Timeshift).
#   - Coletores são funções testáveis (entrada/saída texto puro); uma seção
#     falível nunca derruba o relatório — vira "indisponível".
#   - Duas saídas: pretty (default) e JSON (--healthcheck --json).
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# ── Primitivas de sistema ─────────────────────────────────────────────────────

# Campo KEY de /etc/os-release ("<desconhecida>" quando ausente).
hc_os_release_field() {
  local key="$1" line
  if [[ -r /etc/os-release ]]; then
    line="$(grep -m1 "^${key}=" /etc/os-release 2>/dev/null || true)"
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
  fi
  printf '%s' "${line:-<desconhecida>}"
}

# Uptime humano a partir de /proc/uptime.
hc_uptime_human() {
  local s
  s="$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || printf 0)"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if (( s >= 86400 )); then
    printf '%dd %dh' $(( s / 86400 )) $(( (s % 86400) / 3600 ))
  elif (( s >= 3600 )); then
    printf '%dh %dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  else
    printf '%dm' $(( s / 60 ))
  fi
}

# MiB => representação humana compacta (>=1024 vira GiB).
hc_mib_human() {
  local mib="$1"
  [[ "$mib" =~ ^[0-9]+$ ]] || { printf '?'; return; }
  if (( mib >= 1024 )); then
    printf '%d.%d GiB' $(( mib / 1024 )) $(( (mib % 1024) * 10 / 1024 ))
  else
    printf '%d MiB' "$mib"
  fi
}

# ── Kernel ────────────────────────────────────────────────────────────────────

# Emite "rodando|instalado|reboot(0/1)". $1 opcional = kernel rodando (p/ teste).
hc_kernel_fields() {
  local running="${1:-$(uname -r 2>/dev/null || printf '?')}"
  local installed="" pkg="" p v
  if has pacman; then
    # Pacotes de kernel principal (linux, linux-lts, linux-zen, linux61...).
    # Com múltiplos kernels, prefere o pacote cuja versão casa com o rodando;
    # fallback: o primeiro da lista (ordem alfabética).
    local candidates
    candidates="$(pacman -Qq 2>/dev/null | grep -E '^(linux(-[a-z0-9]+)?|linux[0-9]{2,}(-[a-z0-9]+)?)$' || true)"
    if [[ -n "$candidates" ]]; then
      while IFS= read -r p; do
        v="$(pacman -Q "$p" 2>/dev/null | awk '{print $2}')"
        # uname usa traços onde a versão do pacote usa pontos (6.19.1.arch1-1
        # vs 6.19.1-arch1-1): normaliza antes de comparar.
        if [[ "$(hc_norm_kernel "$running")" == "$(hc_norm_kernel "$v")"* ]]; then
          pkg="$p"; break
        fi
      done <<<"$candidates"
      [[ -z "$pkg" ]] && pkg="$(head -1 <<<"$candidates")"
    fi
    [[ -n "$pkg" ]] && installed="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}' || true)"
  fi
  # Reboot pendente só quando NENHUM pacote casa com o rodando (normalizados):
  # uname "6.18.49-3-lts" casa com linux-lts "6.18.49-3" por prefixo — isso é
  # o mesmo kernel, não um reboot pendente.
  local reboot=1
  local run_n ins_n
  run_n="$(hc_norm_kernel "$running")"
  ins_n="$(hc_norm_kernel "$installed")"
  if [[ -z "$installed" || "$installed" == "?" ]]; then
    reboot=0   # sem pacote identificado: não acusar reboot sem evidência
  elif [[ "$run_n" == "$ins_n" || "$run_n" == "$ins_n"-* ]]; then
    reboot=0
  fi
  printf '%s|%s|%d' "$running" "${installed:-?}" "$reboot"
}

# Normaliza versão de kernel p/ comparação: pontos => traços (minúsculas).
hc_norm_kernel() {
  printf '%s' "${1,,}" | tr '.' '-'
}

# ── Desktop / sessão ──────────────────────────────────────────────────────────

# Emite "de|wm|session".
hc_desktop_fields() {
  local de="${XDG_CURRENT_DESKTOP:-}" wm="" session="${XDG_SESSION_TYPE:-}"
  if [[ -z "$session" ]]; then
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then session=wayland
    elif [[ -n "${DISPLAY:-}" ]]; then session=x11
    else session="tty"; fi
  fi
  local p
  for p in hyprland Hyprland sway i3 kwin_wayland kwin_x11 mutter gnome-shell \
           plasmashell xfwm4 openbox labwc niri river wayfire qtile icewm \
           awesome bspwm fluxbox herbstluftwm; do
    if pgrep -x "$p" >/dev/null 2>&1; then wm="$p"; break; fi
  done
  [[ -z "$wm" ]] && pgrep -x quickshell >/dev/null 2>&1 && wm="quickshell"
  [[ -z "$de" && -n "$wm" ]] && de="$wm"
  printf '%s|%s|%s' "${de:-<texto>}" "${wm:-<indefinido>}" "$session"
}

# TTY da sessão: XDG_VTNR > /sys/class/tty/tty0/active > tty corrente.
hc_tty_info() {
  local v
  if [[ -n "${XDG_VTNR:-}" ]]; then
    printf 'tty%s' "$XDG_VTNR"
    return 0
  fi
  if [[ -r /sys/class/tty/tty0/active ]]; then
    v="$(cat /sys/class/tty/tty0/active 2>/dev/null || true)"
    [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  fi
  v="$(tty 2>/dev/null || true)"
  if [[ "$v" == /dev/* ]]; then printf '%s' "$v"; else printf '%s' "<indefinido>"; fi
}

# Terminais reconhecidos na subida da cadeia de processos.
hc_known_terminals() {
  printf '%s\n' kitty alacritty konsole gnome-terminal-server wezterm \
    foot footclient ghostty xterm st st-256color rxvt urxvt tilix \
    terminator hyper ptyxis blackbox-terminal terminology sakura tmux screen zellij
}

# Terminal em uso: env (TERM_PROGRAM/KITTY/ALACRITTY) e depois cadeia de pais
# em /proc/*/comm. Fallback: $TERM.
hc_terminal_info() {
  case "${TERM_PROGRAM:-}" in
    ghostty|WezTerm|vscode|tmux|Apple_Terminal|iTerm.app)
      printf '%s' "$TERM_PROGRAM"; return 0 ;;
  esac
  [[ -n "${KITTY_WINDOW_ID:-}"       ]] && { printf 'kitty'; return 0; }
  [[ -n "${ALACRITTY_WINDOW_ID:-}"   ]] && { printf 'alacritty'; return 0; }

  local pid="${PPID:-1}" statline comm newpid i
  local -a known=()
  mapfile -t known < <(hc_known_terminals)
  for (( i = 0; i < 8; i++ )); do
    [[ -r "/proc/$pid/stat" ]] || break
    statline="$(cat "/proc/$pid/stat" 2>/dev/null)"; [[ -n "$statline" ]] || break
    # comm está entre parênteses (pode conter espaços): extração ancorada.
    comm="$(sed -n 's/^[0-9]* (\(.*\)) .*/\1/p' <<<"$statline")"
    if [[ -n "$comm" ]] && array_contains "$comm" "${known[@]}"; then
      printf '%s' "$comm"; return 0
    fi
    # Depois do último ") " vêm state e PPID; evitar um sed+awk por ascendente.
    local stat_after state
    stat_after="${statline##*) }"
    read -r state newpid _ <<<"$stat_after"
    [[ "$newpid" =~ ^[0-9]+$ ]] || break
    (( newpid <= 1 )) && break
    pid="$newpid"
  done
  printf '%s' "${TERM:-<indefinido>}"
}

# ── DankMaterialShell ─────────────────────────────────────────────────────────

# DMS ativo? quickshell/DMS em execução OU diretório de plugins presente.
hc_dms_active() {
  pgrep -x quickshell >/dev/null 2>&1 && return 0
  pgrep -f DankMaterialShell >/dev/null 2>&1 && return 0
  [[ -n "${DMS_PLUGINS_DIR:-}" && -d "$DMS_PLUGINS_DIR" ]] && return 0
  return 1
}

# Plugins do DMS: uma linha "nome|branch|estado|nota" por plugin (vazio = nada).
hc_dms_plugins() {
  local dir="${DMS_PLUGINS_DIR:-$HOME/.config/DankMaterialShell/plugins}"
  [[ -d "$dir" ]] || return 0
  local d name branch state note
  for d in "$dir"/*/; do
    [[ -d "$d" ]] || continue
    name="$(basename "$d")"
    if [[ -d "$d/.git" ]] && has git; then
      branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '?')"
      note="$(git -C "$d" log -1 --format=%s 2>/dev/null | head -c 60 || true)"
  if [[ -n "$(git -C "$d" --no-optional-locks status --porcelain 2>/dev/null | head -1)" ]]; then
        state="modificado"
      else
        state="limpo"
      fi
    else
      branch="-"; state="-"; note="sem git"
    fi
    printf '%s|%s|%s|%s\n' "$name" "$branch" "$state" "$note"
  done
}

# Resume linhas de hc_dms_plugins em "total|limpos|modificados|sem_git".
# Mantém a coleta e a apresentação desacopladas para o relatório continuar curto
# mesmo em instalações com dezenas de plugins.
hc_dms_plugin_summary() {
  local lines="$1" line state total=0 clean=0 modified=0 no_git=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    state="$(mem_field "$line" 3)"
    (( ++total ))
    case "$state" in
      limpo) (( ++clean )) ;;
      modificado) (( ++modified )) ;;
      *) (( ++no_git )) ;;
    esac
  done <<<"$lines"
  printf '%s|%s|%s|%s' "$total" "$clean" "$modified" "$no_git"
}

# ── Specs ─────────────────────────────────────────────────────────────────────

# Emite "modelo|núcleos".
hc_cpu_info() {
  local model cores
  model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' || true)"
  [[ -z "$model" ]] && model="$(lscpu 2>/dev/null | awk -F': +' '/Model name/ {print $2; exit}' || true)"
  cores="$(nproc 2>/dev/null || printf '?')"
  printf '%s|%s' "${model:-<indefinido>}" "$cores"
}

# Emite "total|disponível|swap" (MiB).
hc_mem_info() {
  local total avail swap
  total="$(awk '/^MemTotal/    {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf 0)"
  avail="$(awk '/^MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf 0)"
  swap="$(awk '/^SwapTotal/    {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || printf 0)"
  printf '%s|%s|%s' "$total" "$avail" "$swap"
}

# GPU via lspci (VGA/3D/Display); fallback nvidia-smi.
hc_gpu_info() {
  local g=""
  if has lspci; then
    g="$(lspci 2>/dev/null | grep -Ei 'vga|3d controller|display controller' \
        | sed 's/^[0-9a-f:.]* //' | head -3 | paste -sd ';' - || true)"
  fi
  if [[ -z "$g" ]] && has nvidia-smi; then
    g="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)"
  fi
  printf '%s' "${g:-<indefinida>}"
}

# Disco raiz: emite "tamanho|livre|fstype" (formato humano do df).
hc_disk_info() {
  local total free fstype
  total="$(df -h / 2>/dev/null | awk 'NR==2 {print $2}' || true)"
  free="$(df -h / 2>/dev/null | awk 'NR==2 {print $4}' || true)"
  fstype="$(findmnt -nro FSTYPE / 2>/dev/null || printf '?')"
  printf '%s|%s|%s' "${total:-?}" "${free:-?}" "${fstype:-?}"
}

# ── Gerenciadores de pacotes e ferramentas ────────────────────────────────────

# Catálogo de gerenciadores: nome|comando de versão (barato e não-invasivo).
hc_pm_catalog() {
  cat <<'EOF'
pacman|pacman --version
paru|paru -V
yay|yay -V
pikaur|pikaur -V
flatpak|flatpak --version
snap|snap version
npm|npm --version
pnpm|pnpm --version
bun|bun --version
deno|deno --version
pip|pip --version
uv|uv --version
pipx|pipx --version
poetry|poetry --version
cargo|cargo --version
rustup|rustup --version
gem|gem --version
go|go version
dotnet|dotnet --version
ghcup|ghcup --version
arduino-cli|arduino-cli version
EOF
}

# Uma linha "nome|caminho|versão(1ª linha)" por gerenciador PRESENTE.
hc_pm_list() {
  local name vercmd path ver
  while IFS='|' read -r name vercmd; do
    [[ -n "$name" ]] || continue
    path="$(command -v "$name" 2>/dev/null || true)"
    [[ -n "$path" ]] || continue
    ver="$(timeout 6 bash -c "$vercmd" 2>/dev/null | head -1 | cut -c1-60 || true)"
    printf '%s|%s|%s\n' "$name" "$path" "${ver:-?}"
  done < <(hc_pm_catalog)
}

# Catálogo de ferramentas relevantes ao full-upgrade (um nome por linha).
hc_tool_catalog() {
  cat <<'EOF'
timeshift
snapper
restic
rclone
borg
btrfs
smartctl
nvme
fwupdmgr
bootctl
reflector
rate-mirrors
arch-audit
cargo-audit
yad
notify-send
needrestart
checkservices
fastfetch
neofetch
EOF
}

# Uma linha "nome|presente|caminho" ou "nome|ausente|" por ferramenta.
hc_tool_list() {
  local t path state
  while IFS= read -r t; do
    [[ -n "$t" ]] || continue
    path="$(command -v "$t" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
      state="presente"
    else
      state="ausente"
    fi
    printf '%s|%s|%s\n' "$t" "$state" "$path"
  done < <(hc_tool_catalog)
}

# ── Timeshift ─────────────────────────────────────────────────────────────────

# Parser puro da saída de `timeshift --list`: emite "count|latest".
# Linhas de snapshot: "N> AAAA-MM-DD[_ ]HH-MM-SS  ...".
hc_parse_timeshift_list() {
  local text="$1" count latest
  count="$(grep -cE '^[[:space:]]*[0-9]+[[:space:]]*>' <<<"$text" || true)"
  latest=""
  if (( count > 0 )); then
    latest="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*>' <<<"$text" \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[_ ][0-9]{2}-[0-9]{2}-[0-9]{2}' \
      | sort -r | head -1 || true)"
  fi
  printf '%d|%s' "$count" "$latest"
}

# Saída crua do inventário: usuário primeiro; se inconclusiva, tenta sudo -n.
hc_timeshift_raw_list() {
  local out out2 priv_cmd
  local -a priv_tokens=()
  priv_cmd="${PRIV_CMD:-}"
  [[ -n "$priv_cmd" ]] || priv_cmd="$(config_file_value PRIV_CMD 2>/dev/null || true)"
  [[ -n "$priv_cmd" ]] || priv_cmd="$(detect_priv_cmd 2>/dev/null || true)"
  out="$(timeout 15 timeshift --list 2>&1 || true)"
  if grep -qE '^[[:space:]]*[0-9]+[[:space:]]*>|No snapshots' <<<"$out"; then
    printf '%s' "$out"; return 0
  fi
  [[ -n "$priv_cmd" ]] || { printf '%s' "$out"; return 0; }
  read -r -a priv_tokens <<<"$priv_cmd"
  out2="$(timeout 15 "${priv_tokens[@]}" -n timeshift --list 2>&1 || true)"
  if grep -qE '^[[:space:]]*[0-9]+[[:space:]]*>|No snapshots' <<<"$out2"; then
    printf '%s' "$out2"; return 0
  fi
  printf '%s' "$out"
}

# Emite "estado|count|latest". estado: ausente|ok|sudo-necessário.
hc_timeshift_summary() {
  has timeshift || { printf 'ausente||'; return 0; }
  local raw parsed count latest
  raw="$(hc_timeshift_raw_list)"
  parsed="$(hc_parse_timeshift_list "$raw")"
  count="${parsed%%|*}"; latest="${parsed#*|}"
  if (( count > 0 )) || grep -q 'No snapshots' <<<"$raw"; then
    printf 'ok|%s|%s' "$count" "$latest"
  else
    printf 'sudo-necessário||'
  fi
}

# ── Backup em nuvem ───────────────────────────────────────────────────────────

# Linhas: "em-uso|ferramenta|detalhe", "em-uso-incompleto|...|...",
#          "rclone-remotes|lista", "instalado|ferramenta".
hc_cloud_backup_lines() {
  # 1) Config do full-upgrade: réplica Timeshift→Restic/rclone (valor do ARQUIVO).
  local tscb repo
  tscb="$(config_file_value TIMESHIFT_CLOUD_BACKUP)"
  repo="$(config_file_value TIMESHIFT_CLOUD_REPOSITORY)"
  if [[ "$tscb" == "1" ]] && has restic && has rclone; then
    printf 'em-uso|Timeshift → Restic (rclone)|repo: %s\n' "${repo:-?}"
  elif [[ "$tscb" == "1" ]]; then
    printf 'em-uso-incompleto|Timeshift → Restic (rclone)|config ativo mas restic/rclone ausentes\n'
  fi
  # 2) Remotes rclone configurados (apenas nomes).
  if has rclone; then
    local remotes
    remotes="$(timeout 6 rclone listremotes 2>/dev/null | paste -sd ' ' - || true)"
    [[ -n "$remotes" ]] && printf 'rclone-remotes|%s\n' "$remotes"
  fi
  # 3) Ferramentas de backup instaladas (presença ≠ em uso), sem duplicar.
  local t
  for t in borg kopia deja-dup pika-backup vorta syncthing restic rclone; do
    has "$t" && printf 'instalado|%s\n' "$t"
  done | awk '!seen[$0]++'
  return 0
}

# ── Fetch (fastfetch/neofetch/sintetizado) ────────────────────────────────────

# Nome da ferramenta de fetch disponível (ou "sintetizado").
hc_fetch_tool() {
  if has fastfetch; then printf 'fastfetch'
  elif has neofetch; then printf 'neofetch'
  else printf 'sintetizado'; fi
}

hc_run_fetch() {
  local tool
  tool="$(hc_fetch_tool)"
  case "$tool" in
    fastfetch) timeout 10 fastfetch 2>/dev/null || true ;;
    neofetch)  timeout 10 neofetch 2>/dev/null || true ;;
    *)         hc_synthetic_fetch ;;
  esac
}

# Fetch sintetizado quando nem fastfetch nem neofetch existem.
hc_synthetic_fetch() {
  local os arch cpu mem
  os="$(hc_os_release_field PRETTY_NAME)"
  arch="$(uname -m 2>/dev/null || printf '?')"
  cpu="$(hc_cpu_info)"
  mem="$(hc_mem_info)"
  printf '  OS:     %s (%s)\n' "$os" "$arch"
  printf '  Kernel: %s\n' "$(uname -r 2>/dev/null || printf '?')"
  printf '  CPU:    %s (%s núcleos)\n' "${cpu%%|*}" "${cpu#*|}"
  printf '  RAM:    %s (%s disponíveis)\n' \
    "$(hc_mib_human "${mem%%|*}")" "$(hc_mib_human "$(mem_field "$mem" 2)")"
}

# Campo N (1-based) de uma string "a|b|c".
mem_field() {
  local s="$1" n="$2" i v
  for (( i = 1; i <= n; i++ )); do
    v="${s%%|*}"; s="${s#*|}"
  done
  printf '%s' "$v"
}

# ── Renderização pretty ───────────────────────────────────────────────────────

hc_section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$(ui_hr "$HR_HEAVY")" "$C_RESET"
  printf '%s %s %s\n' "$C_CYAN" "$1" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$(ui_hr "$HR_LIGHT")" "$C_RESET"
}

hc_kv() {
  # ui_wrap mede ANSI corretamente e mantém o relatório legível em terminais
  # estreitos; antes, valores longos (GPU, remotes e plugins) vazavam colunas.
  local key="$1" value="$2" prefix
  prefix="  $(ui_pad "$key" 18) "
  ui_wrap "${C_CYAN}${prefix}${C_RESET}${value}" "$(ui_width)"
}

# Entrada principal do --healthcheck.
healthcheck_main() {
  if (( ${JSON_SUMMARY:-0} == 1 )); then
    hc_render_json
    return $?
  fi
  hc_render_pretty
  return $?
}

hc_render_pretty() {
  # ── Coleta única ──
  local distro kf kernel_run kernel_inst reboot
  distro="$(hc_os_release_field PRETTY_NAME)"
  kf="$(hc_kernel_fields)"
  kernel_run="${kf%%|*}"
  kernel_inst="$(mem_field "$kf" 2)"
  reboot="${kf##*|}"

  local dt wm session tty_inf term_inf dms_active=0
  dt="$(hc_desktop_fields)"
  wm="$(mem_field "$dt" 2)"
  session="${dt##*|}"
  tty_inf="$(hc_tty_info)"
  term_inf="$(hc_terminal_info)"
  hc_dms_active && dms_active=1

  local cpu mem disk
  cpu="$(hc_cpu_info)"
  mem="$(hc_mem_info)"
  disk="$(hc_disk_info)"

  printf '%sFull-Upgrade Healthcheck%s %s(v%s · %s)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "${SCRIPT_VERSION:-?}" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"

  hc_section "Sistema"
  hc_kv "Distro" "$distro"
  hc_kv "Kernel" "$kernel_run"
  hc_kv "Kernel instalado" "$kernel_inst"
  if (( reboot == 1 )); then
    hc_kv "Reboot" "${C_YELLOW}pendente (kernel novo instalado)${C_RESET}"
  else
    hc_kv "Reboot" "não pendente"
  fi
  hc_kv "Arquitetura" "$(uname -m 2>/dev/null || printf '?')"
  hc_kv "Uptime" "$(hc_uptime_human)"

  hc_section "Desktop e sessão"
  hc_kv "DE/WM" "${dt%%|*} ($wm)"
  hc_kv "Sessão" "$session"
  hc_kv "TTY" "$tty_inf"
  hc_kv "Terminal" "$term_inf"
  if (( dms_active == 1 )); then
    local plugins plugin_count=0 p_line p_name p_rest
    plugins="$(hc_dms_plugins)"
    plugin_count="$(grep -c . <<<"$plugins" 2>/dev/null || true)"
    if [[ -n "$plugins" ]]; then
      local plugin_summary clean_plugins modified_plugins no_git_plugins p_state p_note
      plugin_summary="$(hc_dms_plugin_summary "$plugins")"
      plugin_count="${plugin_summary%%|*}"
      clean_plugins="$(mem_field "$plugin_summary" 2)"
      modified_plugins="$(mem_field "$plugin_summary" 3)"
      no_git_plugins="$(mem_field "$plugin_summary" 4)"
      hc_kv "DankMaterialShell" "${C_GREEN}ativo${C_RESET} — $plugin_count plugin(s): $clean_plugins limpo(s), $modified_plugins modificado(s), $no_git_plugins sem git"
      # Destaque somente o que exige atenção; o JSON mantém o inventário completo.
      while IFS= read -r p_line; do
        [[ -n "$p_line" ]] || continue
        p_name="${p_line%%|*}"
        p_state="$(mem_field "$p_line" 3)"
        [[ "$p_state" == "modificado" ]] || continue
        p_note="$(mem_field "$p_line" 4)"
        hc_kv "  modificado" "$p_name (branch $(mem_field "$p_line" 2) · $p_note)"
      done <<<"$plugins"
    else
      hc_kv "DankMaterialShell" "${C_GREEN}ativo${C_RESET} — sem plugins instalados"
    fi
  else
    hc_kv "DankMaterialShell" "${C_DIM}não detectado${C_RESET}"
  fi

  hc_section "Specs"
  hc_kv "CPU" "${cpu%%|*} (${cpu#*|} núcleos)"
  hc_kv "RAM" "$(hc_mib_human "${mem%%|*}") (disponível: $(hc_mib_human "$(mem_field "$mem" 2)"))"
  hc_kv "Swap" "$(hc_mib_human "${mem##*|}")"
  hc_kv "GPU" "$(hc_gpu_info)"
  hc_kv "Disco /" "${disk%%|*} · livre $(mem_field "$disk" 2) · ${disk##*|}"

  hc_section "Gerenciadores de pacotes"
  local pm_line pm_count=0
  while IFS= read -r pm_line; do
    [[ -n "$pm_line" ]] || continue
    (( ++pm_count ))
    hc_kv "${pm_line%%|*}" "${pm_line#*|}"
  done < <(hc_pm_list)
  (( pm_count == 0 )) && hc_kv "-" "nenhum gerenciador reconhecido encontrado"

  hc_section "Ferramentas do full-upgrade"
  local tool_line present_count=0 missing_count=0
  local -a missing=()
  while IFS= read -r tool_line; do
    [[ -n "$tool_line" ]] || continue
    local tn="${tool_line%%|*}" t_rest="${tool_line#*|}"
    if [[ "$t_rest" == presente* ]]; then
      (( ++present_count ))
      hc_kv "$tn" "${C_GREEN}presente${C_RESET} ${t_rest#presente|}"
    else
      (( ++missing_count ))
      missing+=("$tn")
    fi
  done < <(hc_tool_list)
  hc_kv "Resumo" "$present_count presentes, $missing_count ausentes"
  (( missing_count > 0 )) && hc_kv "Ausentes" "${missing[*]}"

  hc_section "Timeshift"
  local ts_summary ts_state ts_snap ts_latest
  ts_summary="$(hc_timeshift_summary)"
  ts_state="${ts_summary%%|*}"
  ts_snap="$(mem_field "$ts_summary" 2)"
  ts_latest="${ts_summary##*|}"
  case "$ts_state" in
    ausente)          hc_kv "Timeshift" "${C_DIM}não instalado${C_RESET}" ;;
    sudo-necessário)  hc_kv "Timeshift" "${C_YELLOW}inventário indisponível (sudo -n sem senha)${C_RESET}" ;;
    *)
      hc_kv "Snapshots" "$ts_snap"
      [[ -n "$ts_latest" ]] && hc_kv "Mais recente" "$ts_latest"
      ;;
  esac

  hc_section "Backup em nuvem"
  local cb_line cb_any=0 cb_in_use=""
  while IFS= read -r cb_line; do
    [[ -n "$cb_line" ]] || continue
    cb_any=1
    case "$cb_line" in
      em-uso-incompleto*)  hc_kv "Em uso (incompleto)" "${C_YELLOW}${cb_line#em-uso-incompleto|}${C_RESET}" ;;
      em-uso*)             cb_in_use="$cb_line"; hc_kv "Em uso" "${C_GREEN}${cb_line#em-uso|}${C_RESET}" ;;
      rclone-remotes*)     hc_kv "Remotes rclone" "${cb_line#rclone-remotes|}" ;;
      instalado*)          hc_kv "Instalado" "${cb_line#instalado|}" ;;
    esac
  done < <(hc_cloud_backup_lines)
  (( cb_any == 0 )) && hc_kv "-" "nenhuma ferramenta de backup detectada"

  hc_section "Fetch ($(hc_fetch_tool))"
  hc_run_fetch

  HC_SUMMARY_DISTRO="$distro" HC_SUMMARY_KF="$kf" HC_SUMMARY_DT="$dt"
  HC_SUMMARY_TTY="$tty_inf" HC_SUMMARY_TERM="$term_inf" HC_SUMMARY_CPU="$cpu"
  HC_SUMMARY_MEM="$mem" HC_SUMMARY_DISK="$disk" HC_SUMMARY_PM="$pm_count"
  HC_SUMMARY_TS="$ts_summary" HC_SUMMARY_CB="$cb_in_use"
  hc_section "Resumo do healthcheck"
  hc_render_summary_box
  return 0
}

# Caixa de resumo + veredito. Re-coleta (barato) para ser testável isolada.
hc_render_summary_box() {
  local distro="${HC_SUMMARY_DISTRO:-}" kf="${HC_SUMMARY_KF:-}" kernel_run reboot
  local dt="${HC_SUMMARY_DT:-}" wm session tty_inf="${HC_SUMMARY_TTY:-}" term_inf="${HC_SUMMARY_TERM:-}"
  local cpu="${HC_SUMMARY_CPU:-}" mem="${HC_SUMMARY_MEM:-}" disk="${HC_SUMMARY_DISK:-}"
  local pm_count="${HC_SUMMARY_PM:-0}" ts_summary="${HC_SUMMARY_TS:-}" ts_snap cb_in_use="${HC_SUMMARY_CB:-}"
  [[ -n "$distro$kf$dt$cpu$mem$disk$ts_summary" ]] || return 1
  kernel_run="${kf%%|*}"
  reboot="${kf##*|}"
  wm="$(mem_field "$dt" 2)"
  session="${dt##*|}"
  local cpu_model cpu_cores
  cpu_model="${cpu%%|*}"
  cpu_cores="${cpu#*|}"
  ts_snap="$(mem_field "$ts_summary" 2)"

  local w inner
  w="$(ui_width)"
  inner=$(( w - 4 ))
  printf '  %s%s%s\n' "$C_DIM" "$(ui_hr "$HR_HEAVY" "$inner")" "$C_RESET"
  hc_kv "Distro" "$distro"
  if (( reboot == 1 )); then
    hc_kv "Kernel" "$kernel_run ${C_YELLOW}(reboot pendente)${C_RESET}"
  else
    hc_kv "Kernel" "$kernel_run"
  fi
  hc_kv "DE/WM" "${dt%%|*} ($wm · $session)"
  hc_kv "Terminal" "$term_inf ($tty_inf)"
  hc_kv "CPU" "$cpu_model (${cpu_cores} núcleos)"
  hc_kv "RAM" "$(hc_mib_human "${mem%%|*}")"
  hc_kv "Disco /" "${disk%%|*} · livre $(mem_field "$disk" 2) · ${disk##*|}"
  hc_kv "Gerenciadores" "$pm_count presente(s)"
  if [[ "$ts_snap" =~ ^[0-9]+$ ]] && has timeshift; then
    hc_kv "Timeshift" "$ts_snap snapshot(s)"
  else
    hc_kv "Timeshift" "indisponível"
  fi
  if [[ -n "$cb_in_use" ]]; then
    local cb_txt="${cb_in_use#em-uso|}"
    hc_kv "Backup nuvem" "${cb_txt//|/ · }"
  else
    hc_kv "Backup nuvem" "nenhum configurado no full-upgrade"
  fi
  hc_kv "Versão" "full-upgrade v${SCRIPT_VERSION:-?}"
  printf '  %s%s%s\n' "$C_DIM" "$(ui_hr "$HR_HEAVY" "$inner")" "$C_RESET"

  # Veredito: pacman é crítico; nuvem ativa exige restic+rclone.
  local integrity_ok=1
  has pacman || integrity_ok=0
  if [[ "$(config_file_value TIMESHIFT_CLOUD_BACKUP)" == "1" ]] && { ! has restic || ! has rclone; }; then
    printf '  %sVeredito: TIMESHIFT_CLOUD_BACKUP=1 mas restic/rclone ausentes%s\n' \
      "$C_YELLOW" "$C_RESET"
    integrity_ok=0
  fi
  if (( integrity_ok == 1 )); then
    printf '  %sVeredito: setup íntegro para a operação do full-upgrade.%s\n' \
      "$C_GREEN" "$C_RESET"
  else
    has pacman || printf '  %s%sVeredito: pacman ausente — máquina não é Arch-like?%s\n' \
      "$C_RED" "$C_BOLD" "$C_RESET"
  fi
  return 0
}

# ── Saída JSON (--healthcheck --json) ─────────────────────────────────────────

hc_render_json() {
  local kf k_rest kernel_run kernel_inst reboot
  kf="$(hc_kernel_fields)"
  kernel_run="${kf%%|*}"
  k_rest="${kf#*|}"
  kernel_inst="${k_rest%%|*}"
  reboot="${k_rest##*|}"

  local dt wm session
  dt="$(hc_desktop_fields)"
  wm="$(mem_field "$dt" 2)"
  session="${dt##*|}"

  local cpu mem disk ts
  cpu="$(hc_cpu_info)"
  mem="$(hc_mem_info)"
  disk="$(hc_disk_info)"
  ts="$(hc_timeshift_summary)"

  local plugins_json="[]"
  if hc_dms_active; then
    local line pn pb ps
    local -a acc=()
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      pn="$(json_escape "${line%%|*}")"
      pb="$(json_escape "$(mem_field "$line" 2)")"
      ps="$(json_escape "$(mem_field "$line" 3)")"
      local pnote
      pnote="$(json_escape "$(mem_field "$line" 4)")"
      acc+=("{\"name\":$pn,\"branch\":$pb,\"state\":$ps,\"note\":$pnote}")
    done < <(hc_dms_plugins)
    (( ${#acc[@]} > 0 )) && plugins_json="[$(printf '%s\n' "${acc[@]}" | paste -sd, -)]"
  fi

  local pm_count cb_json
  pm_count="$(hc_pm_list | wc -l | tr -d ' ')"
  cb_json="$(hc_cloud_backup_json_lines)"

  cat <<EOF
{"tool":"full-upgrade","version":$(json_escape "${SCRIPT_VERSION:-}"),"generated_at":$(json_escape "$(date -Is)"),"distro":$(json_escape "$(hc_os_release_field PRETTY_NAME)"),"arch":$(json_escape "$(uname -m)"),"uptime":$(json_escape "$(hc_uptime_human)"),"kernel":{"running":$(json_escape "$kernel_run"),"installed":$(json_escape "$kernel_inst"),"reboot_pending":$reboot},"desktop":{"de":$(json_escape "${dt%%|*}"),"wm":$(json_escape "$wm"),"session":$(json_escape "$session"),"tty":$(json_escape "$(hc_tty_info)"),"terminal":$(json_escape "$(hc_terminal_info)")},"dms":{"active":$(hc_dms_active && printf true || printf false),"plugins":$plugins_json},"cpu":{"model":$(json_escape "${cpu%%|*}"),"cores":$(json_escape "${cpu#*|}")},"memory_mib":{"total":${mem%%|*},"available":$(mem_field "$mem" 2),"swap":${mem##*|}},"gpu":$(json_escape "$(hc_gpu_info)"),"disk_root":{"total":$(json_escape "${disk%%|*}"),"free":$(json_escape "$(mem_field "$disk" 2)"),"fstype":$(json_escape "${disk##*|}")},"package_managers_count":$pm_count,"tools_present":$(hc_tool_list | grep -c '|presente|' || true),"timeshift":{"state":$(json_escape "${ts%%|*}"),"snapshots":$(json_escape "$(mem_field "$ts" 2)"),"latest":$(json_escape "${ts##*|}")},"cloud_backup":$cb_json}
EOF
}

# Linhas do backup em nuvem como array JSON de {kind, detail}.
hc_cloud_backup_json_lines() {
  local line first=1
  local out=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    (( first )) || out+=","
    first=0
    out+="{\"kind\":$(json_escape "${line%%|*}"),\"detail\":$(json_escape "${line#*|}")}"
  done < <(hc_cloud_backup_lines)
  printf '[%s]' "$out"
}
