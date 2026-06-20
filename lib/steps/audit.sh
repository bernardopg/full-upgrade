#!/usr/bin/env bash
# lib/steps/audit.sh — modo --audit: auditoria de segurança consolidada (F6).
# Sourced por full-upgrade.sh (glob de steps). Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Achados acumulados pelas probes. Cada item: "sev|categoria|titulo|detalhe|remediacao".
# sev ∈ {high, medium, low, info}. Os campos nunca contêm '|' (sanitizado em _audit_add).
declare -a AUDIT_FINDINGS=()

_audit_rede_re='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'

# Registra um achado. Remove '|' e quebras de linha dos campos (o delimitador é '|').
_audit_add() {
  local sev="$1" cat="$2" title="$3" detail="${4:-}" remed="${5:-}"
  local f
  for f in sev cat title detail remed; do
    local v="${!f}"
    v="${v//|//}"
    v="${v//$'\n'/ }"
    printf -v "$f" '%s' "$v"
  done
  AUDIT_FINDINGS+=("${sev}|${cat}|${title}|${detail}|${remed}")
}

# ── Probes (cada uma guardada por presença de ferramenta; 0+ achados) ──────────

# CVEs em binários cargo do usuário (reusa o parser de core.sh).
_audit_probe_cargo() {
  has cargo-audit && has cargo || return 0
  local cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  [[ -d "$cargo_bin" ]] || return 0
  local -a bins=()
  mapfile -t bins < <(find "$cargo_bin" -maxdepth 1 -type f -executable 2>/dev/null)
  (( ${#bins[@]} )) || return 0
  local out
  out="$(cargo audit bin "${bins[@]}" 2>&1)"
  if printf '%s\n' "$out" | grep -qiE "$_audit_rede_re"; then
    _audit_add info cargo "Auditoria cargo indisponível" "Falha de rede ao buscar advisory DB" "Repita com rede"
    return 0
  fi
  local -a vb=()
  mapfile -t vb < <(printf '%s\n' "$out" | parse_cargo_vuln_bins)
  (( ${#vb[@]} )) && _audit_add high cargo "CVEs em binários cargo" \
    "${#vb[@]} binário(s): ${vb[*]}" "rustup self update && rustup update; cargo install-update -a"
  return 0
}

# CVEs em pacotes oficiais (se arch-audit estiver instalado).
_audit_probe_arch_audit() {
  has arch-audit || return 0
  local out n
  out="$(arch-audit --quiet 2>/dev/null)"
  n="$(printf '%s\n' "$out" | grep -c . || true)"
  (( n > 0 )) && _audit_add high pacman "$n pacote(s) com CVE (arch-audit)" \
    "Pacotes oficiais com advisories conhecidos" "sudo pacman -Syu"
  return 0
}

# Postura de firmware (HSI) via fwupd.
_audit_probe_fwupd() {
  has fwupdmgr || return 0
  local out hsi lvl
  out="$(fwupdmgr security 2>&1 || true)"
  hsi="$(printf '%s\n' "$out" | grep -oiE 'HSI:[0-9]+' | head -n1)"
  [[ -n "$hsi" ]] || return 0
  lvl="${hsi##*:}"
  if [[ "$lvl" =~ ^[0-9]+$ ]] && (( lvl < 3 )); then
    _audit_add medium fwupd "Postura de firmware baixa ($hsi)" \
      "fwupd reporta $hsi de 4" "Revise 'fwupdmgr security' e a configuração da UEFI"
  else
    _audit_add info fwupd "Postura de firmware $hsi" "fwupd reporta $hsi" ""
  fi
  return 0
}

# Secure Boot habilitado?
_audit_probe_secure_boot() {
  local state=""
  if has mokutil; then
    state="$(mokutil --sb-state 2>/dev/null)"
  fi
  if [[ -z "$state" ]] && has bootctl; then
    state="$(bootctl status 2>/dev/null | grep -i 'secure boot' | head -n1)"
  fi
  [[ -n "$state" ]] || return 0
  if printf '%s' "$state" | grep -qiE 'disabled|desabilit|inativ'; then
    _audit_add medium secureboot "Secure Boot desabilitado" "$state" \
      "Habilite Secure Boot na UEFI se a máquina suportar"
  elif printf '%s' "$state" | grep -qiE 'enabled|ativ'; then
    _audit_add info secureboot "Secure Boot habilitado" "$state" ""
  fi
  return 0
}

# Units systemd falhadas.
_audit_probe_failed_units() {
  has systemctl || return 0
  local units n
  units="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)"
  n="$(printf '%s\n' "$units" | grep -c . || true)"
  (( n > 0 )) && _audit_add medium systemd "$n unit(s) systemd falhada(s)" \
    "$(printf '%s' "$units" | paste -sd, - 2>/dev/null)" "systemctl --failed; journalctl -u <unit>"
  return 0
}

# Erros de autenticação no journal do boot atual.
_audit_probe_journal_auth() {
  has journalctl || return 0
  local out n
  out="$(journalctl -b -p err --no-pager 2>/dev/null | grep -iE 'authentication failure|incorrect password|pam_unix.*failure' || true)"
  n="$(printf '%s\n' "$out" | grep -c . || true)"
  (( n > 0 )) && _audit_add low journal "$n erro(s) de autenticação no journal" \
    "Falhas de auth/sudo no boot atual" "Revise: journalctl -b -p err | grep -i auth"
  return 0
}

# Dependências pip quebradas.
_audit_probe_pip() {
  has python && python -m pip --version >/dev/null 2>&1 || return 0
  local out rc
  out="$(python -m pip check 2>&1)"
  rc=$?
  if (( rc != 0 )) || printf '%s' "$out" | grep -qiE 'requires|incompatible|has requirement'; then
    _audit_add low python "Dependências pip quebradas" \
      "pip check reportou inconsistências de versão" "Revise: python -m pip check"
  fi
  return 0
}

# ── Relatório consolidado ──────────────────────────────────────────────────────

audit_severity_rank() {
  case "$1" in high) printf 3 ;; medium) printf 2 ;; low) printf 1 ;; *) printf 0 ;; esac
}

# Imprime o relatório agrupado por severidade (alta→info) no stdout.
audit_report_text() {
  printf '%b\n' "${C_BOLD}${C_CYAN}Auditoria de segurança consolidada${C_RESET}"
  printf '%b\n' "${C_BOLD}$(ui_hr "$HR_LIGHT")${C_RESET}"

  if (( ${#AUDIT_FINDINGS[@]} == 0 )); then
    printf '%b\n' "  ${C_GREEN}${SYM_OK}${C_RESET} Nenhum achado de segurança acionável."
    return 0
  fi

  local sev label color item s c title detail remed printed
  for sev in high medium low info; do
    case "$sev" in
      high)   label="ALTA";  color="$C_RED" ;;
      medium) label="MÉDIA"; color="$C_YELLOW" ;;
      low)    label="BAIXA"; color="$C_CYAN" ;;
      *)      label="INFO";  color="$C_DIM" ;;
    esac
    printed=0
    for item in "${AUDIT_FINDINGS[@]}"; do
      IFS='|' read -r s c title detail remed <<< "$item"
      [[ "$s" == "$sev" ]] || continue
      if (( printed == 0 )); then
        printf '%b\n' "  ${color}${C_BOLD}[${label}]${C_RESET}"
        printed=1
      fi
      printf '%b\n' "    ${color}•${C_RESET} ${C_BOLD}${title}${C_RESET} ${C_DIM}(${c})${C_RESET}"
      [[ -n "$detail" ]] && printf '%b\n' "      ${detail}"
      [[ -n "$remed" ]]  && printf '%b\n' "      ${C_DIM}↳ remediação: ${remed}${C_RESET}"
    done
  done

  local h=0 m=0 l=0 ii=0
  for item in "${AUDIT_FINDINGS[@]}"; do
    case "${item%%|*}" in high) ((h++)) ;; medium) ((m++)) ;; low) ((l++)) ;; info) ((ii++)) ;; esac
  done
  printf '%b\n' "${C_BOLD}$(ui_hr "$HR_LIGHT")${C_RESET}"
  printf '%b\n' "  Total: ${C_RED}${h} alta${C_RESET}, ${C_YELLOW}${m} média${C_RESET}, ${C_CYAN}${l} baixa${C_RESET}, ${C_DIM}${ii} info${C_RESET}"
  return 0
}

