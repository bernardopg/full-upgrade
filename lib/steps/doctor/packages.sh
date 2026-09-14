#!/usr/bin/env bash
# lib/steps/doctor/packages.sh — auditorias de pacotes: pacman, AUR (paru), arch-audit, pacnew/pacsave, hooks ALPM e Flatpak.
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)



doctor_paru_devel_mode() {
  if ! has paru; then
    log "  paru não instalado; pulando auditoria de Devel."
    return 0
  fi

  local conf
  for conf in /etc/paru.conf "$HOME/.config/paru/paru.conf"; do
    [[ -r "$conf" ]] || continue
    if awk '$1 == "Devel" { found=1 } END { exit found ? 0 : 1 }' "$conf"; then
      log "  paru tem Devel ativo em ${conf}."
      log "  Isso faz pacotes -git/-svn atualizarem mesmo sem passar --devel ao script."
      return "$RC_WARN"
    fi
  done

  log "  paru Devel global não está ativo."
  return 0
}



doctor_flatpak_repair_dry_run() {
  if ! has flatpak; then
    log "  flatpak não instalado."
    return 0
  fi

  local output rc
  output="$(flatpak repair --user --dry-run 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc != 0 )); then
    log "  flatpak repair --user --dry-run retornou código ${rc}:"
    printf '%s\n' "$output" | grep -v '^$' | log_out || true
    return "$RC_WARN"
  fi

  if [[ -z "${output//[[:space:]]/}" ]]; then
    log "  Flatpak repair dry-run: nenhuma inconsistência reportada."
  else
    printf '%s\n' "$output" | grep -v '^$' | log_out || true
  fi
  return 0
}


# Remove de um relatório `pacman -Qkq` (stdin) as linhas que casam padrões de
# falso-positivo (passados como argumentos). Emite só as linhas "reais".
pacman_qk_filter_noise() {
  local filtered; filtered="$(cat)"
  local pat
  for pat in "$@"; do
    filtered="$(printf '%s\n' "$filtered" | grep -Ev "$pat" || true)"
  done
  printf '%s\n' "$filtered" | grep '[^[:space:]]' || true
}



doctor_pacman_health() {
  if ! has pacman; then
    log "  pacman não encontrado."
    return 0
  fi

  local output rc count filtered noise_count check_cmd_label
  local -a check_cmd=(pacman -Qkq)

  if has sudo && sudo -n true >/dev/null 2>&1; then
    check_cmd=(sudo pacman -Qkq)
    check_cmd_label="sudo pacman -Qkq"
  else
    check_cmd_label="pacman -Qkq"
  fi

  # Padrões de falsos positivos conhecidos:
  #   hicolor-icon-theme declara dirs 256x256@2 que apps instalam conforme necessário
  #   intel-ucode /boot/intel-ucode.img é embutido no initramfs pelo mkinitcpio
  local -a _pacman_health_noise=(
    '^hicolor-icon-theme /usr/share/icons/hicolor/256x256@2/'
    '^intel-ucode /boot/intel-ucode.img$'
    # Bytecode em __pycache__ é regenerado pelo interpretador (recompila a cada
    # bump de Python ou import); mtime/size divergem do empacotado mas o arquivo
    # é reconstruído sob demanda — não indica pacote quebrado. Filtra só .pyc/.pyo
    # dentro de __pycache__/. Arquivos .py, .orig e .pacnew seguem reportados.
    '/__pycache__/[^ ]*\.py[co]$'
  )

  output="$("${check_cmd[@]}" 2>&1)"
  rc=$?

  if (( rc != 0 )) && [[ -z "${output//[[:space:]]/}" ]]; then
    log "  ${check_cmd_label} retornou código ${rc} sem saída:"
    return "$RC_WARN"
  fi

  if [[ -z "${output//[[:space:]]/}" ]]; then
    log "  ${check_cmd_label}: nenhum pacote com arquivo faltando."
    return 0
  fi

  if [[ "$check_cmd_label" == "pacman -Qkq" ]] && grep -Eqi 'permission denied|permiss[aã]o negada' <<<"$output"; then
    log "  pacman -Qkq encontrou caminhos sem permissão; rode com sudo para uma auditoria conclusiva."
    printf '%s\n' "$output" | grep -Ei 'permission denied|permiss[aã]o negada' | log_stream | head -n 20
    return "$RC_WARN"
  fi

  # Filtrar falsos positivos
  filtered="$(printf '%s\n' "$output" | pacman_qk_filter_noise "${_pacman_health_noise[@]}")"
  noise_count=$(( $(printf '%s\n' "$output" | grep -c '[^[:space:]]' || true) - $(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true) ))

  if [[ -z "${filtered//[[:space:]]/}" ]]; then
    log "  ${check_cmd_label}: apenas falsos positivos conhecidos (${noise_count} ignorados)."
    return 0
  fi

  count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
  local noise_note=""
  (( noise_count > 0 )) && noise_note=" (+ ${noise_count} falso(s) positivo(s) filtrado(s))"
  log "  ${check_cmd_label}: ${count} arquivo(s)/pacote(s) com problema${noise_note} (mostrando até 60):"
  printf '%s\n' "$filtered" | grep '[^[:space:]]' | log_stream | head -n 60
  if (( count > 60 )); then
    log "  Saída completa registrada no log."
  fi
  STEP_REASON="${count} arquivo(s)/pacote(s) com problema via ${check_cmd_label}${noise_note}"
  return "$RC_TODO"
}



