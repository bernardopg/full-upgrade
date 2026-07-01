#!/usr/bin/env bash
# steps/lang_other.sh — go, dotnet, gcloud, gem, ghcup, arduino
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module (STEP_REASON etc.)

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
      if [[ -z "${outdated_user//[[:space:]]/}" ]]; then
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
          printf '%s\n' "$outdated_user" | tee >(_strip_ansi >> "$LOG_FILE")
          log "  Atualizando ${#updatable[@]} gem(s) próprias do usuário (excluídas as do Arch): ${updatable[*]}"
          GEM_HOME="$gem_user_dir" run_logged gem update "${updatable[@]}"
        fi
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


# N3 — helper puro: dado o `gem list` do sistema ($1) e o do usuário ($2),
# emite as gems que o usuário SOMBREIA com versão divergente. Considera só as
# versões REAIS (instaladas) — entradas "default: X" (gems bundled do Ruby) são
# ignoradas, pois existem em ambos e upgrades de usuário nelas são normais. Uma
# linha por gem: "nome|versões_reais_sistema|versões_reais_usuário". Flag quando
# o sistema tem versão real (gem do Arch) e o usuário tem alguma real ausente nela.
# Read-only. Formato de entrada (gem list): "nome (1.2.3, 1.0.0, default: 0.9)".
gem_shadow_diff() {
  local sys="$1" usr="$2"
  [[ -r "$sys" && -r "$usr" ]] || return 0
  awk '
    function gname(line,   name) { name = line; sub(/ *\(.*/, "", name); return name }
    function realvers(line,   vers, n, parts, i, p, out) {
      if (line !~ /\(/) return ""
      vers = line; sub(/^[^(]*\(/, "", vers); sub(/\).*/, "", vers)
      n = split(vers, parts, ",")
      out = ""
      for (i = 1; i <= n; i++) {
        p = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", p)
        if (p == "" || p ~ /^default:/) continue
        out = (out == "") ? p : out " " p
      }
      return out
    }
    NR == FNR { if ($0 ~ /\(/) sysv[gname($0)] = realvers($0); next }
    {
      if ($0 !~ /\(/) next
      name = gname($0)
      if (!(name in sysv) || sysv[name] == "") next   # sistema sem versão real => ignora
      uv = realvers($0)
      if (uv == "") next                               # usuário só tem default => ignora
      nn = split(uv, U, " "); diff = 0
      for (i = 1; i <= nn && !diff; i++) {
        found = 0; mm = split(sysv[name], S, " ")
        for (j = 1; j <= mm; j++) if (U[i] == S[j]) { found = 1; break }
        if (!found) diff = 1
      }
      if (diff) print name "|" sysv[name] "|" uv
    }
  ' "$sys" "$usr"
}

# N3 — Doctor read-only: gems instaladas pelo USUÁRIO que sombreiam uma gem real
# do sistema (Arch) com versão divergente — ex.: rdoc 7.2.0 (user) sobre 6.14.0
# (Arch), que faz toda invocação ruby carregar a do usuário e despejar
# "already initialized constant". Gems default do Ruby são ignoradas. Sem gem =>
# skip via catálogo. Acionável (`gem uninstall --user-install`) => RC_TODO.
doctor_gem_shadow() {
  has gem || { log "  gem não disponível; pulando."; return 0; }
  local sys_home usr_home
  sys_home="$(gem env home 2>/dev/null || true)"
  usr_home="$(gem env user_gemhome 2>/dev/null || true)"
  if [[ -z "$sys_home" || "$sys_home" == "$HOME"* || -z "$usr_home" || ! -d "$usr_home" ]]; then
    log "  Sem separação sistema/usuário de gems; nada a checar."
    return 0
  fi

  local sysf usrf
  sysf="$(mktemp)"; usrf="$(mktemp)"
  GEM_HOME="$sys_home" GEM_PATH="$sys_home" gem list --local 2>/dev/null > "$sysf"
  GEM_HOME="$usr_home" GEM_PATH="$usr_home" gem list --local 2>/dev/null > "$usrf"
  local -a shadow=()
  mapfile -t shadow < <(gem_shadow_diff "$sysf" "$usrf")
  rm -f "$sysf" "$usrf"

  if (( ${#shadow[@]} == 0 )); then
    log "  Sem gems do usuário sombreando gems do sistema (Arch)."
    return 0
  fi

  log "  ${C_YELLOW}${#shadow[@]} gem(s) do usuário sombreiam a versão do sistema (Arch):${C_RESET}"
  local line name sysv usrv shown=0
  for line in "${shadow[@]}"; do
    IFS='|' read -r name sysv usrv <<< "$line"
    if (( shown < 20 )); then
      log "    • ${name}: sistema ${sysv} vs usuário ${usrv}"
      shown=$((shown + 1))
    fi
  done
  (( ${#shadow[@]} > 20 )) && log "    … e mais $(( ${#shadow[@]} - 20 ))."
  log "  Dica: remova a cópia do usuário p/ usar a do Arch — gem uninstall --user-install <gem>"
  STEP_REASON="${#shadow[@]} gem(s) do usuário sombreando o sistema"
  return "$RC_TODO"
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

