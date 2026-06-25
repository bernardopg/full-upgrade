#!/usr/bin/env bash
# lib/ui.sh — camada visual: cores, símbolos, largura adaptativa, banner,
# barra de progresso, resumo agrupado por categoria.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# ── Cores (TTY-aware; respeita NO_COLOR) ────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\033[1m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""; C_DIM=""; C_RESET=""
fi

# ── Símbolos de status (Unicode com fallback ASCII) ─────────────────────────────
# NO_UNICODE=1 ou locale não-UTF8 → fallback ASCII.
if [[ "${NO_UNICODE:-0}" != "1" && "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *[Uu][Tt][Ff]* ]]; then
  SYM_OK="✔"; SYM_FAIL="✘"; SYM_WARN="⚠"; SYM_TODO="→"; SYM_SKIP="⊘"
  SYM_ARROW="▶"; BAR_FULL="▓"; BAR_EMPTY="░"; HR_HEAVY="━"; HR_LIGHT="─"
  BOX_TL="╔"; BOX_TR="╗"; BOX_BL="╚"; BOX_BR="╝"; BOX_H="═"; BOX_V="║"
else
  SYM_OK="ok"; SYM_FAIL="XX"; SYM_WARN="!!"; SYM_TODO="->"; SYM_SKIP="--"
  SYM_ARROW=">"; BAR_FULL="#"; BAR_EMPTY="."; HR_HEAVY="="; HR_LIGHT="-"
  BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="="; BOX_V="|"
fi

# ── Largura adaptativa do terminal ──────────────────────────────────────────────
ui_width() {
  local w="${COLUMNS:-0}"
  (( w == 0 )) && w="$(tput cols 2>/dev/null || echo 0)"
  (( w == 0 )) && w=80
  (( w < 40 )) && w=40
  (( w > 100 )) && w=100
  printf '%d' "$w"
}

# Linha horizontal de largura adaptativa. $1 = char (default HR_HEAVY).
ui_hr() {
  local ch="${1:-$HR_HEAVY}" w; w="$(ui_width)"
  local line=""; local i
  for (( i = 0; i < w; i++ )); do line+="$ch"; done
  printf '%s' "$line"
}

# ── Barra de progresso textual: ui_bar <atual> <total> [largura] ────────────────
ui_bar() {
  local cur="$1" total="$2" width="${3:-16}"
  (( total <= 0 )) && { printf ''; return; }
  local filled=$(( cur * width / total ))
  (( filled > width )) && filled=width
  (( filled < 0 )) && filled=0
  local pct=$(( cur * 100 / total ))
  local bar="" i
  for (( i = 0; i < filled; i++ )); do bar+="$BAR_FULL"; done
  for (( i = filled; i < width; i++ )); do bar+="$BAR_EMPTY"; done
  printf '%s %3d%%' "$bar" "$pct"
}

# ── Banner de cabeçalho (largura adaptativa) ────────────────────────────────────
print_banner() {
  local w title="full-upgrade  ${SCRIPT_VERSION}"
  w="$(ui_width)"
  local inner=$(( w - 2 ))
  # centraliza o título
  local pad=$(( (inner - ${#title}) / 2 ))
  (( pad < 0 )) && pad=0
  local top="" mid="" bot="" i
  for (( i = 0; i < inner; i++ )); do top+="$BOX_H"; bot+="$BOX_H"; done
  local spaces_l="" spaces_r=""
  for (( i = 0; i < pad; i++ )); do spaces_l+=" "; done
  local rem=$(( inner - pad - ${#title} ))
  (( rem < 0 )) && rem=0
  for (( i = 0; i < rem; i++ )); do spaces_r+=" "; done

  log_always "${C_BOLD}${C_CYAN}${BOX_TL}${top}${BOX_TR}${C_RESET}"
  log_always "${C_BOLD}${C_CYAN}${BOX_V}${spaces_l}${title}${spaces_r}${BOX_V}${C_RESET}"
  log_always "${C_BOLD}${C_CYAN}${BOX_BL}${bot}${BOX_BR}${C_RESET}"
  log_always "${C_DIM}$(date '+%Y-%m-%d %H:%M:%S')  ${SYM_ARROW}  host: $(hostname)  ${SYM_ARROW}  kernel: $(uname -r)${C_RESET}"
  log_always "${C_DIM}Script: ${SCRIPT_VERSION}  ${SYM_ARROW}  sha256: ${SCRIPT_SHA256}${C_RESET}"
  log_always "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
  log_always "${C_DIM}JSONL: ${JSONL_FILE}${C_RESET}"
  if (( DRY_RUN )); then
    log_always "${C_YELLOW}${C_BOLD}  [DRY-RUN] Nenhum comando será executado.${C_RESET}"
  fi
  if (( QUIET )); then
    log_always "${C_DIM}  [QUIET] Output suprimido; log completo em: ${LOG_FILE}${C_RESET}"
  fi
  if (( VERBOSE )); then
    log_always "${C_DIM}  [VERBOSE] Função e argumentos de cada step serão exibidos.${C_RESET}"
  fi
  if [[ -n "$MODE" && "$MODE" != "full" ]]; then
    log_always "${C_CYAN}${C_BOLD}  [MODE:${MODE}] Rodando apenas steps do modo ${MODE}.${C_RESET}"
  fi
  if [[ -n "$ONLY_CATEGORY" ]]; then
    log_always "${C_CYAN}  [ONLY] Rodando apenas (categoria/tag/nome): ${ONLY_CATEGORY}${C_RESET}"
  fi
  if [[ -n "$RESUME_STEPS" ]]; then
    log_always "${C_CYAN}  [RESUME] Retomando steps não-ok do último run: ${RESUME_STEPS}${C_RESET}"
  fi
  if (( NO_REPAIR )); then
    log_always "${C_YELLOW}  [NO-REPAIR] Reparos mutáveis serão pulados.${C_RESET}"
  fi
  if (( NO_CLEANUP )); then
    log_always "${C_YELLOW}  [NO-CLEANUP] Limpeza de cache/snapshots/órfãos/symlinks/journal será pulada.${C_RESET}"
  fi
  if (( DEVEL_UPDATE )); then
    log_always "${C_CYAN}  [--devel] Pacotes AUR -git/-svn incluídos no update.${C_RESET}"
  fi
  if (( JSON_SUMMARY )); then
    log_always "${C_CYAN}  [JSON] Resumo JSON será impresso ao final.${C_RESET}"
  fi
  if [[ -n "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]]; then
    local skip_count; skip_count="$(skip_step_count)"
    if (( skip_count > 8 )); then
      log_always "${C_YELLOW}  [SKIP] ${skip_count} step(s) ignorados; o resumo final lista os nomes.${C_RESET}"
    else
      log_always "${C_YELLOW}  [SKIP] Steps ignorados: ${FULL_UPGRADE_SKIP}${C_RESET}"
    fi
  fi
}

# ── Mapeia status → símbolo + cor ───────────────────────────────────────────────
_status_sym() {  # $1 = status → ecoa "SÍMBOLO|COR"
  case "$1" in
    ok)   printf '%s|%s' "$SYM_OK"   "$C_GREEN" ;;
    warn) printf '%s|%s' "$SYM_WARN" "$C_YELLOW" ;;
    todo) printf '%s|%s' "$SYM_TODO" "$C_CYAN" ;;
    fail) printf '%s|%s' "$SYM_FAIL" "$C_RED" ;;
    skip) printf '%s|%s' "$SYM_SKIP" "$C_YELLOW" ;;
  esac
}

# Especificação dos grupos do resumo: "rótulo|categoria categoria ...".
# Centraliza a ordem e permite agrupar categorias distintas sob o mesmo header
# (ex.: editor+shell), evitando headers duplicados e categorias órfãs no fim.
summary_group_specs() {
  cat <<'EOF'
Preflight|core
Reparos|repair
Sistema / Pacman|pacman
Contêineres|containers flatpak docker snap
Linguagens|lang
Firmware / Boot|firmware
Shell / Editor|editor shell
Hyprland|hyprland
IA|ai
Apps manuais|manual
Rede|network
Limpeza|cleanup
Verificação final|final
Doctor (auditorias)|doctor
EOF
}

summary_category_in_group_list() {
  local category="$1" groups="$2" group
  for group in $groups; do
    [[ "$group" == "$category" ]] && return 0
  done
  return 1
}

summary_category_in_groups() {
  local category="$1" line groups
  while IFS='|' read -r _label groups; do
    summary_category_in_group_list "$category" "$groups" && return 0
  done < <(summary_group_specs)
  return 1
}

# Rótulo do grupo de resumo ao qual uma categoria pertence (mesma fonte de
# verdade do resumo). Usado para imprimir cabeçalhos de seção no output ao vivo,
# mantendo a organização da execução idêntica à do resumo final.
_group_label_for_category() {
  local category="$1" label cats
  while IFS='|' read -r label cats; do
    summary_category_in_group_list "$category" "$cats" && { printf '%s' "$label"; return 0; }
  done < <(summary_group_specs)
  printf 'Outros'
}

# Rótulo legível por categoria (fallback para callers antigos; o resumo usa
# summary_group_specs para evitar duplicação de headers).
_category_label() {
  case "$1" in
    core)     printf 'Preflight' ;;
    repair)   printf 'Reparos' ;;
    pacman)   printf 'Sistema / Pacman' ;;
    flatpak|docker|containers) printf 'Contêineres' ;;
    lang)     printf 'Linguagens' ;;
    firmware) printf 'Firmware / Boot' ;;
    editor|shell) printf 'Shell / Editor' ;;
    hyprland) printf 'Hyprland' ;;
    ai)       printf 'IA' ;;
    manual)   printf 'Apps manuais' ;;
    network)  printf 'Rede' ;;
    cleanup)  printf 'Limpeza' ;;
    final)    printf 'Verificação final' ;;
    doctor)   printf 'Doctor (auditorias)' ;;
    *)        printf 'Outros' ;;
  esac
}