# G2/N1 — helper puro: conta pacotes afetados na saída do `arch-audit`. Aceita o
# formato MODERNO ("<pkg> is affected by <tipo>. <risco> risk!") e o ANTIGO
# ("Package <pkg> is affected by ..."). O parser antigo exigia o prefixo "Package"
# e o marcador "Update to", ambos ausentes no arch-audit atual — fazia o step
# reportar "Sem CVEs" mesmo com dezenas de pacotes afetados. Lê stdin; imprime o
# total (inteiro). A classificação corrigível×sem-correção vem do flag `-u` do
# próprio arch-audit (ver doctor_arch_audit_cves), não mais de regex no texto.
arch_audit_affected_count() {
  grep -cE 'is affected by' || true
}


# G2/N1 — CVEs de pacotes oficiais via arch-audit, no fluxo padrão (read-only).
# Sem arch-audit, o run_step pula via cmd_deps do catálogo.
#  • corrigíveis (já há versão corrigida nos repos, via `arch-audit -u`) → RC_WARN
#    acionável (`pacman -Syu`);
#  • apenas sem correção upstream → informativo (return 0): como os CVEs de
#    toolchain Rust (K3), não há ação local e todo sistema Arch atualizado tem
#    alguns — não vira todo/warn recorrente. A contagem é exibida (visibilidade);
#    o `--audit` consolidado lista os pacotes para revisão de segurança;
#  • nenhuma → 0. Falha de rede ao consultar o tracker → RC_WARN.
doctor_arch_audit_cves() {
  if ! has arch-audit; then
    log "  arch-audit não instalado; pulando."
    return 0
  fi

  local out rc netre total fixable manual
  netre='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'
  out="$(arch-audit 2>&1)"
  rc=$?
  if (( rc != 0 )) && grep -qiE "$netre" <<<"$out"; then
    log "  arch-audit: falha de rede ao consultar o tracker de segurança."
    STEP_REASON="rede indisponível para arch-audit"
    return "$RC_WARN"
  fi
  log_raw "$out"

  total="$(printf '%s\n' "$out" | arch_audit_affected_count)"
  total="${total:-0}"
  if (( total == 0 )); then
    log "  Sem CVEs conhecidas em pacotes oficiais (arch-audit)."
    return 0
  fi

  # Corrigíveis = pacotes que já têm versão corrigida nos repos. `arch-audit -u`
  # ("show only packages that have already been fixed") é a fonte robusta — não
  # depende do texto da saída padrão. Segunda consulta ao tracker; se falhar,
  # cai para 0 (trata tudo como sem-correção) em vez de quebrar o step.
  fixable="$(arch-audit -u --quiet 2>/dev/null | grep -cE '.' || true)"
  fixable="${fixable:-0}"
  (( fixable > total )) && fixable="$total"
  manual=$(( total - fixable ))

  if (( fixable > 0 )); then
    log "  ${C_YELLOW}arch-audit: ${fixable} pacote(s) com CVE já corrigível nos repos.${C_RESET}"
    log "  Remediação: sudo pacman -Syu"
    (( manual > 0 )) && log "  ${C_DIM}+ ${manual} sem correção upstream ainda (informativo).${C_RESET}"
    STEP_REASON="arch-audit: ${fixable} corrigível(is), ${manual} sem correção"
    return "$RC_WARN"
  fi

  log "  ${total} pacote(s) com CVE conhecida — todos sem correção upstream disponível ainda; não acionável localmente (informativo). Veja \`full-upgrade --audit\` para a lista."
  STEP_REASON="arch-audit: ${total} sem correção (informativo)"
  return 0
}



