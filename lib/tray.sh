#!/usr/bin/env bash
# lib/tray.sh — daemon do systray (ícone de bandeja) do full-upgrade.
# Dependência opcional: yad (e notify-send p/ notificações). Gateado por `has`.
# Sourced por full-upgrade.sh. Não executar direto.
#
# Camadas:
#   1) Funções PURAS (sem yad, sem rede) — testáveis via bats:
#      tray_compute_state, tray_icon_name_for_state, tray_tooltip_for_state,
#      tray_summary_counts, tray_summary_reboot_reason, tray_extract_json_field,
#      tray_count_list, tray_total_updates.
#   2) Funções de I/O leve: resolve ícone, lê último summary JSONL, probe do lock.
#   3) Loop yad (--notification --listen) + notificações em transições de estado.
#
# Estado (prioridade): running > error > attention > updates > idle
#   running   — full-upgrade em execução (lock ativo)
#   error     — último run real com fail
#   attention — último run com item doctor em todo (reboot/CVE/...)
#   updates   — checkupdates/AUR sinalizam pacotes
#   idle      — tudo em dia
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# ── Paths de estado do tray ────────────────────────────────────────────────────
TRAY_STATE_FILE="${LOG_DIR}/tray-state.json"
TRAY_PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/full-upgrade-tray.pid"
FU_RUN_LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/full-upgrade.lock"

# ─────────────────────────────────────────────────────────────────────────────
# Camada 1 — funções PURAS (sem I/O, sem yad)
# ─────────────────────────────────────────────────────────────────────────────

# Conta linhas não-vazias em stdin. Puro; usado p/ contar pacotes de updates.
tray_count_list() {
  local n
  n=$(grep -cve '^[[:space:]]*$' 2>/dev/null) || n=0
  printf '%s' "$n"
}

# Soma de contagens. Uso: tray_total_updates <repo> <aur> [flatpak]
tray_total_updates() {
  local total=0 v
  for v in "$@"; do
    [[ "$v" =~ ^[0-9]+$ ]] && total=$(( total + v ))
  done
  printf '%s' "$total"
}

# Extrai um campo JSON (string ou numérico) de uma linha JSON. Puro.
# Uso: tray_extract_json_field <linha_json> <campo>
tray_extract_json_field() {
  local line="$1" field="$2" v
  [[ -n "$line" && -n "$field" ]] || return 1
  v=$(printf '%s' "$line" | grep -oE "\"${field}\":\"[^\"]*\"|\"${field}\":-?[0-9]+" | head -1)
  [[ -n "$v" ]] || return 1
  v="${v#*:}"
  v="${v#\"}"; v="${v%\"}"
  printf '%s' "$v"
}

# Contas do último summary. Puro.
# Uso: tray_summary_counts <linha_summary>  ->  "todo fail reboot_flag"
tray_summary_counts() {
  local line="$1"
  [[ -n "$line" ]] || { printf '0 0 0'; return 0; }
  local todo fail reboot
  todo=$(tray_extract_json_field "$line" todo)
  fail=$(tray_extract_json_field "$line" fail)
  [[ "$todo" =~ ^[0-9]+$ ]] || todo=0
  [[ "$fail" =~ ^[0-9]+$ ]] || fail=0
  if tray_summary_has_reboot "$line"; then reboot=1; else reboot=0; fi
  printf '%s %s %s' "$todo" "$fail" "$reboot"
}

# 1 se a linha summary tem reboot_recommendation não-vazia. Puro.
tray_summary_has_reboot() {
  local line="$1"
  [[ -n "$line" ]] || return 1
  local rr
  rr=$(tray_summary_reboot_reason "$line")
  [[ -n "${rr//[[:space:]]/}" ]]
}

# Texto do reboot_recommendation de uma linha summary. Puro.
tray_summary_reboot_reason() {
  local line="$1"
  [[ -n "$line" ]] || return 0
  printf '%s' "$line" | sed -nE 's/.*"reboot_recommendation":"([^"]*)".*/\1/p'
}

