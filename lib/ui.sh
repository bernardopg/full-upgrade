#!/usr/bin/env bash
# lib/ui.sh — cores, banner, símbolos, resumo (visual layer)
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_BOLD=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
  C_DIM=""
  C_RESET=""
fi

print_summary() {
  local total_dur=$((SECONDS - TOTAL_START))
  local ok=0 warn=0 todo=0 fail=0 skip=0 i

  for i in "${!STEP_RESULTS[@]}"; do
    case "${STEP_RESULTS[$i]}" in
      ok)   ((ok++)) ;;
      warn) ((warn++)) ;;
      todo) ((todo++)) ;;
      fail) ((fail++)) ;;
      skip) ((skip++)) ;;
    esac
  done

  log_always ""
  log_always "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  log_always "${C_BOLD}Resumo:${C_RESET}"

  # steps executados primeiro
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    local status color dur time_color
    case "${STEP_RESULTS[$i]}" in
      ok)   status="[ ok ]"; color="$C_GREEN" ;;
      warn) status="[warn]"; color="$C_YELLOW" ;;
      todo) status="[todo]"; color="$C_CYAN" ;;
      fail) status="[FAIL]"; color="$C_RED" ;;
    esac
    dur="$(elapsed "${STEP_TIMES[$i]}")"
    time_color="$C_DIM"
    (( "${STEP_TIMES[$i]}" >= 30 )) && time_color="${C_YELLOW}"
    log_always "  ${color}${status}${C_RESET}  ${STEP_NAMES[$i]} ${time_color}(${dur})${C_RESET}"
  done

  # skips agrupados no final
  if (( skip > 0 )); then
    log_always "  ${C_DIM}────────────────────────────────────────${C_RESET}"
    for i in "${!STEP_NAMES[@]}"; do
      [[ "${STEP_RESULTS[$i]}" != "skip" ]] && continue
      log_always "  ${C_YELLOW}[skip]${C_RESET}  ${C_DIM}${STEP_NAMES[$i]}${C_RESET}"
    done
  fi

  log_always "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
  log_always "  Total: ${C_GREEN}${ok} ok${C_RESET}, ${C_YELLOW}${warn} warn${C_RESET}, ${C_CYAN}${todo} todo${C_RESET}, ${C_RED}${fail} fail${C_RESET}, ${C_YELLOW}${skip} skip${C_RESET} em ${C_BOLD}$(elapsed "$total_dur")${C_RESET}"
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
