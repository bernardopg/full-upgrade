#!/usr/bin/env bash
# lib/core.sh — helpers, logging, framework de steps (run_step)
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module setadas/usadas entre arquivos

has() {
  command -v "$1" >/dev/null 2>&1
}

# Remove sequências de escape ANSI (cores/estilo) de stdin.
# Usado para manter o arquivo de log legível mesmo quando comandos externos
# (ex.: fwupdmgr) emitem escapes crus.
_strip_ansi() {
  sed -E 's/\x1b\[[0-9;]*[mGKHfABCD]//g'
}

# Grava conteúdo SOMENTE no arquivo de log (não no terminal), removendo ANSI.
# Use para gravar a saída crua de comandos externos no log de auditoria, no
# lugar de 'printf ... >> "$LOG_FILE"', que preservaria escapes de cor.
log_raw() {
  printf '%b\n' "$*" | _strip_ansi >> "$LOG_FILE"
}

add_skip_step() {
  local name="$1"
  if [[ -z "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]]; then
    FULL_UPGRADE_SKIP="$name"
  else
    FULL_UPGRADE_SKIP="${FULL_UPGRADE_SKIP},${name}"
  fi
}

skip_step_count() {
  local item
  local count=0
  local -a _skip_count_items=()
  [[ -z "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]] && { printf '0'; return 0; }
  IFS=',' read -ra _skip_count_items <<< "$FULL_UPGRADE_SKIP"
  for item in "${_skip_count_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && ((count++))
  done
  printf '%d' "$count"
}

log() {
  if (( QUIET )); then
    printf '%b\n' "$*" | _strip_ansi >> "$LOG_FILE"
  else
    printf '%b\n' "$*"                          # terminal: mantém cores
    printf '%b\n' "$*" | _strip_ansi >> "$LOG_FILE"   # arquivo: sem ANSI
  fi
}

# Sempre imprime no terminal (mesmo em --quiet): use para resumo e erros críticos.
log_always() {
  printf '%b\n' "$*"                            # terminal: mantém cores
  printf '%b\n' "$*" | _strip_ansi >> "$LOG_FILE"     # arquivo: sem ANSI
}

run_logged() {
  if (( QUIET )); then
    "$@" > >(_strip_ansi >> "$LOG_FILE") 2>&1
  else
    # Terminal mantém cores; arquivo recebe versão sem ANSI.
    "$@" 2>&1 | tee >(_strip_ansi >> "$LOG_FILE")
  fi
  return ${PIPESTATUS[0]}
}

# Executa comando de rede; se falhar por DNS/conectividade retorna RC_WARN.
# Uso: run_network_cmd curl -sf https://example.com
run_network_cmd() {
  local _out _rc
  _out="$("$@" 2>&1)"
  _rc=$?
  printf '%s\n' "$_out"
  printf '%s\n' "$_out" | _strip_ansi >> "$LOG_FILE"
  if (( _rc != 0 )); then
    if printf '%s\n' "$_out" | grep -qiE \
        'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'; then
      log "  Falha de rede transitória detectada (DNS/conectividade). Marcando como aviso."
      return "$RC_WARN"
    fi
  fi
  return "$_rc"
}

# Tenta comando N vezes com delay de 5s entre tentativas.
# Retorna RC_WARN (não fail) se toda tentativa falhar por erro de rede.
# Uso: _retry 2 cargo audit bin
_retry() {
  local n="$1"; shift
  local attempt out rc last_rc=1
  local _network_re='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'
  for (( attempt=1; attempt<=n; attempt++ )); do
    out="$("$@" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    printf '%s\n' "$out" | _strip_ansi >> "$LOG_FILE"
    if (( rc == 0 )); then
      return 0
    fi
    last_rc=$rc
    if (( attempt < n )); then
      log "  Tentativa ${attempt}/${n} falhou (rc=${rc}); aguardando 5s..."
      sleep 5
    fi
  done
  if printf '%s\n' "$out" | grep -qiE "$_network_re"; then
    log "  Todas as ${n} tentativas falharam por erro de rede — marcando como aviso."
    return "$RC_WARN"
  fi
  return "$last_rc"
}

aur_ignore_args() {
  local item
  [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]] || return 0

  for item in $FULL_UPGRADE_AUR_IGNORE; do
    [[ -n "$item" ]] || continue
    printf '%s\n' "--ignore=${item}"
  done
}

elapsed() {
  local secs="$1"
  if (( secs >= 60 )); then
    printf '%dm %02ds' $((secs / 60)) $((secs % 60))
  else
    printf '%ds' "$secs"
  fi
}


_step_counter() {
  # número de steps executados, excluindo skips
  local count=0
  local r
  for r in "${STEP_RESULTS[@]}"; do
    [[ "$r" == "ok" || "$r" == "warn" || "$r" == "todo" || "$r" == "fail" ]] && ((count++))
  done
  printf '%d' "$count"
}

_step_skip_requested() {
  local name="$1"
  [[ -z "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]] && return 1
  local item
  IFS=',' read -ra _skip_items <<< "$FULL_UPGRADE_SKIP"
  for item in "${_skip_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"  # ltrim
    item="${item%"${item##*[![:space:]]}"}"  # rtrim
    [[ "$item" == "$name" ]] && return 0
  done
  return 1
}

_ts() {
  # timestamp relativo MM:SS desde início do script
  local secs=$((SECONDS - TOTAL_START))
  printf '%02d:%02d' $((secs / 60)) $((secs % 60))
}

# Resolve a categoria de um step pelo catálogo (vazio se não-catalogado).
_category_of() {
  local name="$1" category rest
  IFS='|' read -r category rest < <(catalog_info_for_step "$name")
  printf '%s' "$category"
}

step_start() {
  local name="$1"
  STEP_NAMES+=("$name")
  STEP_CATEGORIES+=("$(_category_of "$name")")
  STEP_START=$SECONDS
  STEP_START_ISO="$(date -Is)"
  STEP_REASON=""   # limpa motivo do step anterior; a função do step pode redefinir
  local done_count
  done_count="$(_step_counter)"
  # N = steps já concluídos + 1 (este)
  local step_n=$(( done_count + 1 ))
  local prefix="[${step_n}]"
  if (( ${TOTAL_STEPS:-0} > 0 )); then
    prefix="[${step_n}/${TOTAL_STEPS}] $(ui_bar "$step_n" "$TOTAL_STEPS" 14)"
  fi
  log ""
  log "${C_BLUE}${C_BOLD}${SYM_ARROW} ${prefix} ${name}${C_RESET}  ${C_DIM}+$(_ts)${C_RESET}"
}

step_ok() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("ok")
  STEP_TIMES+=("$dur")
  write_step_event_json "${STEP_NAMES[-1]}" "ok" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  local time_color="$C_DIM"
  (( dur >= 30 )) && time_color="${C_YELLOW}${C_BOLD}"
  log "${C_GREEN}${SYM_OK}${C_RESET} ${STEP_NAMES[-1]} ${time_color}($(elapsed "$dur"))${C_RESET}"
}

step_fail() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("fail")
  STEP_TIMES+=("$dur")
  HAS_FAIL=1
  write_step_event_json "${STEP_NAMES[-1]}" "fail" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  log "${C_RED}${SYM_FAIL}${C_RESET} ${STEP_NAMES[-1]} ${C_DIM}($(elapsed "$dur"))${C_RESET}"
}

step_warn() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("warn")
  STEP_TIMES+=("$dur")
  write_step_event_json "${STEP_NAMES[-1]}" "warn" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  log "${C_YELLOW}${SYM_WARN}${C_RESET} ${STEP_NAMES[-1]} ${C_DIM}($(elapsed "$dur"))${C_RESET}"
}

step_todo() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("todo")
  STEP_TIMES+=("$dur")
  write_step_event_json "${STEP_NAMES[-1]}" "todo" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  log "${C_CYAN}${SYM_TODO}${C_RESET} ${STEP_NAMES[-1]} ${C_DIM}($(elapsed "$dur"))${C_RESET}"
}

step_skip() {
  local name="$1"
  local reason="$2"
  STEP_NAMES+=("$name")
  STEP_CATEGORIES+=("$(_category_of "$name")")
  STEP_RESULTS+=("skip")
  STEP_TIMES+=(0)
  STEP_START_ISO="$(date -Is)"
  write_step_event_json "$name" "skip" 0 0 "$reason"
  log "${C_YELLOW}${SYM_SKIP}${C_RESET} ${name} ${C_DIM}(${reason})${C_RESET}"
}

run_step() {
  local name="$1"
  shift
  # pular se solicitado via FULL_UPGRADE_SKIP
  if _step_skip_requested "$name"; then
    step_skip "$name" "FULL_UPGRADE_SKIP"
    return 0
  fi
  # dry-run: registrar como skip sem executar
  if (( DRY_RUN )); then
    step_skip "$name" "dry-run"
    return 0
  fi

  # verificar dependências de comando do catálogo
  local _cat_category _cat_tags _cat_effect _cat_timeout _cat_cmd_deps _cat_func _cat_desc
  IFS='|' read -r _cat_category _cat_tags _cat_effect _cat_timeout _cat_cmd_deps _cat_func _cat_desc \
    < <(catalog_info_for_step "$name")

  if [[ -n "$_cat_cmd_deps" ]]; then
    local dep
    IFS=',' read -ra _deps_arr <<< "$_cat_cmd_deps"
    for dep in "${_deps_arr[@]}"; do
      dep="${dep#"${dep%%[![:space:]]*}"}"
      dep="${dep%"${dep##*[![:space:]]}"}"
      if [[ -n "$dep" ]] && ! has "$dep"; then
        step_skip "$name" "cmd-ausente: $dep"
        return 0
      fi
    done
  fi

  step_start "$name"

  if (( VERBOSE )); then
    log "${C_DIM}  [verbose] func: ${_cat_func:-$2} | args: $*${C_RESET}"
  fi

  local rc
  local _to="${_cat_timeout:-0}"
  if [[ "$_to" == "0" || -z "$_to" ]]; then
    "$@"
    rc=$?
  else
    # timeout de função Bash: background da função + sleep sentinela + wait -n
    # quem terminar primeiro (função ou sleep) determina o resultado.
    # A função roda em subshell, então STEP_REASON definido dentro dela não
    # propaga ao processo pai — capturamos via arquivo temporário.
    local _reason_file
    _reason_file="$(mktemp 2>/dev/null || printf '')"
    ( "$@"; _rc=$?; [[ -n "$_reason_file" && -n "$STEP_REASON" ]] && printf '%s' "$STEP_REASON" > "$_reason_file"; exit "$_rc" ) &
    local _bg_pid=$!
    ( sleep "$_to" ) &
    local _sleep_pid=$!
    wait -n "$_bg_pid" "$_sleep_pid" 2>/dev/null
    local _first_rc=$?

    if kill -0 "$_bg_pid" 2>/dev/null; then
      # função ainda rodando → sleep terminou primeiro → timeout
      kill "$_bg_pid" 2>/dev/null
      wait "$_bg_pid" 2>/dev/null
      kill "$_sleep_pid" 2>/dev/null
      wait "$_sleep_pid" 2>/dev/null
      rc=124
    else
      # função terminou → matar sleep sentinela
      kill "$_sleep_pid" 2>/dev/null
      wait "$_sleep_pid" 2>/dev/null
      rc=$_first_rc
    fi

    # Recupera o motivo definido dentro do subshell (se houver).
    if [[ -n "$_reason_file" && -s "$_reason_file" ]]; then
      STEP_REASON="$(cat "$_reason_file")"
    fi
    [[ -n "$_reason_file" ]] && rm -f "$_reason_file"

    if (( rc == 124 )); then
      STEP_LAST_RC=$rc
      local dur=$((SECONDS - STEP_START))
      STEP_RESULTS+=("warn")
      STEP_TIMES+=("$dur")
      write_step_event_json "$name" "warn" "$dur" "$rc" "timed_out"
      log "${C_YELLOW}[warn]${C_RESET} ${name} ${C_DIM}(timeout ${_to}s excedido)${C_RESET}"
      return 0
    fi
  fi

  STEP_LAST_RC=$rc
  case "$rc" in
    0) step_ok ;;
    "$RC_WARN") step_warn ;;
    "$RC_TODO") step_todo ;;
    *) step_fail ;;
  esac
}