# Calcula o estado a partir das entradas. Puro.
# Uso: tray_compute_state <running:0|1> <fail> <todo> <updates>
tray_compute_state() {
  local running="$1" fail="$2" todo="$3" updates="$4"
  (( running )) && { printf 'running'; return 0; }
  [[ "$fail" =~ ^[0-9]+$ ]] || fail=0
  [[ "$todo" =~ ^[0-9]+$ ]] || todo=0
  [[ "$updates" =~ ^[0-9]+$ ]] || updates=0
  (( fail > 0 ))   && { printf 'error';     return 0; }
  (( todo > 0 ))   && { printf 'attention'; return 0; }
  (( updates > 0 )) && { printf 'updates';   return 0; }
  printf 'idle'
}

# Nome lógico do ícone (sem extensão/caminho) por estado. Puro.
tray_icon_name_for_state() {
  case "$1" in
    running)   printf 'full-upgrade-tray-running' ;;
    error)     printf 'full-upgrade-tray-error' ;;
    attention) printf 'full-upgrade-tray-attention' ;;
    updates)   printf 'full-upgrade-tray-updates' ;;
    idle|*)    printf 'full-upgrade-tray-idle' ;;
  esac
}

# Tooltip curto (PT-BR) por estado. Puro.
# Uso: tray_tooltip_for_state <state> <updates> <todo> <fail> <reboot_reason>
tray_tooltip_for_state() {
  local state="$1" updates="$2" todo="$3" fail="$4" reboot="${5:-}"
  case "$state" in
    running) printf 'full-upgrade: executando…' ; return 0 ;;
    error)   printf 'full-upgrade: último run com %s falha(s)' "$fail"; return 0 ;;
  esac
  local -a parts=()
  if [[ -n "${reboot//[[:space:]]/}" ]]; then parts+=("Reboot pendente"); fi
  [[ "$todo" =~ ^[0-9]+$ ]] && (( todo > 0 )) && parts+=("$todo doctor todo")
  [[ "$updates" =~ ^[0-9]+$ ]] && (( updates > 0 )) && parts+=("$updates atualização(ões)")
  if (( ${#parts[@]} == 0 )); then
    printf 'full-upgrade: sistema atualizado'
    return 0
  fi
  local joined="" part
  for part in "${parts[@]}"; do
    if [[ -z "$joined" ]]; then joined="$part"; else joined="${joined} · ${part}"; fi
  done
  printf 'full-upgrade: %s' "$joined"
}

# ─────────────────────────────────────────────────────────────────────────────
# Camada 2 — I/O leve (sem yad)
# ─────────────────────────────────────────────────────────────────────────────

# Última linha "summary" do JSONL mais recente (rc 1 se indisponível).
tray_last_summary_line() {
  local jsonl="${LATEST_JSONL_LINK:-${LOG_DIR}/latest.jsonl}"
  [[ -r "$jsonl" ]] || return 1
  grep '"event":"summary"' "$jsonl" 2>/dev/null | tail -1
}

# "todo fail reboot" do último run real (0 0 0 se não houver).
tray_last_summary_counts() {
  local line
  line=$(tray_last_summary_line 2>/dev/null) || { printf '0 0 0'; return 0; }
  tray_summary_counts "$line"
}

# 1 (true) se uma instância de full-upgrade está em execução (lock ativo).
# Probe não-bloqueante: adquire e libera o lock imediatamente se estiver livre.
tray_is_full_upgrade_running() {
  local f="${FU_RUN_LOCK_FILE}"
  [[ -e "$f" ]] || return 1
  if has flock; then
    # rc 0 = lock adquirido = NÃO rodando; rc≠0 = lock ocupado = rodando.
    ( exec 9<>"$f" 2>/dev/null && flock -n 9 ) 2>/dev/null
    local rc=$?
    (( rc != 0 )) && return 0
    return 1
  fi
  # Fallback sem flock: pid vivo no lockfile.
  local pid
  pid=$(tr -dc '0-9' < "$f" 2>/dev/null | head -1)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Resolve o caminho do SVG do ícone lógico, ou devolve o nome (lookup de tema).
tray_resolve_icon() {
  local name="$1" candidate
  for candidate in \
    "${FU_ROOT}/icons/${name}.svg" \
    "${FU_ROOT}/assets/icons/${name}.svg" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/${name}.svg" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/full-upgrade/icons/${name}.svg" \
    "/usr/share/icons/hicolor/scalable/apps/${name}.svg"; do
    if [[ -r "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  printf '%s' "$name"
  return 1
}

# Lê um campo do arquivo de estado do tray.
tray_read_state_field() {
  local f="$1" field="$2" line
  [[ -r "$f" && -n "$field" ]] || return 1
  line=$(grep -oE "\"${field}\":\"[^\"]*\"|\"${field}\":-?[0-9]+" "$f" 2>/dev/null | head -1)
  [[ -n "$line" ]] || return 1
  line="${line#*:}"; line="${line#\"}"; line="${line%\"}"
  printf '%s' "$line"
}

# Resolve o binário full-upgrade para uso em .desktop/comandos do yad.
tray_self_bin() {
  if has full-upgrade; then printf 'full-upgrade'; return 0; fi
  [[ -n "${SCRIPT_PATH:-}" ]] && { printf '%s' "$SCRIPT_PATH"; return 0; }
  printf '%s/full-upgrade.sh' "${FU_ROOT:-.}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Camada 3 — coleta de updates, estado, notificações, daemon yad
# ─────────────────────────────────────────────────────────────────────────────

# Coleta contagens de updates (repo + AUR; flatpak best-effort). Faz rede.
# Emite "repo aur flatpak". Não muta o sistema.
tray_gather_updates() {
  local repo=0 aur=0 flatpak=0 out h
  if has checkupdates; then
    out=$(checkupdates 2>/dev/null) && repo=$(tray_count_list <<< "$out")
  fi
  if h=$(detect_aur_helper 2>/dev/null); then
    [[ -n "$h" ]] && { out=$("$h" -Qua 2>/dev/null) && aur=$(tray_count_list <<< "$out") || true; }
  fi
  # Flatpak: sem modo --dry-run não-mutante confiável; mantém 0 por ora
  # (as atualizações flatpak ocorrem no run normal do full-upgrade).
  printf '%s %s %s' "$repo" "$aur" "$flatpak"
}

# Escreve o JSON de estado do tray.
# Uso: tray_write_state <state> <prev> <repo> <aur> <flatpak> <todo> <fail> <reboot> <checked_at>
tray_write_state() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  printf '{"state":%s,"prev_state":%s,"repo":%s,"aur":%s,"flatpak":%s,"todo":%s,"fail":%s,"reboot":%s,"checked_at":%s}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$3" "$4" "$5" "$6" "$7" \
    "$(json_escape "$8")" "$(json_escape "$9")" > "${TRAY_STATE_FILE}.tmp" \
    && mv -f "${TRAY_STATE_FILE}.tmp" "${TRAY_STATE_FILE}" 2>/dev/null
}

# Envia notificação desktop (notify-send). Respeita TRAY_NOTIFICATIONS.
# Uso: tray_notify <urgency> <icon> <title> <body>
tray_notify() {
  (( ${TRAY_NOTIFICATIONS:-1} == 1 )) || return 0
  has notify-send || return 0
  local urgency="$1" icon="$2" title="$3" body="$4"
  notify-send -a full-upgrade -u "$urgency" -i "$icon" "$title" "$body" 2>/dev/null || true
}

# Notifica apenas em transição relevante de estado. Puro-ish (sem rede).
# Uso: _tray_notify_transition <prev> <state> <updates> <todo> <fail> <reboot>
_tray_notify_transition() {
  local prev="$1" state="$2" updates="$3" todo="$4" fail="$5" reboot="$6"
  local icon urgency title body
  icon=$(tray_resolve_icon "$(tray_icon_name_for_state "$state")")
  case "$state" in
    updates)
      urgency=normal
      title="full-upgrade: ${updates} atualização(ões) disponível(is)"
      body="Clique no ícone para executar o full-upgrade." ;;
    attention)
      urgency=normal
      title="full-upgrade: atenção necessária"
      if [[ -n "${reboot//[[:space:]]/}" ]]; then
        body="Reboot pendente: ${reboot}"
      else
        body="${todo} item(ns) do Doctor precisam de ação manual."
      fi ;;
    error)
      urgency=critical
      title="full-upgrade: último run com falha"
      body="${fail} step(s) falharam. Veja o log: ~/.cache/system-upgrade/latest.log" ;;
    idle)
      # Só notifica "tudo ok" se vinha de updates/attention (evita spam).
      [[ "$prev" == "updates" || "$prev" == "attention" ]] || return 0
      urgency=low
      title="full-upgrade: sistema atualizado"
      body="Tudo em dia." ;;
    *) return 0 ;;
  esac
  tray_notify "$urgency" "$icon" "$title" "$body"
}

