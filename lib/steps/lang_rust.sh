#!/usr/bin/env bash
# steps/lang_rust.sh — rustup, cargo bins, cargo-audit
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

update_rustup() {
  local check_out
  check_out="$(rustup check 2>&1)"
  printf '%s\n' "$check_out" | tee >(_strip_ansi >> "$LOG_FILE")

  if ! printf '%s\n' "$check_out" | grep -qi 'update available\|needs updating'; then
    log "  rustup: toolchain já atualizado, pulando sync."
    return 0
  fi

  run_logged rustup update
}


update_cargo_bins() {
  run_logged cargo install-update -a
}


audit_cargo_bins() {
  local cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  if [[ ! -d "$cargo_bin" ]]; then
    log "  \$CARGO_HOME/bin não encontrado; pulando auditoria."
    return 0
  fi

  local -a bins=()
  mapfile -t bins < <(find "$cargo_bin" -maxdepth 1 -type f -executable 2>/dev/null)

  if (( ${#bins[@]} == 0 )); then
    log "  Sem binários cargo para auditar."
    return 0
  fi

  log "  Auditando ${#bins[@]} binário(s) cargo por vulnerabilidades conhecidas..."
  local output rc_audit
  output="$(cargo audit bin "${bins[@]}" 2>&1)"
  rc_audit=$?
  if (( rc_audit != 0 )) && printf '%s\n' "$output" | grep -qiE 'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'; then
    log "  cargo audit: falha de rede; tentando novamente em 5s..."
    sleep 5
    output="$(cargo audit bin "${bins[@]}" 2>&1)"
    rc_audit=$?
  fi
  log_raw "$output"
  if (( rc_audit != 0 )) && printf '%s\n' "$output" | grep -qiE 'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'; then
    log "  cargo audit: falha de rede transitória ao buscar advisory DB."
    return "$RC_WARN"
  fi
  # mostrar só blocos de CVE — suprimir Fetching/Loaded/Updating/warning de binários sem auditable
  printf '%s\n' "$output" \
    | grep -v '^\s*Fetching advisory\|^\s*Loaded \|^\s*Updating crates\|^warning:.*not built with' \
    | grep -v '^$' \
    | grep -A 8 '^Crate:' || true

  # Extrai os binários com vulnerabilidade: cargo-audit emite
  #   error: N vulnerabilities found in /home/user/.cargo/bin/<nome>
  local -a vuln_bins=()
  mapfile -t vuln_bins < <(printf '%s\n' "$output" | parse_cargo_vuln_bins)
  local vuln_count="${#vuln_bins[@]}"
  # Fallback se o formato mudar: conta linhas 'error:'.
  if (( vuln_count == 0 )); then
    vuln_count="$(printf '%s\n' "$output" | grep -c '^error:' || true)"
  fi

  if (( vuln_count == 0 )); then
    log "  Sem CVEs críticas em binários cargo do usuário."
    return 0
  fi

  # Remediação correta depende da ORIGEM do binário. rustup/cargo/rustc são
  # parte da toolchain — 'cargo install-update' NÃO os toca; precisam de
  # 'rustup self update' (binários do rustup) ou do gerenciador de pacotes
  # (toolchain via pacman). Só os demais são cargo-installed e atualizáveis
  # via 'cargo install-update -a'.
  local -a toolchain_bins=() cargo_bins=()
  local _b
  for _b in "${vuln_bins[@]}"; do
    if [[ "$(classify_cargo_bin "$_b")" == "toolchain" ]]; then
      toolchain_bins+=("$_b")
    else
      cargo_bins+=("$_b")
    fi
  done

  log "  ${C_YELLOW}Aviso: ${vuln_count} binário(s) com CVEs conhecidas: ${vuln_bins[*]}${C_RESET}"
  if (( ${#cargo_bins[@]} > 0 )); then
    log "    • Instalados via cargo (${#cargo_bins[@]}): ${cargo_bins[*]}"
    remediation "cargo install-update -a"
  fi
  if (( ${#toolchain_bins[@]} > 0 )); then
    log "    • Toolchain/rustup (${#toolchain_bins[@]}): ${toolchain_bins[*]}"
    log "      'cargo install-update' não corrige estes."
    remediation "rustup self update && rustup update"
    remediation "sudo pacman -Syu rust rustup  # se gerenciados pelo pacman"
  fi
  STEP_REASON="${vuln_count} binário(s) com CVE (${#toolchain_bins[@]} toolchain, ${#cargo_bins[@]} cargo)"
  return "$RC_WARN"
}


