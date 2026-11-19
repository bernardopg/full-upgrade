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
go_tool_module() {
  local info module modver
  info="$(go version -m "$1" 2>/dev/null)" || return 1
  module="$(awk '$1=="path"{print $2; exit}' <<<"$info")"
  modver="$(awk '$1=="mod"{print $3; exit}' <<<"$info")"
  [[ -n "$module" && "${module%%/*}" == *.* && -n "$modver" && "$modver" != "(devel)" ]] || return 1
  printf '%s' "$module"
}

# Decide se o binário Go ($1) precisa de `go install @latest`. Reinstalar as 9
# ferramentas em todo run levava 46s com nada novo. Precisa quando: a última
# versão do módulo (`go list -m mod@latest`, via GOPROXY, ~0,2s) difere da
# gravada no binário; ou a toolchain mudou (o rebuild traz as correções da
# stdlib); ou a última versão não pôde ser consultada (na dúvida, reinstala).
# rc 0 = reinstalar · 1 = já atual.
go_tool_needs_update() {
  local info modpath modver built cur latest
  info="$(go version -m "$1" 2>/dev/null)" || return 0
  modpath="$(awk '$1=="mod"{print $2; exit}' <<<"$info")"
  modver="$(awk '$1=="mod"{print $3; exit}' <<<"$info")"
  built="$(awk 'NR==1{print $2; exit}' <<<"$info")"
  built="${built%%-*}"
  [[ -n "$modpath" && -n "$modver" ]] || return 0
  cur="$(go env GOVERSION 2>/dev/null)"
  cur="${cur%%-*}"   # "go1.27.4-X:nodwarf5" → go1.27.4 (sufixo de GOEXPERIMENT)
  [[ -n "$cur" && -n "$built" && "$built" != "$cur" ]] && return 0
  latest="$(cd "${TMPDIR:-/tmp}" && GOWORK=off GOFLAGS=-mod=mod go list -m -f '{{.Version}}' "${modpath}@latest" 2>/dev/null)"
  [[ -n "$latest" && "$latest" == "$modver" ]] && return 1
  return 0
}

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
  local bin module dir
  for dir in "${dirs[@]}"; do
    for bin in "$dir"/*; do
      [[ -f "$bin" && -x "$bin" && ! -L "$bin" ]] || continue
      module="$(go_tool_module "$bin")" || continue
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

  local -a failed=() updated=() current=()
  local before_sum after_sum mod_path
  for module in "${modules[@]}"; do
    mod_path="${mod_to_bin[$module]}"
    if ! go_tool_needs_update "$mod_path"; then
      current+=("$(basename "$mod_path")")
      continue
    fi
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

  ((${#current[@]} > 0)) && log "  Go tools já na última versão (sem reinstalar): ${current[*]}"
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
    # kcov-excl-start (programa embutido, não é Bash)
    !segundo { if ($0 ~ /\(/) arch[$1] = 1; next }   # não NR == FNR: falha com o 1º arquivo vazio
    $0 ~ /\(/ { if (!($1 in arch)) print $1 }
  ' "$arch" segundo=1 "$outdated"
  # kcov-excl-stop
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


# ── mise (ferramentas gerenciadas) ─────────────────────────────────────────────
# O pacote mise atualiza o binário; as ferramentas que ele instala (node, php,
# python… em ~/.local/share/mise/installs) só sobem com `mise upgrade`. O
# upgrade respeita o intervalo do config (node = "24" => último 24.x); subir de
# major (--bump) reescreve o mise.toml e fica com o usuário. A versão antiga sai
# depois do upgrade.prune_after do próprio mise, nunca na mão.
# Tudo roda a partir de $HOME: um mise.toml de projeto no cwd do run mudaria o
# escopo para as ferramentas daquele projeto. Plugins asdf/vfox (não-core) vivem
# em clones git e são renovados antes, porque definem a lista de versões.

# Puro: "ferramenta atual → última" por linha, do JSON de `mise outdated --json`.
# rc != 0 quando o JSON não parseia (o chamador cai para o upgrade completo).
mise_outdated_summary() {
  local fmt='to_entries[] | "\(.key) \(.value.current // "?") → \(.value.latest // "?")"'
  jq -er "$fmt" <<<"$1" 2>/dev/null && return 0
  jq -e 'type == "object" and length == 0' <<<"$1" >/dev/null 2>&1
}

update_mise_tools() {
  local plugins out rc errf json summary
  plugins="$(cd "$HOME" && mise plugins ls 2>/dev/null)"
  if [[ -n "$plugins" ]]; then
    log "  Atualizando plugins do mise: $(tr '\n' ' ' <<<"$plugins")"
    out="$(cd "$HOME" && run_network_cmd mise plugins update)"
    rc=$?
    printf '%s\n' "$out" | _strip_ansi | grep -v '^[[:space:]]*$' | tail -n 5 | log_stream
    ((rc == 0)) || log "  Aviso: mise plugins update falhou (rc=${rc}); seguindo com as ferramentas."
  fi

  errf="$(mktemp)" || return "$RC_WARN"
  json="$(cd "$HOME" && mise outdated --json 2>"$errf")"
  rc=$?
  if ((rc != 0)); then
    log_raw "$(<"$errf")"
    if grep -qiE "$NETWORK_TRANSIENT_RE" "$errf"; then
      rm -f -- "$errf"
      STEP_REASON="mise outdated: rede indisponível"
      return "$RC_WARN"
    fi
  fi
  rm -f -- "$errf"

  # Atalho só quando dá para PROVAR que nada mudou: JSON válido e vazio.
  if summary="$(mise_outdated_summary "$json")"; then
    if [[ -z "$summary" ]]; then
      log "  Ferramentas do mise já estão nas últimas versões do intervalo configurado."
      return 0
    fi
    printf '%s\n' "$summary" | log_stream
  else
    log "  Não foi possível ler 'mise outdated' (rc=${rc}); rodando o upgrade completo."
  fi

  out="$(cd "$HOME" && run_network_cmd env MISE_YES=1 mise upgrade)"
  rc=$?
  # Sem TTY o mise ainda imprime o progresso do download a cada 3s: fica só o resultado.
  printf '%s\n' "$out" | _strip_ansi | grep -vE '^[[:space:]]*$|(downloading|extracting) [0-9.]+s|[█░]' | tail -n 15 | log_stream
  ((rc == 0)) && return 0
  if ((rc == RC_WARN)); then
    STEP_REASON="mise upgrade: rede indisponível"
    return "$RC_WARN"
  fi
  STEP_REASON="mise upgrade falhou (rc=${rc})"
  return 1
}


# ── ESP-IDF instalado pelo EIM ──────────────────────────────────────────────────
# O Espressif Installation Manager (EIM) põe cada versão do ESP-IDF em
# ~/.espressif/vX.Y.Z e nunca avisa de patch novo. Só leitura: patch novo na
# mesma série vira todo com o comando; série nova só é informada (migrar de
# série muda APIs e é decisão do projeto). Índice: idf_versions.json oficial.
ESP_IDF_VERSIONS_URL="${ESP_IDF_VERSIONS_URL:-https://dl.espressif.com/dl/esp-idf/idf_versions.json}"

esp_idf_installed() {
  local root="${IDF_TOOLS_PATH:-$HOME/.espressif}" d
  [[ -d "$root" ]] || return 0
  for d in "$root"/v[0-9]*/; do
    [[ -d "$d" ]] && basename "$d"
  done | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V
  return 0
}