# I2 — localiza arquivos .pacnew/.pacsave nos diretórios dados (um por linha).
# Isolado p/ testes (stub). Silencioso em erros de permissão.
pacfiles_find() {
  find "$@" -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null
}


# I2 — reporta arquivos .pacnew/.pacsave pendentes (configs novas/antigas geradas
# pelo pacman que precisam ser mescladas manualmente). Read-only: lista e sugere
# `pacdiff`. RC_TODO se houver pendências; 0 caso contrário. Inspirado no
# arch-update. Diretórios via PACFILES_DIRS (default "/etc /boot").
doctor_pacfiles() {
  local dirs="${PACFILES_DIRS:-/etc /boot}"
  local -a pacf=()
  # shellcheck disable=SC2086  # split intencional de PACFILES_DIRS
  mapfile -t pacf < <(pacfiles_find $dirs | grep -v '^[[:space:]]*$')

  if (( ${#pacf[@]} == 0 )); then
    log "  Sem arquivos .pacnew/.pacsave pendentes."
    return 0
  fi

  if pacfiles_todo_already_reported; then
    log "  ${#pacf[@]} arquivo(s) .pacnew/.pacsave pendente(s) já reportado(s) na verificação final."
    STEP_REASON="pacfiles já reportados pela verificação final"
    return 0
  fi

  log "  ${C_YELLOW}${#pacf[@]} arquivo(s) .pacnew/.pacsave pendente(s):${C_RESET}"
  local f shown=0
  for f in "${pacf[@]}"; do
    if (( shown < 20 )); then
      log "    • ${f}"
      shown=$((shown + 1))
    fi
  done
  (( ${#pacf[@]} > 20 )) && log "    … e mais $(( ${#pacf[@]} - 20 ))."
  if has pacdiff; then
    log "  Remediação: revise/mescle com 'sudo pacdiff' (ou 'pacdiff -o' para listar)."
  else
    log "  Remediação: instale 'pacman-contrib' e rode 'sudo pacdiff'."
  fi
  STEP_REASON="${#pacf[@]} .pacnew/.pacsave pendente(s) — rode pacdiff"
  return "$RC_TODO"
}



doctor_pacman_hooks() {
  if ! has journalctl; then
    log "  journalctl não encontrado; não é possível auditar hooks ALPM."
    return 0
  fi

  local boot_id
  boot_id="$(journalctl --list-boots --no-pager 2>/dev/null | awk 'NR==1{print $2}' || true)"
  [[ -z "$boot_id" ]] && boot_id="-b"

  local failed_hooks
  failed_hooks="$(journalctl -b "${boot_id}" -p err -g 'ALPM-scriptlet|alpm-hook' --no-pager --output=short-monotonic 2>/dev/null | grep -v '^$' || true)"

  if [[ -z "${failed_hooks//[[:space:]]/}" ]]; then
    log "  Nenhum hook ALPM com falha registrado no boot atual."
    return 0
  fi

  local count
  count="$(printf '%s\n' "$failed_hooks" | grep -c '[^[:space:]]' || true)"
  log "  ${count} mensagem(ns) de erro em hooks ALPM no boot atual (mostrando até 20):"
  printf '%s\n' "$failed_hooks" | head -n 20 | log_stream
  (( count > 20 )) && log "  Saída completa registrada no log."
  STEP_REASON="${count} erro(s) em hook(s) ALPM no boot atual"
  return "$RC_TODO"
}