# Recalcula o estado completo, grava o arquivo e (opcionalmente) notifica.
# Uso: tray_check_now [notify|no_notify]  ->  ecoa o estado (state)
tray_check_now() {
  local do_notify=1
  [[ "${1:-notify}" == "no_notify" ]] && do_notify=0

  local prev=""
  [[ -r "$TRAY_STATE_FILE" ]] && prev=$(tray_read_state_field "$TRAY_STATE_FILE" state 2>/dev/null || true)

  local running=0
  tray_is_full_upgrade_running && running=1

  local todo=0 fail=0 reboot=0
  read -r todo fail reboot <<< "$(tray_last_summary_counts)"

  local reboot_reason=""
  local sumline
  if sumline=$(tray_last_summary_line 2>/dev/null); then
    reboot_reason=$(tray_summary_reboot_reason "$sumline")
  fi

  local repo=0 aur=0 flatpak=0 updates=0
  if (( ! running )); then
    read -r repo aur flatpak <<< "$(tray_gather_updates)"
    updates=$(tray_total_updates "$repo" "$aur" "$flatpak")
  fi

  local state
  state=$(tray_compute_state "$running" "$fail" "$todo" "$updates")

  tray_write_state "$state" "$prev" "$repo" "$aur" "$flatpak" "$todo" "$fail" "$reboot_reason" "$(date -Is)"

  if (( do_notify )) && [[ -n "$prev" && "$prev" != "$state" && "$state" != "running" ]]; then
    _tray_notify_transition "$prev" "$state" "$updates" "$todo" "$fail" "$reboot_reason"
  fi

  printf '%s' "$state"
}