# Puro: versões vX.Y.Z publicadas (sem pré-release) de um idf_versions.json.
esp_idf_published() {
  jq -r '.VERSIONS[].name' <<<"$1" 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V
}

# Puro: maior versão publicada na série de $1 (vX.Y[.Z]) dentre $2 (lista).
esp_idf_latest_in_series() {
  local series
  series="$(sed -E 's/^(v[0-9]+\.[0-9]+).*/\1/' <<<"$1")"
  grep -E "^${series//./\\.}(\.[0-9]+)?$" <<<"$2" | sort -V | tail -1
}

# Puro: da lista ordenada (sort -V) de versões instaladas, a maior de cada série
# vX.Y. Com v6.0.1 e v6.0.3 lado a lado (o EIM instala o patch novo ao lado do
# antigo), só a v6.0.3 conta: medir a v6.0.1 deixava o step em todo para sempre
# mesmo com o patch já instalado.
esp_idf_series_heads() {
  awk '{ s = $0; sub(/^v/, "", s); split(s, p, "."); head[p[1] "." p[2]] = $0; order[p[1] "." p[2]] = NR }
       END { for (k in head) print order[k], head[k] }' <<<"$1" | sort -n | cut -d' ' -f2-
}

# Caminho do EIM CLI: o do PATH ou o `eimPath` do eim_idf.json. A instalação
# pela GUI deixa o binário em ~/.espressif/eim_gui/eim, fora do PATH, e a
# remediação `eim install` não rodava como estava escrita.
esp_idf_eim_bin() {
  local json="${IDF_TOOLS_PATH:-$HOME/.espressif/tools}/eim_idf.json" alt=""
  [[ -r "$json" ]] && alt="$(jq -r '.eimPath // empty' "$json" 2>/dev/null || true)"
  manual_bin_path eim ${alt:+"$alt"}
}

