#!/usr/bin/env bash
# steps/lang_other.sh — go, dotnet, gcloud, gem, ghcup, arduino
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

update_go_tools() {
  local gopath
  gopath="$(go env GOPATH 2>/dev/null || true)"
  if [[ -z "$gopath" || ! -d "$gopath/bin" ]]; then
    log "  GOPATH/bin não encontrado; sem ferramentas Go para atualizar."
    return 0
  fi

  local -A seen=()        # module path → 1
  local -A mod_to_bin=()  # module path → bin path (para capturar before_sum do bin real)
  local -a modules=()
  local bin module
  for bin in "$gopath"/bin/*; do
    [[ -x "$bin" ]] || continue
    module="$(go version -m "$bin" 2>/dev/null | awk '$1=="path"{print $2; exit}')"
    [[ -n "$module" ]] || continue
    if [[ -z "${seen[$module]+x}" ]]; then
      seen[$module]=1
      mod_to_bin[$module]="$bin"
      modules+=("$module")
    fi
  done

  if (( ${#modules[@]} == 0 )); then
    log "  Sem módulos Go identificados para atualizar."
    return 0
  fi

  local -a failed=() updated=()
  local before_sum after_sum mod_path
  for module in "${modules[@]}"; do
    mod_path="${mod_to_bin[$module]}"
    before_sum="$(go version -m "$mod_path" 2>/dev/null | awk '$1=="mod"{print $3}' || true)"
    log "  Atualizando Go tool: ${module}@latest"
    if ! run_logged go install "${module}@latest"; then
      failed+=("$module"); continue
    fi
    after_sum="$(go version -m "$mod_path" 2>/dev/null | awk '$1=="mod"{print $3}' || true)"
    if [[ -n "$before_sum" && "$before_sum" != "$after_sum" ]]; then
      updated+=("$(basename "$mod_path") ${before_sum}→${after_sum}")
    fi
  done

  local total_ok=$(( ${#modules[@]} - ${#failed[@]} ))
  if (( ${#updated[@]} > 0 )); then
    log "  Go tools: ${total_ok}/${#modules[@]} ok — versões novas: ${updated[*]}."
  else
    log "  Go tools: ${total_ok}/${#modules[@]} ok — todos já na versão mais recente."
  fi

  if (( ${#failed[@]} > 0 )); then
    log "  Falha ao atualizar módulo(s) Go: ${failed[*]}"
    return 1
  fi

  return 0
}


update_dotnet_tools() {
  local -a tools=()
  local -a failed=()
  local tool

  mapfile -t tools < <(dotnet tool list -g 2>/dev/null | tail -n +3 | awk 'NF >= 1 {print $1}')

  if (( ${#tools[@]} == 0 )); then
    log "  Sem ferramentas .NET globais instaladas."
    return 0
  fi

  log "  Ferramentas .NET globais: ${tools[*]}"
  local any_fail=0
  for tool in "${tools[@]}"; do
    [[ -n "$tool" ]] || continue
    log "  Atualizando .NET tool: ${tool}"
    local _out _rc
    _out="$(dotnet tool update -g "$tool" 2>&1)"
    _rc=$?
    log_raw "$_out"
    if (( _rc == 0 )); then
      printf '%s\n' "$_out" | grep -v '^$' || true
    elif printf '%s\n' "$_out" | grep -qi "is already the latest version\|já está na versão mais recente\|No packages installed were updated\|No se actualizaron"; then
      log "  ${tool}: já na versão mais recente."
    else
      log "  ERRO ao atualizar ${tool}:"
      printf '%s\n' "$_out" | grep -v '^$' || true
      any_fail=1
    fi
  done

  return "$any_fail"
}


update_gcloud() {
  local output rc
  output="$(_retry 2 "${GCLOUD_BIN:-gcloud}" components update --quiet 2>&1)"
  rc=$?
  log_raw "$output"
  (( rc == RC_WARN )) && { log "  gcloud: falha de rede transitória após 2 tentativas."; return "$RC_WARN"; }
  printf '%s\n' "$output" | grep -v '^Beginning update\.' || true
  return "$rc"
}


update_gem_user() {
  local gem_home gem_user_dir
  gem_home="$(gem env home 2>/dev/null || true)"
  gem_user_dir="$(gem env user_gemhome 2>/dev/null || true)"

  if [[ -z "$gem_home" ]]; then
    log "  Não foi possivel determinar GEM_HOME."
    return 1
  fi

  # Gems de sistema (Arch): não atualizar — gerenciadas pelo pacman
  if [[ "$gem_home" != "$HOME"* ]]; then
    local sys_count
    sys_count="$(gem list 2>/dev/null | grep -c '[^[:space:]]' || true)"
    log "  GEM_HOME em caminho de sistema (${gem_home}) — ${sys_count} gem(s) gerenciada(s) pelo Arch. Use pacman para atualizá-las."
    # Tentar gems de usuário em user_gemhome se existir
    if [[ -n "$gem_user_dir" && "$gem_user_dir" == "$HOME"* && -d "$gem_user_dir" ]]; then
      log "  Detectado GEM_USER_HOME do usuário: ${gem_user_dir}"
      local outdated_user
      outdated_user="$(GEM_HOME="$gem_user_dir" gem outdated 2>/dev/null || true)"
      if [[ -z "${outdated_user//[[:space:]]/}" ]]; then
        log "  Gems do usuário: todas atualizadas."
      else
        log "  Gems do usuário desatualizadas:"
        printf '%s\n' "$outdated_user" | tee >(_strip_ansi >> "$LOG_FILE")
        GEM_HOME="$gem_user_dir" run_logged gem update
      fi
    fi
    return 0
  fi

  local outdated
  outdated="$(gem outdated 2>/dev/null || true)"
  if [[ -z "${outdated//[[:space:]]/}" ]]; then
    log "  Sem gems desatualizadas."
    return 0
  fi

  log "  Gems desatualizadas:"
  printf '%s\n' "$outdated" | tee >(_strip_ansi >> "$LOG_FILE")
  # rdoc/rake/rubygems-update podem gerar conflito com versão do Arch — ignorar erros não-fatais
  run_logged gem update || log "  Aviso: gem update retornou erro (possível conflito rdoc/rake com pacman — inofensivo)."
}


update_ghcup() {
  local output rc
  output="$(ghcup upgrade 2>&1)"
  rc=$?
  log_raw "$output"
  printf '%s\n' "$output" | grep -E '^\[' || true
  return "$rc"
}


update_arduino() {
  if ! has arduino-cli; then
    log "  arduino-cli não encontrado."
    return 0
  fi

  log "  Atualizando índices de cores e bibliotecas..."
  local idx_output rc_idx
  idx_output="$(arduino-cli update 2>&1)"
  rc_idx=$?
  log_raw "$idx_output"
  # suprimir linhas de progresso (Downloading... X%)
  printf '%s\n' "$idx_output" | grep -v 'Downloading\|0 B /' || true

  log "  Atualizando cores e bibliotecas instaladas..."
  local upg_output rc_upg
  upg_output="$(arduino-cli upgrade 2>&1)"
  rc_upg=$?
  printf '%s\n' "$upg_output" | tee >(_strip_ansi >> "$LOG_FILE")

  if (( rc_idx != 0 || rc_upg != 0 )); then return 1; fi

  # Verificar se ainda há libs atualizáveis
  local updatable
  updatable="$(arduino-cli lib list --updatable 2>/dev/null | tail -n +2 | wc -l || true)"
  if (( updatable > 0 )); then
    log "  ${C_YELLOW}Aviso: ${updatable} biblioteca(s) Arduino ainda atualizável(eis) após upgrade.${C_RESET}"
  else
    log "  Cores e bibliotecas Arduino: todos atualizados."
  fi

  return 0
}