summary_group_total_seconds() {
  local groups="$1" i total=0
  for i in "${!STEP_RESULTS[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    summary_category_in_group_list "${STEP_CATEGORIES[$i]:-}" "$groups" || continue
    total=$(( total + ${STEP_TIMES[$i]:-0} ))
  done
  printf '%s' "$total"
}

summary_slowest_steps() {
  local limit="${1:-3}" i
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    printf '%s\t%s\t%s\n' "${STEP_TIMES[$i]:-0}" "${STEP_NAMES[$i]}" "${STEP_RESULTS[$i]}"
  done | sort -rn | head -n "$limit"
}

summary_category_totals_json() {
  local first=1 group_label group_cats i status total ok warn todo fail skip
  printf '{'
  while IFS='|' read -r group_label group_cats; do
    total=0; ok=0; warn=0; todo=0; fail=0; skip=0
    for i in "${!STEP_RESULTS[@]}"; do
      summary_category_in_group_list "${STEP_CATEGORIES[$i]:-}" "$group_cats" || continue
      status="${STEP_RESULTS[$i]}"
      case "$status" in
        ok) ((ok++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        warn) ((warn++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        todo) ((todo++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        fail) ((fail++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        skip) ((skip++)) ;;
      esac
    done
    (( ok + warn + todo + fail + skip == 0 )) && continue
    (( first == 0 )) && printf ','
    first=0
    printf '%s:{"duration_seconds":%s,"ok":%s,"warn":%s,"todo":%s,"fail":%s,"skip":%s}' \
      "$(json_escape "$group_label")" "$total" "$ok" "$warn" "$todo" "$fail" "$skip"
  done < <(summary_group_specs)
  printf '}'
}

summary_slowest_steps_json() {
  local first=1 line dur name status
  printf '['
  while IFS=$'\t' read -r dur name status; do
    [[ -n "$name" ]] || continue
    (( first == 0 )) && printf ','
    first=0
    printf '{"step":%s,"status":%s,"duration_seconds":%s}' \
      "$(json_escape "$name")" "$(json_escape "$status")" "${dur:-0}"
  done < <(summary_slowest_steps 3)
  printf ']'
}

reboot_recommendation_from_reason() {
  local reason="$1"
  [[ -n "${reason//[[:space:]]/}" ]] || return 1
  printf 'Reboot recomendado: %s\n' "$reason"
}

# ── Resumo agrupado por categoria ───────────────────────────────────────────────
print_summary() {
  local total_dur=$((SECONDS - TOTAL_START))
  local ok=0 warn=0 todo=0 fail=0 skip=0 i

  for i in "${!STEP_RESULTS[@]}"; do
    case "${STEP_RESULTS[$i]}" in
      ok) ((ok++));; warn) ((warn++));; todo) ((todo++));; fail) ((fail++));; skip) ((skip++));;
    esac
  done

  log_always ""
  log_always "${C_BOLD}$(ui_hr "$HR_HEAVY")${C_RESET}"
  log_always "${C_BOLD}Resumo${C_RESET}"

  # Ordem/grupos de categorias para exibição.
  local group_label group_cats
  while IFS='|' read -r group_label group_cats; do
    local printed_header=0
    local group_total
    group_total="$(summary_group_total_seconds "$group_cats")"
    for i in "${!STEP_NAMES[@]}"; do
      summary_category_in_group_list "${STEP_CATEGORIES[$i]:-}" "$group_cats" || continue
      [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
      if (( printed_header == 0 )); then
        log_always "  ${C_BOLD}${C_BLUE}${group_label}${C_RESET} ${C_DIM}($(elapsed "$group_total"))${C_RESET}"
        printed_header=1
      fi
      local sym color dur time_color symcolor
      symcolor="$(_status_sym "${STEP_RESULTS[$i]}")"
      sym="${symcolor%%|*}"; color="${symcolor##*|}"
      dur="$(elapsed "${STEP_TIMES[$i]}")"
      time_color="$C_DIM"
      (( "${STEP_TIMES[$i]}" >= 30 )) && time_color="${C_YELLOW}"
      log_always "    ${color}${sym}${C_RESET}  ${STEP_NAMES[$i]} ${time_color}(${dur})${C_RESET}"
    done
  done < <(summary_group_specs)

  # Steps sem categoria conhecida (defensivo).
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    local c="${STEP_CATEGORIES[$i]:-}"
    summary_category_in_groups "$c" && continue
    local symcolor sym color dur
    symcolor="$(_status_sym "${STEP_RESULTS[$i]}")"; sym="${symcolor%%|*}"; color="${symcolor##*|}"
    dur="$(elapsed "${STEP_TIMES[$i]}")"
    log_always "    ${color}${sym}${C_RESET}  ${STEP_NAMES[$i]} ${C_DIM}(${dur})${C_RESET}"
  done

  # Skips agrupados ao final.
  if (( skip > 0 )); then
    log_always "  ${C_DIM}$(ui_hr "$HR_LIGHT")${C_RESET}"
    for i in "${!STEP_NAMES[@]}"; do
      [[ "${STEP_RESULTS[$i]}" != "skip" ]] && continue
      log_always "    ${C_YELLOW}${SYM_SKIP}${C_RESET}  ${C_DIM}${STEP_NAMES[$i]}${C_RESET}"
    done
  fi

  log_always "${C_BOLD}$(ui_hr "$HR_HEAVY")${C_RESET}"
  log_always "  Total: ${C_GREEN}${ok} ok${C_RESET}, ${C_YELLOW}${warn} warn${C_RESET}, ${C_CYAN}${todo} todo${C_RESET}, ${C_RED}${fail} fail${C_RESET}, ${C_YELLOW}${skip} skip${C_RESET} em ${C_BOLD}$(elapsed "$total_dur")${C_RESET}"
  if [[ -n "${REBOOT_RECOMMENDATION:-}" ]]; then
    log_always "  ${C_YELLOW}${C_BOLD}$(reboot_recommendation_from_reason "$REBOOT_RECOMMENDATION")${C_RESET}"
  fi
  local slow_line slow_dur slow_name slow_status printed_slow=0
  while IFS=$'\t' read -r slow_dur slow_name slow_status; do
    [[ -n "$slow_name" ]] || continue
    if (( printed_slow == 0 )); then
      log_always "  ${C_BOLD}Top 3 mais lentos:${C_RESET}"
      printed_slow=1
    fi
    log_always "    ${C_DIM}$(elapsed "$slow_dur")${C_RESET}  ${slow_name} (${slow_status})"
  done < <(summary_slowest_steps 3)
  if (( todo > 0 )); then
    log_always "  ${C_CYAN}${C_BOLD}Ação necessária: ${todo} item(ns) precisam de decisão ou ação manual.${C_RESET}"
  fi
  if (( warn > 0 )); then
    log_always "  ${C_YELLOW}${C_BOLD}Aviso: ${warn} item(ns) merecem revisão, mas não bloquearam o update.${C_RESET}"
  fi
  if (( fail > 0 )); then
    log_always "  ${C_RED}${C_BOLD}Atenção: ${fail} step(s) com falha — verifique o log: ${LOG_FILE}${C_RESET}"
  fi

  write_summary_event_json "$ok" "$warn" "$todo" "$fail" "$skip" "$total_dur"
  if (( JSON_SUMMARY )); then
    printf '%s\n' "$(summary_json_line "$ok" "$warn" "$todo" "$fail" "$skip" "$total_dur")"
  fi
}


