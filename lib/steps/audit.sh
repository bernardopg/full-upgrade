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
_audit_rustup_check_has_update() {
  printf '%s\n' "$1" | grep -qiE 'update available|atualiza(c|ç)[aã]o dispon[ií]vel'
}

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
  (( ${#vb[@]} )) || return 0

  local -a toolchain=() cargobins=()
  local b
  for b in "${vb[@]}"; do
    if [[ "$(classify_cargo_bin "$b")" == "toolchain" ]]; then
      toolchain+=("$b")
    else
      cargobins+=("$b")
    fi
  done

  if (( ${#cargobins[@]} > 0 )); then
    local detail="${#cargobins[@]} cargo-installed: ${cargobins[*]}"
    (( ${#toolchain[@]} > 0 )) && detail+="; ${#toolchain[@]} toolchain: ${toolchain[*]}"
    _audit_add high cargo "CVEs em binários cargo" \
      "$detail" "cargo install-update -a; rustup self update && rustup update (se toolchain também afetada)"
    return 0
  fi

  if (( ${#toolchain[@]} > 0 )) && has rustup; then
    local rustup_out rustup_rc
    rustup_out="$(run_network_cmd rustup check 2>/dev/null)"
    rustup_rc=$?
    if (( rustup_rc == 0 )) && ! _audit_rustup_check_has_update "$rustup_out"; then
      _audit_add info cargo "CVEs em toolchain Rust sem correção local" \
        "${#toolchain[@]} binário(s): ${toolchain[*]}; rustup já está na última versão, CVEs vivem em crates vendorizadas upstream" \
        "Sem ação local; aguarde rebuild upstream do rustup/toolchain"
      return 0
    fi
  fi

  _audit_add high cargo "CVEs em toolchain Rust" \
    "${#toolchain[@]} binário(s): ${toolchain[*]}" "rustup self update && rustup update"
  return 0
}

# CVEs em pacotes oficiais (se arch-audit estiver instalado). N1: separa os já
# corrigíveis nos repos (acionável via pacman -Syu) dos sem correção upstream
# (informativo) — antes marcava todos como high/pacman -Syu, enganoso quando o
# sistema já está atualizado e os remanescentes só dependem de upstream.
_audit_probe_arch_audit() {
  has arch-audit || return 0
  local total fixable manual
  total="$(arch-audit --quiet 2>/dev/null | grep -cE '.' || true)"
  total="${total:-0}"
  (( total > 0 )) || return 0
  fixable="$(arch-audit -u --quiet 2>/dev/null | grep -cE '.' || true)"
  fixable="${fixable:-0}"
  (( fixable > total )) && fixable="$total"
  manual=$(( total - fixable ))
  (( fixable > 0 )) && _audit_add high pacman "$fixable pacote(s) oficial(is) com CVE já corrigível" \
    "Versão corrigida disponível nos repos" "sudo pacman -Syu"
  (( manual > 0 )) && _audit_add info pacman "$manual pacote(s) oficial(is) com CVE sem correção upstream" \
    "Afetados conhecidos, ainda sem versão corrigida; acompanhe o tracker de segurança Arch" "Sem ação local; aguarde atualização upstream"
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
    local sev="info"
    (( ${SECURE_BOOT_STRICT:-0} == 1 )) && sev="medium"
    _audit_add "$sev" secureboot "Secure Boot desabilitado" "$state; postura/política de segurança, não falha operacional" \
      "Opcional: habilite Secure Boot na UEFI se a máquina suportar; use SECURE_BOOT_STRICT=1 para tratar como severidade média"
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

# G4 — relatório de auditoria em Markdown (sem ANSI), agrupado por severidade.
# Emite no stdout; reaproveitado por --audit --report.
audit_report_markdown() {
  printf '# Auditoria de segurança consolidada\n\n'

  if (( ${#AUDIT_FINDINGS[@]} == 0 )); then
    printf '_Nenhum achado de segurança acionável._\n'
    return 0
  fi

  local sev label item s c title detail remed printed
  for sev in high medium low info; do
    case "$sev" in
      high)   label="Alta"  ;;
      medium) label="Média" ;;
      low)    label="Baixa" ;;
      *)      label="Info"  ;;
    esac
    printed=0
    for item in "${AUDIT_FINDINGS[@]}"; do
      IFS='|' read -r s c title detail remed <<< "$item"
      [[ "$s" == "$sev" ]] || continue
      if (( printed == 0 )); then
        printf '## %s\n\n' "$label"
        printed=1
      fi
      printf -- '- **%s** (%s)\n' "$title" "$c"
      [[ -n "$detail" ]] && printf '  - %s\n' "$detail"
      # Backticks são Markdown literal ao redor do placeholder de printf.
      # shellcheck disable=SC2016
      [[ -n "$remed" ]]  && printf '  - remediação: `%s`\n' "$remed"
    done
    (( printed == 1 )) && printf '\n'
  done

  local h=0 m=0 l=0 ii=0
  for item in "${AUDIT_FINDINGS[@]}"; do
    case "${item%%|*}" in high) ((h++)) ;; medium) ((m++)) ;; low) ((l++)) ;; info) ((ii++)) ;; esac
  done
  printf '**Total:** %d alta, %d média, %d baixa, %d info\n' "$h" "$m" "$l" "$ii"
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

  # G4: com --report, emite Markdown (no arquivo REPORT_FILE ou stdout) em vez do
  # relatório colorido; senão, o relatório de texto padrão.
  if (( ${DO_REPORT:-0} )); then
    if [[ -n "${REPORT_FILE:-}" ]]; then
      if audit_report_markdown > "$REPORT_FILE"; then
        printf 'Relatório de auditoria gravado: %s\n' "$REPORT_FILE"
      else
        printf 'full-upgrade: falha ao gravar relatório de auditoria em %s\n' "$REPORT_FILE" >&2
        return 1
      fi
    else
      audit_report_markdown
    fi
  else
    audit_report_text
  fi

  if (( ${JSON_SUMMARY:-0} )); then
    printf '%s\n' "$(audit_json_section)"
  fi
  return 0
}
