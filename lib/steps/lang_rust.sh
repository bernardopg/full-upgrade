#!/usr/bin/env bash
# steps/lang_rust.sh — rustup, cargo bins, cargo-audit
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

update_rustup() {
  local check_out check_rc
  check_out="$(run_network_cmd rustup check 2>&1)"
  check_rc=$?
  printf '%s\n' "$check_out" | log_stream

  if (( check_rc != 0 )); then
    STEP_REASON="não foi possível verificar atualizações do rustup"
    return "$RC_WARN"
  fi

  if ! grep -qi 'update available\|needs updating' <<<"$check_out"; then
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
  grep -qiE 'Update available' <<<"$1"
}


# Puro. rc 0 (true) somente quando a saída do rustup afirma, POSITIVAMENTE, que
# nada mudou: há pelo menos uma linha "<alvo> unchanged - <ver>" e nenhuma de
# "updated"/"installed". Qualquer formato não reconhecido (inclusive vazio, erro
# de rede ou "self-update is disabled for this build") → rc 1, ou seja, "assuma
# que mudou". O viés é deliberado: quem consome isto usa o resultado para PULAR
# uma re-auditoria de segurança, e pular indevidamente esconderia CVE.
rustup_output_unchanged() {
  local out="$1"
  grep -qE '(^|[[:space:]])unchanged[[:space:]]+-' <<<"$out" || return 1
  grep -qE '(^|[[:space:]])(updated|installed)[[:space:]]+-' <<<"$out" && return 1
  return 0
}


# Puro. rc 0 (true) quando `cargo install-update -a` reporta que nenhum pacote
# precisava de update. Mesmo viés conservador de rustup_output_unchanged:
# formato desconhecido → rc 1 (assume que mudou).
cargo_install_update_unchanged() {
  grep -qiE 'no packages need updating|all packages are up to date' <<<"$1"
}


# Executa um comando de remediação preservando o streaming para terminal+log
# (como run_logged) e ainda ecoando a saída em stdout, para o chamador decidir
# via $( ) se houve mudança real. Existe porque run_logged consome a saída no
# pipe e só devolve o rc.
_rust_run_capture() {
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | log_stream
  printf '%s' "$out"
  return "$rc"
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
  if (( rc_audit != 0 )) && grep -qiE 'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect' <<<"$output"; then
    log "  cargo audit: falha de rede; tentando novamente em 5s..."
    sleep 5
    output="$(cargo audit bin "${bins[@]}" 2>&1)"
    rc_audit=$?
  fi
  log_raw "$output"
  if (( rc_audit != 0 )) && grep -qiE 'name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect' <<<"$output"; then
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
  if (( rc != 0 )) && grep -qiE "$netre" <<<"$output"; then
    return "$RC_WARN"
  fi
  printf '%s\n' "$output" | parse_cargo_vuln_bins
  return 0
}

# ── Memo do rebuild sem fix (fase 2 do F7) ───────────────────────────────────
# `cargo install --force` de um crate grande custa minutos (cargo-outdated levou
# 14m19s num run real) e é determinístico enquanto nem o crate nem as deps dele
# publicarem versão corrigida: cada run pagava o mesmo rebuild para reencontrar
# exatamente as mesmas CVEs e fechar com a mesma nota informativa. O memo grava
# "crate@versão foi rebuildado e a CVE persistiu" e pula o rebuild dentro da
# janela de RUST_CVE_REBUILD_TTL_D dias.
# ponytail: janela por tempo em vez de invalidação exata — o fix pode chegar por
# uma dependência nova sem o crate mudar de versão, então o TTL garante uma nova
# tentativa periódica sem precisar rastrear o grafo de deps.
_rust_rebuild_memo_file() {
  printf '%s/rust-cve-rebuild-nofix.tsv' "${LOG_DIR:-$HOME/.cache/system-upgrade}"
}

# Puro: existe entrada <crate>\t<versão>\t<epoch> dentro do TTL?
# $1=conteúdo do memo  $2=crate  $3=versão  $4=agora(epoch)  $5=ttl em dias
rust_rebuild_memo_is_fresh() {
  local memo="$1" crate="$2" ver="$3" now="$4" ttl="$5" c v ts
  [[ -n "$crate" && -n "$ver" ]] || return 1
  [[ "$now" =~ ^[0-9]+$ && "$ttl" =~ ^[0-9]+$ ]] || return 1
  (( ttl > 0 )) || return 1
  while IFS=$'\t' read -r c v ts; do
    [[ "$c" == "$crate" && "$v" == "$ver" ]] || continue
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    (( now - ts < ttl * 86400 )) && return 0
  done <<< "$memo"
  return 1
}

# Puro: devolve o memo com a entrada do crate substituída pela atual (uma linha
# por crate — versões antigas não se acumulam).
rust_rebuild_memo_upsert() {
  local memo="$1" crate="$2" ver="$3" now="$4" c v ts
  while IFS=$'\t' read -r c v ts; do
    [[ -n "$c" && "$c" != "$crate" && -n "$ts" ]] || continue
    printf '%s\t%s\t%s\n' "$c" "$v" "$ts"
  done <<< "$memo"
  printf '%s\t%s\t%s\n' "$crate" "$ver" "$now"
}

_rust_rebuild_memo_skip() {
  local f; f="$(_rust_rebuild_memo_file)"
  [[ -r "$f" ]] || return 1
  rust_rebuild_memo_is_fresh "$(cat "$f" 2>/dev/null)" "$1" "$2" \
    "$(date +%s)" "${RUST_CVE_REBUILD_TTL_D:-7}"
}

