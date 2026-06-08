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

  local vuln_count
  vuln_count="$(printf '%s\n' "$output" | grep -c '^error:' || true)"

  if (( vuln_count > 0 )); then
    log "  Aviso: ${vuln_count} binário(s) com CVEs conhecidas (ver log). Atualize com 'cargo install-update -a'."
    STEP_REASON="${vuln_count} binário(s) cargo com CVE conhecida"
    return "$RC_WARN"
  else
    log "  Sem CVEs críticas em binários cargo do usuário."
  fi

  return 0
}


