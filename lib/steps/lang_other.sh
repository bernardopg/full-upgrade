#!/usr/bin/env bash
# steps/lang_other.sh — go, dotnet, gcloud, gem, ghcup, arduino
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module (STEP_REASON etc.)

# Binários `go install` vivem em GOPATH/bin, mas há quem instale com
# GOBIN=~/.local/bin (ex.: os *-pp-cli do printing-press); sem varrer esse
# diretório eles nunca eram atualizados. Cada módulo é reinstalado no mesmo
# diretório onde foi achado. Binário de `go build` local (path
# command-line-arguments ou mod "(devel)") ou de módulo privado não tem @latest
# e é ignorado.
update_go_tools() {
  local gopath
  gopath="$(go env GOPATH 2>/dev/null || true)"
  local -a dirs=()
  [[ -n "$gopath" && -d "$gopath/bin" ]] && dirs+=("$gopath/bin")
  [[ -d "${HOME}/.local/bin" ]] && dirs+=("${HOME}/.local/bin")
  if (( ${#dirs[@]} == 0 )); then
    log "  GOPATH/bin não encontrado; sem ferramentas Go para atualizar."
    return 0
  fi

  local -A seen=()        # module path → 1
  local -A mod_to_bin=()  # module path → bin path (para capturar before_sum do bin real)
  local -a modules=()
  local bin module dir info modver
  for dir in "${dirs[@]}"; do
    for bin in "$dir"/*; do
      [[ -f "$bin" && -x "$bin" && ! -L "$bin" ]] || continue
      info="$(go version -m "$bin" 2>/dev/null)" || continue
      module="$(awk '$1=="path"{print $2; exit}' <<<"$info")"
      modver="$(awk '$1=="mod"{print $3; exit}' <<<"$info")"
      # Sem ponto no primeiro elemento o path não é baixável (ex.: o gk da
      # GitKraken, compilado como "gkcli/cmd/installer-proxy").
      [[ -n "$module" && "${module%%/*}" == *.* ]] || continue
      [[ -n "$modver" && "$modver" != "(devel)" ]] || continue
      if [[ -z "${seen[$module]+x}" ]]; then
        seen[$module]=1
        mod_to_bin[$module]="$bin"
        modules+=("$module")
      fi
    done
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
    if ! run_logged env GOBIN="$(dirname "$mod_path")" go install "${module}@latest"; then
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

  # DOTNET_CLI_UI_LANGUAGE=en + LC_ALL=C: o dotnet É localizado; o tail -n +3
  # (header de 3 linhas) e os greps de status abaixo assumem saída em inglês.
  mapfile -t tools < <(DOTNET_CLI_UI_LANGUAGE=en LC_ALL=C dotnet tool list -g 2>/dev/null | tail -n +3 | awk 'NF >= 1 {print $1}')

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
    _out="$(DOTNET_CLI_UI_LANGUAGE=en LC_ALL=C dotnet tool update -g "$tool" 2>&1)"
    _rc=$?
    log_raw "$_out"
    if (( _rc == 0 )); then
      printf '%s\n' "$_out" | grep -v '^$' | log_out || true
    elif grep -qi "is already the latest version\|já está na versão mais recente\|No packages installed were updated\|No se actualizaron" <<<"$_out"; then
      log "  ${tool}: já na versão mais recente."
    else
      log "  ERRO ao atualizar ${tool}:"
      printf '%s\n' "$_out" | grep -v '^$' | log_out || true
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
  printf '%s\n' "$output" | grep -v '^Beginning update\.' | log_out || true
  return "$rc"
}



# N4 — helper puro: dado o `gem outdated` do usuário ($1) e o `gem list` do
# sistema/Arch ($2), emite os nomes de gems do usuário atualizáveis SEM sombrear
# o sistema — i.e., cujo nome NÃO é gerenciado pelo Arch. Evita que o
# `gem update` recrie o shadowing (rdoc/rake/etc.) a cada run. Uma por linha.
# Linhas sem "(...)" (cabeçalhos, vazias) são ignoradas; casa pelo 1º campo (nome).
gem_user_updatable() {
  local outdated="$1" arch="$2"
  [[ -r "$outdated" && -r "$arch" ]] || return 0
  awk '
    NR == FNR { if ($0 ~ /\(/) arch[$1] = 1; next }
    $0 ~ /\(/ { if (!($1 in arch)) print $1 }
  ' "$arch" "$outdated"
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
      if [[ $outdated_user != *[![:space:]]* ]]; then
        log "  Gems do usuário: todas atualizadas."
      else
        # N4: nunca atualizar gems que o Arch já gerencia — `gem update` puxaria
        # versões novas pro GEM_USER_HOME, sombreando a stdlib do sistema e
        # despejando "already initialized constant" (ver doctor_gem_shadow).
        local sysf upf
        sysf="$(mktemp)"; upf="$(mktemp)"
        GEM_HOME="$gem_home" GEM_PATH="$gem_home" gem list --local 2>/dev/null > "$sysf"
        printf '%s\n' "$outdated_user" > "$upf"
        local -a updatable=()
        mapfile -t updatable < <(gem_user_updatable "$upf" "$sysf")
        rm -f "$sysf" "$upf"

        if (( ${#updatable[@]} == 0 )); then
          local outdated_count
          outdated_count="$(printf '%s\n' "$outdated_user" | grep -c '[^[:space:]]' || true)"
          log "  Gems do usuário desatualizadas: ${outdated_count} — todas gerenciadas pelo Arch; pulando p/ não sombrear o sistema (lista completa no log)."
          log_raw "--- gem outdated (GEM_USER_HOME, Arch-managed; terminal resumido) ---"
          log_raw "$outdated_user"
        else
          log "  Gems do usuário desatualizadas:"
          printf '%s\n' "$outdated_user" | log_stream
          log "  Atualizando ${#updatable[@]} gem(s) próprias do usuário (excluídas as do Arch): ${updatable[*]}"
          GEM_HOME="$gem_user_dir" run_logged gem update "${updatable[@]}"
        fi
      fi
    fi
    return 0
  fi

  local outdated
  outdated="$(gem outdated 2>/dev/null || true)"
  if [[ $outdated != *[![:space:]]* ]]; then
    log "  Sem gems desatualizadas."
    return 0
  fi

  log "  Gems desatualizadas:"
  printf '%s\n' "$outdated" | log_stream
  # rdoc/rake/rubygems-update podem gerar conflito com versão do Arch — ignorar erros não-fatais
  run_logged gem update || log "  Aviso: gem update retornou erro (possível conflito rdoc/rake com pacman — inofensivo)."
}



update_ghcup() {
  local output rc
  output="$(ghcup upgrade 2>&1)"
  rc=$?
  log_raw "$output"
  printf '%s\n' "$output" | grep -E '^\[' | log_out || true
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
  printf '%s\n' "$upg_output" | log_stream

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