# Emite a seção JSON da auditoria (uma linha). Usa json_escape de json.sh.
audit_json_section() {
  local first=1 item s c title detail remed h=0 m=0 l=0 ii=0
  printf '{"event":"audit","findings":['
  for item in "${AUDIT_FINDINGS[@]}"; do
    IFS='|' read -r s c title detail remed <<< "$item"
    case "$s" in high) ((h++)) ;; medium) ((m++)) ;; low) ((l++)) ;; info) ((ii++)) ;; esac
    (( first == 0 )) && printf ','
    first=0
    printf '{"severity":%s,"category":%s,"title":%s,"detail":%s,"remediation":%s}' \
      "$(json_escape "$s")" "$(json_escape "$c")" "$(json_escape "$title")" \
      "$(json_escape "$detail")" "$(json_escape "$remed")"
  done
  printf '],"counts":{"high":%d,"medium":%d,"low":%d,"info":%d}}' "$h" "$m" "$l" "$ii"
}

# Ponto de entrada do modo --audit. Read-only (nenhuma probe muta o sistema).
run_audit_mode() {
  AUDIT_FINDINGS=()
  _audit_probe_cargo
  _audit_probe_arch_audit
  _audit_probe_fwupd
  _audit_probe_secure_boot
  _audit_probe_failed_units
  _audit_probe_journal_auth
  _audit_probe_pip
  audit_report_text
  if (( ${JSON_SUMMARY:-0} )); then
    printf '%s\n' "$(audit_json_section)"
  fi
  return 0
}