check_esp_idf() {
  local json published v latest newest eim
  local -a pending=()
  local -a superseded=()
  local -a installed=()
  local -a all=()
  mapfile -t all <<<"$(esp_idf_installed)"
  [[ -n "${all[0]:-}" ]] || { log "  Nenhum ESP-IDF instalado pelo EIM."; return 0; }
  mapfile -t installed <<<"$(esp_idf_series_heads "$(printf '%s\n' "${all[@]}")")"
  for v in "${all[@]}"; do
    array_contains "$v" "${installed[@]}" || superseded+=("$v")
  done
  json="$(fetch_network_text --connect-timeout 10 --max-time 30 "$ESP_IDF_VERSIONS_URL")" || {
    STEP_REASON="índice de versões do ESP-IDF indisponível"
    return "$RC_WARN"
  }
  published="$(esp_idf_published "$json")"
  [[ -n "$published" ]] || { STEP_REASON="índice do ESP-IDF sem versões"; return "$RC_WARN"; }
  newest="$(tail -1 <<<"$published")"
  for v in "${installed[@]}"; do
    latest="$(esp_idf_latest_in_series "$v" "$published")"
    if [[ -n "$latest" ]] && version_is_outdated "${v#v}" "${latest#v}"; then
      pending+=("$latest")
      log "  ESP-IDF ${v}: patch ${latest} disponível na mesma série."
    else
      log "  ESP-IDF ${v}: em dia na série."
    fi
  done
  version_is_outdated "${installed[-1]#v}" "${newest#v}" \
    && log "  Série mais nova publicada: ${newest} (migração é decisão do projeto)."
  if ((${#superseded[@]} > 0)); then
    log "  Superadas por um patch mais novo da mesma série: ${superseded[*]} (libere espaço com: eim remove <versão>)."
  fi
  ((${#pending[@]} == 0)) && return 0
  eim="$(esp_idf_eim_bin)"
  if [[ -n "$eim" ]]; then
    remediation "${eim} install -i ${pending[*]}  # depois: ${eim} remove <versão antiga>"
  else
    remediation "eim install -i ${pending[*]}  # EIM CLI fora do PATH: instale o eim-cli ou use a GUI do EIM"
  fi
  STEP_REASON="ESP-IDF: patch novo na série instalada (${pending[*]})"
  return "$RC_TODO"
}


# ── Gerenciadores de toolchain: juliaup, elan, coursier, SDKMAN! ────────────────
# Mesmo molde do rustup/ghcup: instalados por script no $HOME, cada um atualiza
# o próprio binário e os toolchains só a pedido. Do SDKMAN! só o próprio sdk e
# a lista de candidatos são atualizados; `sdk upgrade` pode trocar a major do
# Java e fica com o usuário.
toolchain_managers() {
  has juliaup && printf 'juliaup\n'
  has elan && printf 'elan\n'
  has cs && printf 'coursier\n'
  [[ -f "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh" ]] && printf 'sdkman\n'
  return 0
}

# O binário instalado por pacote não tem self-update (o pacman cuida dele).
_toolchain_self_managed() { [[ "$(readlink -f "$(type -P "$1")")" == "$HOME"/* ]]; }

update_toolchain_managers() {
  local m rc worst=0
  local -a mgrs=()
  mapfile -t mgrs <<<"$(toolchain_managers)"
  [[ -n "${mgrs[0]:-}" ]] || { log "  Nenhum gerenciador de toolchain (juliaup, elan, coursier, SDKMAN!)."; return 0; }
  for m in "${mgrs[@]}"; do
    log "  ${m}:"
    rc=0
    case "$m" in
      juliaup)
        _toolchain_self_managed juliaup && { _native_update "juliaup self update" juliaup self update || rc=$?; }
        ((rc == 0)) && { _native_update "juliaup update" juliaup update || rc=$?; }
        ;;
      elan)
        _toolchain_self_managed elan && { _native_update "elan self update" elan self update || rc=$?; }
        ((rc == 0)) && { _native_update "elan update" elan update || rc=$?; }
        ;;
      coursier) _native_update "cs update" cs update || rc=$? ;;
      sdkman)
        _native_update "sdk selfupdate" bash -c 'export sdkman_auto_answer=true sdkman_auto_selfupdate=false; source "${SDKMAN_DIR:-$HOME/.sdkman}/bin/sdkman-init.sh" && sdk selfupdate && sdk update' || rc=$?
        ;;
    esac
    ((rc == 1 || (worst != 1 && rc > worst))) && worst=$rc
  done
  return "$worst"
}


# ── Pacotes globais do Composer ─────────────────────────────────────────────────
# `composer global require` instala ferramentas PHP (laravel/installer,
# phpstan…) num projeto global que nenhum gerenciador atualiza.
composer_global_json() {
  local home
  home="$(composer global config home --quiet 2>/dev/null)" || return 0
  [[ -f "${home}/composer.json" ]] && printf '%s\n' "${home}/composer.json"
  return 0
}

update_composer_global() {
  _native_update "composer global update" composer global update --no-interaction --no-progress
}
