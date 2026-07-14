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


# K3 — true (rc 0) se `rustup check` indica atualização disponível para rustup
# ou para a toolchain. Usado para decidir se CVEs restritas a binários da
# toolchain são acionáveis (há update pendente) ou não (já na última → a CVE vive
# numa crate vendorizada no binário upstream e só some quando upstream reconstrói).
rustup_check_has_update() {
  printf '%s\n' "$1" | grep -qiE 'Update available'
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

  # K3: CVEs só em binários da toolchain (rustup/cargo/rustc), sem nenhum binário
  # cargo-installed acionável. Se o rustup já está na última versão, não há
  # remediação local: a CVE vive numa crate vendorizada no binário upstream e só
  # é corrigida quando o upstream reconstrói. Rebaixa de warn para nota
  # informativa (return 0) em vez de poluir todo run com um aviso irreparável.
  if (( ${#cargo_bins[@]} == 0 && ${#toolchain_bins[@]} > 0 )) && has rustup; then
    local _rc_out _rc_rc
    _rc_out="$(run_network_cmd rustup check 2>/dev/null)"
    _rc_rc=$?
    if (( _rc_rc != RC_WARN )) && ! rustup_check_has_update "$_rc_out"; then
      log "  ${vuln_count} binário(s) da toolchain com CVE conhecida: ${vuln_bins[*]}"
      log "  rustup já na última versão — estas CVEs vivem em crates vendorizadas no binário upstream e só somem quando o upstream reconstrói. Não acionável localmente (informativo)."
      log "  Detalhes brutos do cargo-audit foram preservados no log, sem imprimir erros alarmistas no terminal."
      return 0
    fi
  fi

  # Exibe detalhes somente quando há uma ação local possível. A saída bruta já
  # foi gravada no log, então CVEs upstream-only não parecem falha do run.
  printf '%s\n' "$output" \
    | grep -v '^\s*Fetching advisory\|^\s*Loaded \|^\s*Updating crates\|^warning:.*not built with' \
    | grep -v '^$' \
    | grep -A 8 '^Crate:' || true

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


# Roda `cargo audit bin` nos binários de $CARGO_HOME/bin e emite (stdout) os
# basenames vulneráveis, um por linha. rc: RC_WARN se falha de rede transitória,
# 0 caso contrário (mesmo sem CVEs). Isola a coleta para o step de remediação
# medir o estado antes/depois sem duplicar a lógica de parsing.
_rust_collect_vuln_bins() {
  local cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  [[ -d "$cargo_bin" ]] || return 0
  local -a bins=()
  mapfile -t bins < <(find "$cargo_bin" -maxdepth 1 -type f -executable 2>/dev/null)
  (( ${#bins[@]} == 0 )) && return 0

  local output rc netre
  netre='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'
  output="$(cargo audit bin "${bins[@]}" 2>&1)"
  rc=$?
  log_raw "$output"
  if (( rc != 0 )) && printf '%s\n' "$output" | grep -qiE "$netre"; then
    return "$RC_WARN"
  fi
  printf '%s\n' "$output" | parse_cargo_vuln_bins
  return 0
}

# F7 — auto-remediação opcional de CVEs de toolchain/cargo.
# O gate de config (AUTO_FIX_RUST_CVES) é aplicado em main.sh; aqui também é
# defensivo. Mede CVEs antes, aplica `rustup self update && rustup update`
# (toolchain) e `cargo install-update -a` (cargo-installed) sob confirmação/
# --yes, re-audita e reporta antes→depois. Se um binário cargo-installed segue
# vulnerável (já na última versão, CVE pinada no build), rebuilda com
# `cargo install --force` (resolução fresca de deps) e re-audita de novo.
# Sem rede → RC_WARN; recusa/não interativo sem --yes → RC_TODO; CVEs
# remanescentes sem remediação possível → informativo; falha de rebuild → RC_WARN.
autofix_rust_cves() {
  if (( ${AUTO_FIX_RUST_CVES:-0} == 0 )); then
    log "  AUTO_FIX_RUST_CVES desligado; nada a remediar."
    return 0
  fi

  log "  Auditando binários cargo para identificar CVEs corrigíveis..."
  local before_list before_rc
  before_list="$(_rust_collect_vuln_bins)"
  before_rc=$?
  if (( before_rc == RC_WARN )); then
    log "  cargo audit: falha de rede transitória; adiando auto-remediação."
    STEP_REASON="rede indisponível para auditoria"
    return "$RC_WARN"
  fi

  local -a vuln=()
  mapfile -t vuln < <(printf '%s\n' "$before_list" | grep -v '^[[:space:]]*$')
  if (( ${#vuln[@]} == 0 )); then
    log "  Sem CVEs corrigíveis em binários cargo."
    return 0
  fi

  local -a toolchain=() cargobins=()
  local b
  for b in "${vuln[@]}"; do
    if [[ "$(classify_cargo_bin "$b")" == "toolchain" ]]; then
      toolchain+=("$b")
    else
      cargobins+=("$b")
    fi
  done

  log "  CVEs detectadas em ${#vuln[@]} binário(s): ${vuln[*]}"
  (( ${#toolchain[@]} > 0 )) && log "    • toolchain/rustup: ${toolchain[*]}"
  (( ${#cargobins[@]} > 0 )) && log "    • cargo-installed: ${cargobins[*]}"

  # Gate: aplicar mutações exige confirmação ou --yes.
  if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
      printf '%b' "${C_YELLOW}  Aplicar remediação (rustup self update/update + cargo install-update)? [s/N] ${C_RESET}"
      local ans
      read -r ans
      case "$ans" in
        [sS][iI][mM]|[sS]) ;;
        *) log "  Auto-remediação cancelada pelo usuário."; STEP_REASON="cancelado pelo usuário"; return "$RC_TODO" ;;
      esac
    else
      log "  Execução não interativa sem --yes; pulando auto-remediação."
      STEP_REASON="requer --yes ou confirmação interativa"
      return "$RC_TODO"
    fi
  fi

  local applied=0
  if (( ${#toolchain[@]} > 0 )) && has rustup; then
    log "  Atualizando toolchain/rustup..."
    run_logged rustup self update || true
    run_logged rustup update || true
    applied=1
  fi
  if (( ${#cargobins[@]} > 0 )); then
    if has cargo-install-update; then
      log "  Atualizando binários cargo-installed..."
      run_logged cargo install-update -a || true
      applied=1
    else
      log "  cargo-update ausente; binários cargo-installed não puderam ser atualizados."
    fi
  fi

  if (( applied == 0 )); then
    log "  Nenhuma ferramenta de remediação disponível (rustup/cargo-update)."
    STEP_REASON="sem ferramenta de remediação aplicável"
    return "$RC_WARN"
  fi

  log "  Re-auditando após remediação..."
  local after_list after_rc
  after_list="$(_rust_collect_vuln_bins)"
  after_rc=$?
  if (( after_rc == RC_WARN )); then
    log "  Re-auditoria falhou por rede; resultado inconclusivo."
    STEP_REASON="re-auditoria sem rede"
    return "$RC_WARN"
  fi

  local -a after=()
  mapfile -t after < <(printf '%s\n' "$after_list" | grep -v '^[[:space:]]*$')
  log "  CVEs antes: ${#vuln[@]} → depois: ${#after[@]}."
  if (( ${#after[@]} == 0 )); then
    log "  ${C_GREEN}Todas as CVEs corrigíveis foram remediadas.${C_RESET}"
    return 0
  fi
  # K3: classificar o que sobrou. rustup já foi atualizado acima, então CVEs
  # remanescentes restritas a binários da toolchain vivem em crates vendorizadas
  # no binário upstream — irreparáveis localmente, só somem quando o upstream
  # reconstrói. Nesse caso vira nota informativa (ok) em vez de warn recorrente.
  local -a after_toolchain=() after_cargo=()
  for b in "${after[@]}"; do
    if [[ "$(classify_cargo_bin "$b")" == "toolchain" ]]; then
      after_toolchain+=("$b")
    else
      after_cargo+=("$b")
    fi
  done

  if (( ${#after_cargo[@]} == 0 )); then
    log "  CVEs remanescentes restritas à toolchain (${after_toolchain[*]}): vivem em crates vendorizadas no binário rustup upstream, já na última versão — não acionável localmente (informativo)."
    return 0
  fi

  # Fase 2 — rebuild com resolução fresca. `cargo install-update` só age quando
  # há versão nova no registry; se o binário já está na última versão mas foi
  # buildado com uma crate vulnerável pinada (build --locked, prebuilt via
  # binstall ou Cargo.lock empacotado do release), `cargo install --force`
  # re-resolve as dependências para as versões compatíveis mais novas e remove
  # a CVE sem depender de release novo do upstream.
  local install_list crate rebuilt=0
  local -a rebuild_failed=()
  install_list="$(cargo install --list 2>/dev/null)"
  for b in "${after_cargo[@]}"; do
    crate="$(cargo_crate_for_bin "$b" "$install_list")"
    if [[ -z "$crate" ]]; then
      log "    ${b}: sem crate correspondente em 'cargo install --list'; rebuild indisponível."
      rebuild_failed+=("$b")
      continue
    fi
    log "  Rebuild com resolução fresca de dependências: cargo install --force ${crate}"
    if run_logged cargo install --force "$crate"; then
      rebuilt=1
    else
      rebuild_failed+=("$b")
    fi
  done

  if (( rebuilt )); then
    log "  Re-auditando após rebuild..."
    after_list="$(_rust_collect_vuln_bins)"
    after_rc=$?
    if (( after_rc == RC_WARN )); then
      log "  Re-auditoria (pós-rebuild) falhou por rede; resultado inconclusivo."
      STEP_REASON="re-auditoria sem rede"
      return "$RC_WARN"
    fi
    mapfile -t after < <(printf '%s\n' "$after_list" | grep -v '^[[:space:]]*$')
    after_toolchain=() after_cargo=()
    for b in "${after[@]}"; do
      if [[ "$(classify_cargo_bin "$b")" == "toolchain" ]]; then
        after_toolchain+=("$b")
      else
        after_cargo+=("$b")
      fi
    done
    log "  CVEs após rebuild: ${#after[@]}."
    if (( ${#after[@]} == 0 )); then
      log "  ${C_GREEN}Todas as CVEs corrigíveis foram remediadas.${C_RESET}"
      return 0
    fi
    if (( ${#after_cargo[@]} == 0 )); then
      log "  CVEs remanescentes restritas à toolchain (${after_toolchain[*]}): vivem em crates vendorizadas no binário rustup upstream, já na última versão — não acionável localmente (informativo)."
      return 0
    fi
  fi

  # Rebuild aplicado e a CVE persiste: nem a resolução fresca tem versão
  # corrigida compatível — nada acionável localmente até o upstream publicar.
  if (( ${#rebuild_failed[@]} == 0 )); then
    log "  CVEs persistem após rebuild com resolução fresca (${after_cargo[*]}): sem versão corrigida compatível publicada — aguarda upstream (informativo)."
    return 0
  fi

  log "  ${C_YELLOW}CVEs remanescentes acionáveis (${#after_cargo[@]}): ${after_cargo[*]}${C_RESET}"
  log "    Rebuild indisponível/falhou para: ${rebuild_failed[*]}."
  log "    Podem exigir o gerenciador de pacotes (sudo pacman -Syu rust rustup) ou não ter fix upstream."
  (( ${#after_toolchain[@]} > 0 )) && log "    (${#after_toolchain[@]} CVE(s) de toolchain upstream ignoradas: não acionáveis localmente.)"
  STEP_REASON="${#after_cargo[@]} CVE(s) acionável(is) remanescente(s) após remediação"
  return "$RC_WARN"
}