# ── Detecção de terminal e lançamento ──────────────────────────────────────────

# Detecta o terminal emulator a usar. Emite o nome (rc 0) ou nada (rc 1).
tray_detect_terminal() {
  if [[ -n "${TRAY_TERMINAL:-}" ]] && has "$TRAY_TERMINAL"; then
    printf '%s' "$TRAY_TERMINAL"; return 0
  fi
  if has xdg-terminal-exec; then printf 'xdg-terminal-exec'; return 0; fi
  local t
  for t in kitty alacritty foot wezterm ghostty konsole gnome-terminal \
           xfce4-terminal tilix terminator xterm; do
    if has "$t"; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

# Executa um comando num terminal, em background. Uso: tray_run_in_terminal <cmd...>
tray_run_in_terminal() {
  local term
  term=$(tray_detect_terminal) || { echo "Nenhum terminal encontrado. Defina TRAY_TERMINAL no config." >&2; return 1; }
  case "$term" in
    xdg-terminal-exec) xdg-terminal-exec "$@" >/dev/null 2>&1 & ;;
    konsole)           konsole -e "$@" >/dev/null 2>&1 & ;;
    gnome-terminal)    gnome-terminal -- "$@" >/dev/null 2>&1 & ;;
    foot)              foot -- "$@" >/dev/null 2>&1 & ;;
    *)                 "$term" -e "$@" >/dev/null 2>&1 & ;;
  esac
  disown 2>/dev/null || true
}

# Lança o full-upgrade num terminal (left-click / menu "Executar").
tray_launch_full_upgrade() {
  local fu_bin
  fu_bin=$(tray_self_bin)
  tray_run_in_terminal "$fu_bin" "$@"
}

# Abre o último log humano.
tray_view_log() {
  local log="${LATEST_LOG_LINK:-${LOG_DIR}/latest.log}"
  if [[ ! -r "$log" ]]; then
    echo "Log não encontrado: $log" >&2
    return 1
  fi
  if has xdg-open; then
    xdg-open "$log" >/dev/null 2>&1 &
  else
    tray_run_in_terminal "${PAGER:-less}" "$log"
  fi
  disown 2>/dev/null || true
}

# ── Autostart (XDG) ────────────────────────────────────────────────────────────

tray_autostart_file() {
  printf '%s/full-upgrade-tray.desktop' "${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
}