_rust_rebuild_memo_record() {
  local f cur=""
  f="$(_rust_rebuild_memo_file)"
  [[ -r "$f" ]] && cur="$(cat "$f" 2>/dev/null)"
  rust_rebuild_memo_upsert "$cur" "$1" "$2" "$(date +%s)" > "${f}.tmp" 2>/dev/null &&
    mv -f "${f}.tmp" "$f" 2>/dev/null || rm -f "${f}.tmp" 2>/dev/null
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

  # `noop` só cai para 0 quando alguma ferramenta relata mudança real. Serve
  # para dispensar a re-auditoria no caso comum (máquina já atualizada), em que
  # ela repetiria um sweep de `cargo audit bin` idêntico — advisory DB + índice
  # do crates.io pela rede — sobre binários que ninguém reescreveu.
  local applied=0 noop=1
  if (( ${#toolchain[@]} > 0 )) && has rustup; then
    log "  Atualizando toolchain/rustup..."
    local _self_out _upd_out
    _self_out="$(_rust_run_capture rustup self update)" || true
    _upd_out="$(_rust_run_capture rustup update)" || true
    applied=1
    if ! rustup_output_unchanged "$_self_out" || ! rustup_output_unchanged "$_upd_out"; then
      noop=0
    fi
  fi
  if (( ${#cargobins[@]} > 0 )); then
    if has cargo-install-update; then
      log "  Atualizando binários cargo-installed..."
      local _ciu_out
      _ciu_out="$(_rust_run_capture cargo install-update -a)" || true
      applied=1
      cargo_install_update_unchanged "$_ciu_out" || noop=0
    else
      log "  cargo-update ausente; binários cargo-installed não puderam ser atualizados."
    fi
  fi

  if (( applied == 0 )); then
    log "  Nenhuma ferramenta de remediação disponível (rustup/cargo-update)."
    STEP_REASON="sem ferramenta de remediação aplicável"
    return "$RC_WARN"
  fi

  local -a after=()
  local after_list after_rc
  if (( noop == 1 )); then
    log "  Remediação foi no-op: tudo já na última versão, nenhum binário reescrito."
    log "  Re-auditoria dispensada — a mesma entrada em disco daria o mesmo veredito."
    after=("${vuln[@]}")
  else
    log "  Re-auditando após remediação..."
    after_list="$(_rust_collect_vuln_bins)"
    after_rc=$?
    if (( after_rc == RC_WARN )); then
      log "  Re-auditoria falhou por rede; resultado inconclusivo."
      STEP_REASON="re-auditoria sem rede"
      return "$RC_WARN"
    fi
    mapfile -t after < <(printf '%s\n' "$after_list" | grep -v '^[[:space:]]*$')
  fi
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
  local install_list crate crate_ver rebuilt=0
  local -a rebuild_failed=() memo_skipped=()
  local -A rebuilt_ver=()
  install_list="$(cargo install --list 2>/dev/null)"
  for b in "${after_cargo[@]}"; do
    crate="$(cargo_crate_for_bin "$b" "$install_list")"
    if [[ -z "$crate" ]]; then
      log "    ${b}: sem crate correspondente em 'cargo install --list'; rebuild indisponível."
      rebuild_failed+=("$b")
      continue
    fi
    crate_ver="$(cargo_crate_version "$crate" "$install_list")"
    if _rust_rebuild_memo_skip "$crate" "$crate_ver"; then
      log "    ${crate} v${crate_ver}: rebuild com resolução fresca já tentado nos últimos ${RUST_CVE_REBUILD_TTL_D:-7}d e a CVE persistiu; pulando o rebuild."
      memo_skipped+=("$b")
      continue
    fi
    log "  Rebuild com resolução fresca de dependências: cargo install --force ${crate}"
    if run_logged cargo install --force "$crate"; then
      rebuilt=1
      rebuilt_ver["$b"]="${crate}"$'\t'"$crate_ver"
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
  # Memoriza o par crate@versão para não repetir o mesmo rebuild caro no próximo
  # run enquanto o upstream não se mexer.
  for b in "${after_cargo[@]}"; do
    [[ -n "${rebuilt_ver[$b]+x}" ]] || continue
    IFS=$'\t' read -r crate crate_ver <<< "${rebuilt_ver[$b]}"
    [[ -n "$crate" && -n "$crate_ver" ]] && _rust_rebuild_memo_record "$crate" "$crate_ver"
  done

  if (( ${#rebuild_failed[@]} == 0 )); then
    if (( ${#memo_skipped[@]} > 0 )); then
      log "  CVEs seguem em ${after_cargo[*]}: rebuild com resolução fresca já foi tentado sem fix (memo de ${RUST_CVE_REBUILD_TTL_D:-7}d) — aguarda upstream (informativo)."
    else
      log "  CVEs persistem após rebuild com resolução fresca (${after_cargo[*]}): sem versão corrigida compatível publicada — aguarda upstream (informativo)."
    fi
    return 0
  fi

  log "  ${C_YELLOW}CVEs remanescentes acionáveis (${#after_cargo[@]}): ${after_cargo[*]}${C_RESET}"
  log "    Rebuild indisponível/falhou para: ${rebuild_failed[*]}."
  log "    Podem exigir o gerenciador de pacotes (sudo pacman -Syu rust rustup) ou não ter fix upstream."
  (( ${#after_toolchain[@]} > 0 )) && log "    (${#after_toolchain[@]} CVE(s) de toolchain upstream ignoradas: não acionáveis localmente.)"
  STEP_REASON="${#after_cargo[@]} CVE(s) acionável(is) remanescente(s) após remediação"
  return "$RC_WARN"
}
