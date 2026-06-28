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

# Texto curto do "badge" (rótulo ao lado do ícone no painel, via AppIndicator
# set_label). Puro. Mostra o número de itens acionáveis por estado:
#   updates -> total de atualizações | attention -> nº de todos (ou "!" se só reboot)
#   error -> nº de falhas | running/idle -> vazio (sem badge).
# Uso: tray_badge_text <state> <updates> <todo> <fail>
tray_badge_text() {
  local state="$1" updates="$2" todo="$3" fail="$4"
  [[ "$updates" =~ ^[0-9]+$ ]] || updates=0
  [[ "$todo" =~ ^[0-9]+$ ]] || todo=0
  [[ "$fail" =~ ^[0-9]+$ ]] || fail=0
  case "$state" in
    updates)   (( updates > 0 )) && printf '%s' "$updates" ;;
    attention) if (( todo > 0 )); then printf '%s' "$todo"; else printf '!'; fi ;;
    error)     (( fail > 0 )) && printf '%s' "$fail" ;;
    *)         printf '' ;;
  esac
}

# Tempo relativo curto (PT-BR) a partir de um timestamp ISO-8601. Determinístico
# quando o "agora" (epoch) é passado em $2; senão usa a hora atual. rc 0 sempre;
# string vazia se o timestamp não puder ser parseado.
# Uso: tray_relative_time <iso8601> [now_epoch]  ->  "agora" | "há N min" | "há N h" | "há N d"
tray_relative_time() {
  local iso="$1" now="${2:-}" ts delta
  [[ -n "${iso//[[:space:]]/}" ]] || { printf ''; return 0; }
  ts=$(date -d "$iso" +%s 2>/dev/null) || { printf ''; return 0; }
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf ''; return 0; }
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date +%s)
  delta=$(( now - ts ))
  (( delta < 0 )) && delta=0
  if   (( delta < 60 ));    then printf 'agora'
  elif (( delta < 3600 ));  then printf 'há %d min' "$(( delta / 60 ))"
  elif (( delta < 86400 )); then printf 'há %d h' "$(( delta / 3600 ))"
  else                           printf 'há %d d' "$(( delta / 86400 ))"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Camada 2 — I/O leve (sem yad)
# ─────────────────────────────────────────────────────────────────────────────

# JSONL completo mais recente de um run REAL. Ignora dry-runs e o run atual
# enquanto ele ainda não escreveu summary, para o tray não "esquecer" pendências
# do último Doctor/upgrade durante a execução de outro comando.
tray_latest_completed_real_jsonl() {
  local f
  while IFS= read -r f; do
    [[ -r "$f" ]] || continue
    grep -m1 '"event":"run_start"' "$f" 2>/dev/null | grep -q '"dry_run":false' || continue
    grep -q '"event":"summary"' "$f" 2>/dev/null || continue
    printf '%s\n' "$f"
    return 0
  done < <(
    find "$LOG_DIR" -maxdepth 1 -name 'full-upgrade-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | cut -d' ' -f2-
  )
  return 1
}

# Última linha "summary" do JSONL real completo mais recente (rc 1 se indisponível).
tray_last_summary_line() {
  local jsonl
  jsonl=$(tray_latest_completed_real_jsonl 2>/dev/null) || return 1
  grep '"event":"summary"' "$jsonl" 2>/dev/null | tail -1
}

# "todo fail reboot" do último run real (0 0 0 se não houver).
tray_last_summary_counts() {
  local line
  line=$(tray_last_summary_line 2>/dev/null) || { printf '0 0 0'; return 0; }
  tray_summary_counts "$line"
}