tray_enable_autostart() {
  local self dir
  self=$(tray_self_bin)
  dir="$(dirname "$(tray_autostart_file)")"
  mkdir -p "$dir"
  cat > "$(tray_autostart_file)" <<EOF
[Desktop Entry]
Type=Application
Name=full-upgrade Tray
Name[pt_BR]=Bandeja do full-upgrade
Comment=Systray applet for full-upgrade
Comment[pt_BR]=Ícone de bandeja do full-upgrade
Exec=${self} --tray
Icon=full-upgrade
Terminal=false
Categories=System;Utility;
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF
  echo "Autostart habilitado: $(tray_autostart_file)"
  echo "Inicie agora com: full-upgrade --tray"
}

tray_disable_autostart() {
  if [[ -f "$(tray_autostart_file)" ]]; then
    rm -f "$(tray_autostart_file)"
    echo "Autostart desabilitado."
  else
    echo "Autostart não estava habilitado."
  fi
}

# ── --tray-status: imprime estado atual (do arquivo, sem rede) ─────────────────

tray_print_status() {
  if [[ ! -r "$TRAY_STATE_FILE" ]]; then
    echo "Sem estado ainda. Rode 'full-upgrade --tray-check' para computar." >&2
    return 0
  fi
  local state repo aur todo fail checked reboot
  state=$(tray_read_state_field "$TRAY_STATE_FILE" state 2>/dev/null || echo "?")
  repo=$(tray_read_state_field "$TRAY_STATE_FILE" repo 2>/dev/null || echo 0)
  aur=$(tray_read_state_field "$TRAY_STATE_FILE" aur 2>/dev/null || echo 0)
  todo=$(tray_read_state_field "$TRAY_STATE_FILE" todo 2>/dev/null || echo 0)
  fail=$(tray_read_state_field "$TRAY_STATE_FILE" fail 2>/dev/null || echo 0)
  reboot=$(tray_read_state_field "$TRAY_STATE_FILE" reboot 2>/dev/null || echo "")
  checked=$(tray_read_state_field "$TRAY_STATE_FILE" checked_at 2>/dev/null || echo "?")
  cat <<EOF
Estado      : ${state}
Updates     : ${repo} repo + ${aur} AUR
Doctor todo : ${todo}
Falhas      : ${fail}
Reboot      : ${reboot:-não}
Verificado  : ${checked}
Daemon      : $(tray_daemon_status)
EOF
}

# "rodando (pid N)" | "parado"
tray_daemon_status() {
  local pidf="$TRAY_PID_FILE" pid
  if [[ -r "$pidf" ]]; then
    pid=$(tr -dc '0-9' < "$pidf" 2>/dev/null | head -1)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'rodando (pid %s)' "$pid"; return 0
    fi
  fi
  printf 'parado'
}

# ── --tray-check: computa e imprime o estado (faz rede) ────────────────────────

tray_check_and_print() {
  local state
  state=$(tray_check_now no_notify)
  local repo aur todo fail
  repo=$(tray_read_state_field "$TRAY_STATE_FILE" repo 2>/dev/null || echo 0)
  aur=$(tray_read_state_field "$TRAY_STATE_FILE" aur 2>/dev/null || echo 0)
  todo=$(tray_read_state_field "$TRAY_STATE_FILE" todo 2>/dev/null || echo 0)
  fail=$(tray_read_state_field "$TRAY_STATE_FILE" fail 2>/dev/null || echo 0)
  printf 'Estado: %s | updates: %s repo + %s AUR | doctor todo: %s | falhas: %s\n' \
    "$state" "$repo" "$aur" "$todo" "$fail"
}

# ─────────────────────────────────────────────────────────────────────────────
# Daemon (loop yad --notification --listen)
# ─────────────────────────────────────────────────────────────────────────────

# FD do coproc yad é ${FU_YAD[1]}; PID é FU_YAD_PID. Definidos por `coproc`.
FU_YAD_PID=""
declare -a FU_YAD=()

_tray_yad_send() {
  [[ -n "${FU_YAD[1]:-}" ]] || return 0
  printf '%s\n' "$1" 1>&"${FU_YAD[1]}" || true
}

# Constrói a string de menu do yad: name[!action] separados por '|'.
tray_build_menu() {
  local self="$1" pid="$2"
  printf '%s' \
    "Executar full-upgrade!${self} --tray-launch" \
    "|Doctor (auditorias)!${self} --tray-launch --mode doctor" \
    "|Verificar agora!kill -USR1 ${pid}" \
    "|Ver último log!${self} --tray-view-log" \
    "|" \
    "|Sair!kill -USR2 ${pid}"
}