# L3 — bloco "Pacotes alterados" no resumo: lê dois snapshots de pacman -Q
# (antes/depois do run) e mostra atualizados (nome velha → nova), instalados e
# removidos. Lista capada; sem diff => nada é impresso. rc 0 sempre.
print_pkg_changes() {
  local before="$1" after="$2"
  [[ -r "$before" && -r "$after" ]] || return 0
  local diff
  diff="$(pkg_diff "$before" "$after" 2>/dev/null)"
  [[ -n "${diff//[[:space:]]/}" ]] || return 0

  local up ins rem
  up="$(grep -c '^U ' <<< "$diff" || true)"
  ins="$(grep -c '^I ' <<< "$diff" || true)"
  rem="$(grep -c '^R ' <<< "$diff" || true)"

  log_always "${C_BOLD}Pacotes alterados${C_RESET}  (${C_GREEN}${up} atualizados${C_RESET}, ${ins} instalados, ${rem} removidos)"

  local shown=0 max=30 tag a b c
  while read -r tag a b c; do
    [[ -n "$tag" ]] || continue
    if (( shown >= max )); then
      log_always "    ${C_DIM}… e mais $(( up + ins + rem - shown )) (lista completa no log)${C_RESET}"
      break
    fi
    case "$tag" in
      U) log_always "    ${C_GREEN}↑${C_RESET} ${a}  ${C_DIM}${b} → ${c}${C_RESET}" ;;
      I) log_always "    ${C_CYAN}+${C_RESET} ${a}  ${C_DIM}${b}${C_RESET}" ;;
      R) log_always "    ${C_RED}−${C_RESET} ${a}  ${C_DIM}${b}${C_RESET}" ;;
    esac
    (( shown++ ))
  done <<< "$diff"
}