# Itens Doctor pendentes (warn/todo/fail) do último run real completo.
# Formato por linha: "status: Nome do step — motivo".
tray_last_doctor_pending_items() {
  local jsonl line step status reason
  jsonl=$(tray_latest_completed_real_jsonl 2>/dev/null) || return 0
  while IFS= read -r line; do
    [[ "$line" == *'"event":"step"'* && "$line" == *'"category":"doctor"'* ]] || continue
    status=$(tray_extract_json_field "$line" status 2>/dev/null || true)
    case "$status" in warn|todo|fail) ;; *) continue ;; esac
    step=$(tray_extract_json_field "$line" step 2>/dev/null || true)
    reason=$(tray_extract_json_field "$line" reason 2>/dev/null || true)
    [[ -n "$step" ]] || continue
    if [[ -n "${reason//[[:space:]]/}" ]]; then
      printf '%s: %s — %s\n' "$status" "$step" "$reason"
    else
      printf '%s: %s\n' "$status" "$step"
    fi
  done < "$jsonl"
}

# Array JSON de strings a partir de stdin (linhas vazias são ignoradas).
tray_json_array_from_lines() {
  local line sep=""
  printf '['
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    printf '%s%s' "$sep" "$(json_escape "$line")"
    sep=','
  done
  printf ']'
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

# Coleta listas de updates (repo + AUR; flatpak best-effort). Faz rede.
# Uso: tray_gather_updates_detail <repo_file> <aur_file> <flatpak_file>
# Emite "repo aur flatpak". Não muta o sistema.
tray_gather_updates_detail() {
  local repo_file="$1" aur_file="$2" flatpak_file="$3" repo=0 aur=0 flatpak=0 h
  : > "$repo_file"
  : > "$aur_file"
  : > "$flatpak_file"

  if has checkupdates; then
    checkupdates > "$repo_file" 2>/dev/null || true
    repo=$(tray_count_list < "$repo_file")
  fi
  if h=$(detect_aur_helper 2>/dev/null); then
    [[ -n "$h" ]] && "$h" -Qua > "$aur_file" 2>/dev/null || true
    aur=$(tray_count_list < "$aur_file")
  fi
  # Flatpak: sem modo --dry-run não-mutante confiável; mantém lista vazia por ora
  # (as atualizações flatpak ocorrem no run normal do full-upgrade).
  flatpak=$(tray_count_list < "$flatpak_file")
  printf '%s %s %s' "$repo" "$aur" "$flatpak"
}

# Compatibilidade para chamadores/testes antigos: só devolve contagens.
tray_gather_updates() {
  local repo_file aur_file flatpak_file
  repo_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-repo.$$" )
  aur_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-aur.$$" )
  flatpak_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-flatpak.$$" )
  tray_gather_updates_detail "$repo_file" "$aur_file" "$flatpak_file"
  rm -f "$repo_file" "$aur_file" "$flatpak_file" 2>/dev/null || true
}

# Escreve o JSON de estado do tray.
# Uso: tray_write_state <state> <prev> <repo> <aur> <flatpak> <todo> <fail> <reboot> <checked_at> <last_run_at> <log_file> <jsonl_file> <repo_json> <aur_json> <doctor_json>
tray_write_state() {
  mkdir -p "${LOG_DIR}" 2>/dev/null || true
  printf '{"state":%s,"prev_state":%s,"repo":%s,"aur":%s,"flatpak":%s,"todo":%s,"fail":%s,"reboot":%s,"checked_at":%s,"last_run_at":%s,"log_file":%s,"jsonl_file":%s,"repo_updates":%s,"aur_updates":%s,"doctor_pending":%s}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$3" "$4" "$5" "$6" "$7" \
    "$(json_escape "$8")" "$(json_escape "$9")" "$(json_escape "${10}")" \
    "$(json_escape "${11}")" "$(json_escape "${12}")" "${13:-[]}" "${14:-[]}" "${15:-[]}" > "${TRAY_STATE_FILE}.tmp" \
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

  local reboot_reason="" last_run_at="" last_log="" last_jsonl=""
  local sumline
  if sumline=$(tray_last_summary_line 2>/dev/null); then
    reboot_reason=$(tray_summary_reboot_reason "$sumline")
    last_run_at=$(tray_extract_json_field "$sumline" timestamp 2>/dev/null || true)
    last_log=$(tray_extract_json_field "$sumline" log_file 2>/dev/null || true)
    last_jsonl=$(tray_extract_json_field "$sumline" jsonl_file 2>/dev/null || true)
  fi

  local repo=0 aur=0 flatpak=0 updates=0
  local repo_file aur_file flatpak_file doctor_file repo_json='[]' aur_json='[]' doctor_json='[]'
  repo_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-repo.$$" )
  aur_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-aur.$$" )
  flatpak_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-flatpak.$$" )
  doctor_file=$(mktemp 2>/dev/null || printf '%s' "${LOG_DIR}/tray-doctor.$$" )
  if (( ! running )); then
    read -r repo aur flatpak <<< "$(tray_gather_updates_detail "$repo_file" "$aur_file" "$flatpak_file")"
    updates=$(tray_total_updates "$repo" "$aur" "$flatpak")
  fi
  tray_last_doctor_pending_items > "$doctor_file"
  todo=$(tray_count_list < "$doctor_file")
  repo_json=$(tray_json_array_from_lines < "$repo_file")
  aur_json=$(tray_json_array_from_lines < "$aur_file")
  doctor_json=$(tray_json_array_from_lines < "$doctor_file")
  rm -f "$repo_file" "$aur_file" "$flatpak_file" "$doctor_file" 2>/dev/null || true

  local state
  state=$(tray_compute_state "$running" "$fail" "$todo" "$updates")

  tray_write_state "$state" "$prev" "$repo" "$aur" "$flatpak" "$todo" "$fail" "$reboot_reason" \
    "$(date -Is)" "$last_run_at" "$last_log" "$last_jsonl" "$repo_json" "$aur_json" "$doctor_json"

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
  local state repo aur todo fail checked reboot last_run log_file
  state=$(tray_read_state_field "$TRAY_STATE_FILE" state 2>/dev/null || echo "?")
  repo=$(tray_read_state_field "$TRAY_STATE_FILE" repo 2>/dev/null || echo 0)
  aur=$(tray_read_state_field "$TRAY_STATE_FILE" aur 2>/dev/null || echo 0)
  todo=$(tray_read_state_field "$TRAY_STATE_FILE" todo 2>/dev/null || echo 0)
  fail=$(tray_read_state_field "$TRAY_STATE_FILE" fail 2>/dev/null || echo 0)
  reboot=$(tray_read_state_field "$TRAY_STATE_FILE" reboot 2>/dev/null || echo "")
  checked=$(tray_read_state_field "$TRAY_STATE_FILE" checked_at 2>/dev/null || echo "?")
  last_run=$(tray_read_state_field "$TRAY_STATE_FILE" last_run_at 2>/dev/null || echo "")
  log_file=$(tray_read_state_field "$TRAY_STATE_FILE" log_file 2>/dev/null || echo "")
  local rel; rel=$(tray_relative_time "$checked")
  [[ -n "$rel" ]] && checked="${checked} (${rel})"
  local last_rel; last_rel=$(tray_relative_time "$last_run")
  [[ -n "$last_rel" ]] && last_run="${last_run} (${last_rel})"
  cat <<EOF
Estado      : ${state}
Updates     : ${repo} repo + ${aur} AUR
Doctor todo : ${todo}
Falhas      : ${fail}
Reboot      : ${reboot:-não}
Verificado  : ${checked}
Último run  : ${last_run:-desconhecido}
Log fonte   : ${log_file:-desconhecido}
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
# Daemon (AppIndicator em Wayland; yad em X11)
# ─────────────────────────────────────────────────────────────────────────────

tray_python_bin() {
  if has python3; then printf 'python3'; return 0; fi
  if has python; then printf 'python'; return 0; fi
  return 1
}

tray_wayland_session() {
  [[ "${XDG_SESSION_TYPE:-}" == "wayland" || -n "${WAYLAND_DISPLAY:-}" ]]
}

tray_appindicator_available() {
  local py
  py=$(tray_python_bin) || return 1
  "$py" - <<'PY' >/dev/null 2>&1
import gi
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3  # noqa: F401
except Exception:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3  # noqa: F401
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: F401
PY
}

tray_appindicator_main() {
  local self="$1" interval="$2" py
  py=$(tray_python_bin) || return 1
  FU_TRAY_SELF="$self" \
  FU_TRAY_INTERVAL="$interval" \
  FU_TRAY_STATE_FILE="$TRAY_STATE_FILE" \
  FU_TRAY_PID_FILE="$TRAY_PID_FILE" \
  FU_TRAY_ROOT="${FU_ROOT:-}" \
  FU_TRAY_LOG_DIR="${LOG_DIR:-}" \
  FU_TRAY_BADGE="${TRAY_BADGE:-1}" \
  FU_TRAY_NOTIFICATIONS="${TRAY_NOTIFICATIONS:-1}" \
    exec "$py" - <<'PY'
import atexit
import datetime
import json
import os
import signal
import shutil
import subprocess
import threading

import gi

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except Exception:
    gi.require_version("AppIndicator3", "0.1")
    from gi.repository import AppIndicator3 as AppIndicator

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk


SELF = os.environ.get("FU_TRAY_SELF", "full-upgrade")
STATE_FILE = os.environ.get("FU_TRAY_STATE_FILE", "")
PID_FILE = os.environ.get("FU_TRAY_PID_FILE", "")
FU_ROOT = os.environ.get("FU_TRAY_ROOT", "")
LOG_DIR = os.environ.get("FU_TRAY_LOG_DIR", "")
BADGE_ENABLED = os.environ.get("FU_TRAY_BADGE", "1") == "1"
NOTIFICATIONS_ENABLED = os.environ.get("FU_TRAY_NOTIFICATIONS", "1") == "1"
INTERVAL = max(int(os.environ.get("FU_TRAY_INTERVAL", "1800") or "1800"), 60)

# Glifo + rótulo curto por estado, usado no cabeçalho do menu.
STATE_GLYPH = {
    "running": "⟳",    # ⟳
    "error": "✕",      # ✕
    "attention": "⚠",  # ⚠
    "updates": "↑",    # ↑
    "idle": "●",       # ●
}


def write_pid():
    if PID_FILE:
        os.makedirs(os.path.dirname(PID_FILE), exist_ok=True)
        with open(PID_FILE, "w", encoding="utf-8") as f:
            f.write(f"{os.getpid()}\n")


def cleanup():
    if PID_FILE:
        try:
            with open(PID_FILE, "r", encoding="utf-8") as f:
                pid = f.read().strip()
            if pid == str(os.getpid()):
                os.unlink(PID_FILE)
        except OSError:
            pass


def icon_name_for_state(state):
    return {
        "running": "full-upgrade-tray-running",
        "error": "full-upgrade-tray-error",
        "attention": "full-upgrade-tray-attention",
        "updates": "full-upgrade-tray-updates",
    }.get(state, "full-upgrade-tray-idle")


def resolve_icon_name(name):
    home = os.path.expanduser("~")
    xdg_data = os.environ.get("XDG_DATA_HOME", os.path.join(home, ".local/share"))
    candidates = [
        os.path.join(FU_ROOT, "icons", f"{name}.svg"),
        os.path.join(FU_ROOT, "assets/icons", f"{name}.svg"),
        os.path.join(xdg_data, "icons/hicolor/scalable/apps", f"{name}.svg"),
        os.path.join(xdg_data, "full-upgrade/icons", f"{name}.svg"),
        os.path.join("/usr/share/icons/hicolor/scalable/apps", f"{name}.svg"),
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                indicator.set_icon_theme_path(os.path.dirname(path))
            except Exception:
                pass
            return name
    return name


def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {
            "state": "idle",
            "repo": 0,
            "aur": 0,
            "todo": 0,
            "fail": 0,
            "reboot": "",
            "repo_updates": [],
            "aur_updates": [],
            "doctor_pending": [],
        }


def _ints(data):
    return (
        str(data.get("state") or "idle"),
        int(data.get("repo") or 0),
        int(data.get("aur") or 0),
        int(data.get("todo") or 0),
        int(data.get("fail") or 0),
        str(data.get("reboot") or "").strip(),
    )


def tooltip_for_state(data):
    state, repo, aur, todo, fail, reboot = _ints(data)
    updates = repo + aur
    if state == "running":
        return "full-upgrade: executando..."
    if state == "error":
        return f"full-upgrade: último run com {fail} falha(s)"
    parts = []
    if reboot:
        parts.append("Reboot pendente")
    if todo > 0:
        parts.append(f"{todo} doctor todo")
    if updates > 0:
        parts.append(f"{updates} atualização(ões)")
    return "full-upgrade: " + ("; ".join(parts) if parts else "sistema atualizado")


def badge_text(data):
    """Rótulo curto ao lado do ícone no painel (set_label)."""
    if not BADGE_ENABLED:
        return ""
    state, repo, aur, todo, fail, _reboot = _ints(data)
    updates = repo + aur
    if state == "updates" and updates > 0:
        return str(updates)
    if state == "attention":
        return str(todo) if todo > 0 else "!"
    if state == "error" and fail > 0:
        return str(fail)
    return ""


def relative_time(iso):
    if not iso:
        return ""
    try:
        then = datetime.datetime.fromisoformat(iso)
    except Exception:
        return ""
    now = datetime.datetime.now(then.tzinfo) if then.tzinfo else datetime.datetime.now()
    delta = int((now - then).total_seconds())
    if delta < 0:
        delta = 0
    if delta < 60:
        return "agora"
    if delta < 3600:
        return f"há {delta // 60} min"
    if delta < 86400:
        return f"há {delta // 3600} h"
    return f"há {delta // 86400} d"


def as_list(data, key):
    value = data.get(key) or []
    if isinstance(value, list):
        return [str(v) for v in value if str(v).strip()]
    return []


def desktop_notify(title, body="", urgency="normal"):
    if not NOTIFICATIONS_ENABLED:
        return
    notify = shutil.which("notify-send")
    if not notify:
        return
    args = [notify, "-a", "full-upgrade", "-u", urgency, title]
    if body:
        args.append(body)
    subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def state_headline(data):
    state, repo, aur, todo, fail, reboot = _ints(data)
    updates = repo + aur
    glyph = STATE_GLYPH.get(state, STATE_GLYPH["idle"])
    if state == "running":
        return f"{glyph}  Executando full-upgrade…"
    if state == "error":
        return f"{glyph}  Último run falhou ({fail})"
    if state == "updates":
        return f"{glyph}  {updates} atualização(ões) disponível(is)"
    if state == "attention":
        if todo > 0:
            return f"{glyph}  Atenção: {todo} item(ns) do Doctor"
        return f"{glyph}  Atenção necessária"
    return f"{glyph}  Sistema atualizado"


def launch_and_refresh(args):
    launch(args)
    desktop_notify("full-upgrade iniciado", "O status do tray será atualizado durante e após a execução.", "normal")
    GLib.timeout_add_seconds(2, refresh, True)
    schedule_post_launch_refresh()


def schedule_post_launch_refresh():
    # Após iniciar pelo menu, o intervalo normal do tray pode ser longo demais
    # para refletir a transição running → idle/attention/error. Faz polling curto
    # até observar o run terminar, com limite defensivo de ~30 min.
    tracker = {"seen_running": False, "ticks_left": 180}

    def tick():
        data = load_state()
        if data.get("state") == "running":
            tracker["seen_running"] = True
        refresh(True)
        tracker["ticks_left"] -= 1
        if tracker["seen_running"] and data.get("state") != "running":
            return False
        return tracker["ticks_left"] > 0

    GLib.timeout_add_seconds(10, tick)


# ── Indicador + menu ────────────────────────────────────────────────────────────
checking = False
running_now = False


def apply_state(data):
    global running_now
    state, repo, aur, todo, fail, reboot = _ints(data)
    running_now = state == "running"
    icon = resolve_icon_name(icon_name_for_state(state))
    tooltip = tooltip_for_state(data)

    # Ícone (com fallback) + título (lido pelos hosts SNI como tooltip).
    try:
        indicator.set_icon_full(icon, tooltip)
    except Exception:
        indicator.set_icon(icon)
    try:
        indicator.set_title(tooltip)
    except Exception:
        pass

    # Badge: número de itens acionáveis ao lado do ícone no painel.
    try:
        indicator.set_label(badge_text(data), "00")
    except Exception:
        pass

    # Estados que pedem destaque viram ATTENTION (hosts realçam/piscam).
    try:
        if state in ("error", "attention"):
            indicator.set_attention_icon_full(icon, tooltip)
            indicator.set_status(AppIndicator.IndicatorStatus.ATTENTION)
        else:
            indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
    except Exception:
        pass

    rebuild_menu(data)
    return False


def finish_refresh(data, user_initiated=False):
    global checking
    checking = False
    apply_state(data)
    if user_initiated:
        state, repo, aur, todo, fail, _reboot = _ints(data)
        updates = repo + aur
        if state == "running":
            body = "full-upgrade está em execução. Mantendo o estado atual."
        elif fail > 0:
            body = f"Último run com {fail} falha(s)."
        elif todo > 0:
            body = f"{todo} pendência(s) do Doctor."
        elif updates > 0:
            body = f"{updates} atualização(ões): {repo} repo, {aur} AUR."
        else:
            body = "Nenhuma atualização ou pendência detectada."
        desktop_notify("Verificação concluída", body, "normal")
    return False


def refresh(run_probe=True, user_initiated=False):
    global checking
    if checking:
        if user_initiated:
            desktop_notify("Verificação já em andamento", "Aguarde a conclusão da checagem atual.", "low")
        return False
    checking = True
    if user_initiated:
        desktop_notify("Verificando agora…", "Consultando atualizações e o último log real completo.", "low")
    rebuild_menu(load_state())

    def worker():
        if run_probe:
            subprocess.run(
                [SELF, "--tray-check"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=300,
                check=False,
            )
        data = load_state()
        GLib.idle_add(finish_refresh, data, user_initiated)

    threading.Thread(target=worker, daemon=True).start()
    return False


def every_interval():
    refresh(True)
    return True


def launch(args):
    subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def open_path(path):
    if path:
        launch(["xdg-open", path])


def info_item(label):
    """Item de menu informativo (não-clicável)."""
    item = Gtk.MenuItem(label=label)
    item.set_sensitive(False)
    item.show()
    return item


def menu_item(label, callback, enabled=True):
    item = Gtk.MenuItem(label=label)
    item.set_sensitive(enabled)
    if enabled:
        item.connect("activate", lambda *_: callback())
    item.show()
    return item


def submenu_item(label, entries, empty_label="Nenhum item", limit=30):
    item = Gtk.MenuItem(label=label)
    submenu = Gtk.Menu()
    shown = entries[:limit]
    if shown:
        for entry in shown:
            text = entry if len(entry) <= 96 else entry[:93] + "…"
            submenu.append(info_item("  " + text))
        if len(entries) > limit:
            submenu.append(info_item(f"  … mais {len(entries) - limit} item(ns)"))
    else:
        submenu.append(info_item("  " + empty_label))
    item.set_submenu(submenu)
    item.show_all()
    return item


def separator():
    sep = Gtk.SeparatorMenuItem()
    sep.show()
    return sep


def rebuild_menu(data):
    """Reconstrói o menu a cada refresh para refletir o estado atual."""
    state, repo, aur, todo, fail, reboot = _ints(data)
    updates = repo + aur
    can_run = not running_now
    repo_updates = as_list(data, "repo_updates")
    aur_updates = as_list(data, "aur_updates")
    doctor_pending = as_list(data, "doctor_pending")

    menu = Gtk.Menu()

    # Cabeçalho informativo (estado + detalhamento).
    menu.append(info_item(state_headline(data)))
    if updates > 0:
        menu.append(info_item(f"     {repo} repo · {aur} AUR"))
    if todo > 0:
        menu.append(info_item(f"     {todo} item(ns) do Doctor"))
    if reboot:
        menu.append(info_item(f"     Reboot: {reboot[:48]}"))
    rel = relative_time(str(data.get("checked_at") or ""))
    if rel:
        menu.append(info_item(f"     Última verificação: {rel}"))
    run_rel = relative_time(str(data.get("last_run_at") or ""))
    if run_rel:
        menu.append(info_item(f"     Último run: {run_rel}"))
    if data.get("log_file"):
        menu.append(info_item("     Fonte: último run real completo"))
    if repo_updates:
        menu.append(submenu_item(f"     Pacotes repo pendentes ({len(repo_updates)})", repo_updates))
    if aur_updates:
        menu.append(submenu_item(f"     Pacotes AUR pendentes ({len(aur_updates)})", aur_updates))
    if doctor_pending:
        menu.append(submenu_item(f"     Pendências do Doctor ({len(doctor_pending)})", doctor_pending))
    menu.append(separator())

    # Ações de execução (desabilitadas enquanto um run está em andamento).
    menu.append(menu_item(
        "Atualizar sistema completo" if can_run else "full-upgrade em execução…",
        lambda: launch_and_refresh([SELF, "--tray-launch"]), enabled=can_run))
    menu.append(menu_item(
        "Atualizar pacotes",
        lambda: launch_and_refresh([SELF, "--tray-launch", "--mode", "update"]),
        enabled=can_run))
    menu.append(menu_item(
        "Executar Doctor",
        lambda: launch_and_refresh([SELF, "--tray-launch", "--mode", "doctor"]),
        enabled=can_run))
    menu.append(menu_item(
        "Executar reparos",
        lambda: launch_and_refresh([SELF, "--tray-launch", "--mode", "repair"]),
        enabled=can_run))
    menu.append(separator())

    # Utilitários.
    if checking:
        menu.append(menu_item("Verificando agora…", lambda: None, enabled=False))
    else:
        suffix = f" (última: {rel})" if rel else ""
        menu.append(menu_item(f"Verificar agora{suffix}", lambda: refresh(True, True)))
    menu.append(menu_item("Abrir último log", lambda: launch([SELF, "--tray-view-log"])))
    if LOG_DIR:
        menu.append(menu_item("Abrir pasta de logs", lambda: open_path(LOG_DIR)))
    menu.append(separator())
    menu.append(menu_item("Sair do tray", Gtk.main_quit))

    menu.show_all()
    indicator.set_menu(menu)


def handle_usr1(_signum, _frame):
    GLib.idle_add(refresh, True, True)


def handle_usr2(_signum, _frame):
    GLib.idle_add(Gtk.main_quit)


write_pid()
atexit.register(cleanup)
signal.signal(signal.SIGUSR1, handle_usr1)
signal.signal(signal.SIGUSR2, handle_usr2)

indicator = AppIndicator.Indicator.new(
    "full-upgrade",
    "full-upgrade-tray-idle",
    AppIndicator.IndicatorCategory.SYSTEM_SERVICES,
)
indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
indicator.set_title("full-upgrade")
# Scroll sobre o ícone => verifica agora (atalho sem abrir o menu).
try:
    indicator.connect("scroll-event", lambda *_: refresh(True, True))
except Exception:
    pass
# Menu inicial a partir do estado em cache (rebuild_menu já faz set_menu).
rebuild_menu(load_state())

refresh(True)
GLib.timeout_add_seconds(INTERVAL, every_interval)
Gtk.main()
PY
}

# FD do coproc yad é ${FU_YAD[1]}; PID é FU_YAD_PID. Definidos por `coproc`.
FU_YAD_PID=""
declare -a FU_YAD=()

_tray_yad_send() {
  [[ -n "${FU_YAD[1]:-}" ]] || return 0
  printf '%s\n' "$1" 1>&"${FU_YAD[1]}" || true
}

tray_yad_pid_alive() {
  [[ -n "${FU_YAD_PID:-}" ]] && kill -0 "$FU_YAD_PID" 2>/dev/null
}

# Constrói a string de menu do yad: name[!action] separados por '|'.
tray_build_menu() {
  local self="$1" pid="$2"
  printf '%s' \
    "Atualizar sistema completo!${self} --tray-launch" \
    "|Atualizar pacotes!${self} --tray-launch --mode update" \
    "|Executar Doctor!${self} --tray-launch --mode doctor" \
    "|Executar reparos!${self} --tray-launch --mode repair" \
    "|Verificar agora!kill -USR1 ${pid}" \
    "|Abrir último log!${self} --tray-view-log" \
    "|" \
    "|Sair do tray!kill -USR2 ${pid}"
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

# Reinicia o daemon: encerra a instância antiga (graceful via USR2) e sobe uma
# nova no lugar. Útil após atualizar o full-upgrade para carregar novo
# comportamento/ícones. Bloqueante (a nova instância assume o primeiro plano).
tray_restart() {
  local old i
  if [[ -r "$TRAY_PID_FILE" ]]; then
    old=$(tr -dc '0-9' < "$TRAY_PID_FILE" 2>/dev/null | head -1)
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      echo "Encerrando applet antigo (pid ${old})…"
      kill -USR2 "$old" 2>/dev/null || kill "$old" 2>/dev/null || true
      for i in 1 2 3 4 5 6; do kill -0 "$old" 2>/dev/null || break; sleep 0.5; done
      kill -0 "$old" 2>/dev/null && kill -9 "$old" 2>/dev/null || true
    fi
    rm -f "$TRAY_PID_FILE" 2>/dev/null || true
  fi
  echo "Iniciando applet…"
  tray_main
}

# Ponto de entrada do daemon (--tray). Bloqueante.
tray_main() {
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

  if tray_wayland_session; then
    if tray_appindicator_available; then
      tray_appindicator_main "$self" "$interval"
    fi
  fi

  if ! has yad; then
    echo "full-upgrade --tray requer 'yad' ou AppIndicator Python/GI." >&2
    exit 1
  fi

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

  if ! tray_yad_pid_alive; then
    echo "full-upgrade --tray: yad não iniciou o modo notification." >&2
    exit 1
  fi

  # Primeira verificação + atualização do ícone.
  local cur_state
  cur_state=$(tray_check_now no_notify)
  _tray_yad_apply "$cur_state"

  # Loop principal: verifica, espera o intervalo (em incrementos reativos), repete.
  while tray_yad_pid_alive && (( _tray_quit == 0 )); do
    _tray_force=0
    cur_state=$(tray_check_now)
    _tray_yad_apply "$cur_state"

    local waited=0 prev_running=-1 r
    while (( waited < interval )) && (( _tray_force == 0 )) && (( _tray_quit == 0 )) \
          && tray_yad_pid_alive; do
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