_tray_yad_apply() {
  # $1=estado. Atualiza ícone+tooltip do yad a partir do arquivo de estado.
  local state="$1"
  local icon tooltip updates todo fail reboot_reason
  icon=$(tray_resolve_icon "$(tray_icon_name_for_state "$state")")
  reboot_reason=$(tray_read_state_field "$TRAY_STATE_FILE" reboot 2>/dev/null || true)
  updates=$(tray_read_state_field "$TRAY_STATE_FILE" repo 2>/dev/null || echo 0)
  local aur
  aur=$(tray_read_state_field "$TRAY_STATE_FILE" aur 2>/dev/null || echo 0)
  updates=$(( updates + aur ))
  todo=$(tray_read_state_field "$TRAY_STATE_FILE" todo 2>/dev/null || echo 0)
  fail=$(tray_read_state_field "$TRAY_STATE_FILE" fail 2>/dev/null || echo 0)
  tooltip=$(tray_tooltip_for_state "$state" "$updates" "$todo" "$fail" "$reboot_reason")
  _tray_yad_send "icon:${icon}"
  _tray_yad_send "tooltip:${tooltip}"
}

_tray_cleanup() {
  if [[ -n "${FU_YAD_PID:-}" ]] && kill -0 "$FU_YAD_PID" 2>/dev/null; then
    kill "$FU_YAD_PID" 2>/dev/null || true
    wait "$FU_YAD_PID" 2>/dev/null || true
  fi
  rm -f "$TRAY_PID_FILE" 2>/dev/null || true
}

# Ponto de entrada do daemon (--tray). Bloqueante.
tray_main() {
  if ! has yad; then
    echo "full-upgrade --tray requer 'yad'. Instale com: sudo pacman -S yad" >&2
    exit 1
  fi

  # Instância única.
  if [[ -r "$TRAY_PID_FILE" ]]; then
    local old
    old=$(tr -dc '0-9' < "$TRAY_PID_FILE" 2>/dev/null | head -1)
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      echo "full-upgrade tray já está em execução (pid ${old})." >&2
      exit 0
    fi
  fi
  printf '%s\n' "$$" > "$TRAY_PID_FILE"
  local TRAY_DAEMON_PID=$$
  export TRAY_DAEMON_PID

  local self interval
  self=$(tray_self_bin)
  interval=$(( ${TRAY_CHECK_INTERVAL_M:-30} * 60 ))
  (( interval < 60 )) && interval=60

  trap '_tray_cleanup' EXIT
  trap 'exit 0' INT TERM
  trap '_tray_force=1' USR1
  trap '_tray_quit=1' USR2

  local _tray_force=0 _tray_quit=0

  # Inicia yad (notification, listen). coproc abre FDs de comunicação.
  local initial_icon initial_menu
  initial_icon=$(tray_resolve_icon "$(tray_icon_name_for_state idle)")
  initial_menu=$(tray_build_menu "$self" "$TRAY_DAEMON_PID")
  # shellcheck disable=SC2034
  coproc FU_YAD { yad --notification --listen --no-middle \
      --image="$initial_icon" \
      --tooltip="full-upgrade" \
      --command="${self} --tray-launch" \
      --menu="$initial_menu" >/dev/null 2>&1; } 2>/dev/null

  # Primeira verificação + atualização do ícone.
  local cur_state
  cur_state=$(tray_check_now no_notify)
  _tray_yad_apply "$cur_state"

  # Loop principal: verifica, espera o intervalo (em incrementos reativos), repete.
  while kill -0 "${FU_YAD_PID:-0}" 2>/dev/null && (( _tray_quit == 0 )); do
    _tray_force=0
    cur_state=$(tray_check_now)
    _tray_yad_apply "$cur_state"

    local waited=0 prev_running=-1 r
    while (( waited < interval )) && (( _tray_force == 0 )) && (( _tray_quit == 0 )) \
          && kill -0 "${FU_YAD_PID:-0}" 2>/dev/null; do
      sleep 5
      waited=$(( waited + 5 ))
      tray_is_full_upgrade_running && r=1 || r=0
      if (( prev_running >= 0 && r != prev_running )); then break; fi
      prev_running=$r
    done
  done

  _tray_yad_send "quit" 2>/dev/null || true
  exit 0
}
