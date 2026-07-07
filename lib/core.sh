#!/usr/bin/env bash
# lib/core.sh — helpers, logging, framework de steps (run_step)
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module setadas/usadas entre arquivos

has() {
  command -v "$1" >/dev/null 2>&1
}

# Dependência de comando do catálogo satisfeita?
# Aceita o comando no PATH ou um override <CMD>_BIN apontando para executável
# (ex.: GCLOUD_BIN p/ gcloud, OPENCLAW_BIN p/ openclaw) — o mesmo contrato que
# os gates de run_all_steps já honram; sem isso o dep check do catálogo pulava
# o step com "cmd-ausente" mesmo com o override configurado.
dep_satisfied() {
  local dep="$1"
  has "$dep" && return 0
  local ovr="${dep//[^a-zA-Z0-9]/_}"
  ovr="${ovr^^}_BIN"
  [[ -n "${!ovr:-}" && -x "${!ovr}" ]]
}

# Remove sequências de escape ANSI (cores/estilo) de stdin.
# Usado para manter o arquivo de log legível mesmo quando comandos externos
# (ex.: fwupdmgr) emitem escapes crus.
_strip_ansi() {
  # 1) remove sequências ANSI (cores/cursor);
  # 2) colapsa atualizações in-place via carriage return (\r) — barras de
  #    progresso do curl/wget reescrevem a mesma linha com \r e, sem isso,
  #    cada quadro vira uma linha gigante ilegível no log. Mantém só o
  #    último estado de cada linha (texto após o último \r).
  sed -E 's/\x1b\[[0-9;]*[mGKHfABCD]//g; s/.*\r([^\r])/\1/g; s/\r$//'
}

# Grava conteúdo SOMENTE no arquivo de log (não no terminal), removendo ANSI.
# Use para gravar a saída crua de comandos externos no log de auditoria, no
# lugar de 'printf ... >> "$LOG_FILE"', que preservaria escapes de cor.
log_raw() {
  local _lf="${LOG_FILE:-/dev/null}"
  [[ -z "$_lf" ]] && _lf="/dev/null"
  printf '%b\n' "$*" | _strip_ansi >> "$_lf"
}

# Mata uma árvore de processos (filhos primeiro, depois o pai) com o sinal dado.
# Usado pelo timeout de run_step: matar só o subshell deixaria os processos
# netos (paru, npm, nvim...) órfãos, rodando em paralelo com os steps seguintes.
_kill_tree() {
  local pid="$1" sig="${2:-TERM}" child
  local -a _children=()
  if has pgrep; then
    mapfile -t _children < <(pgrep -P "$pid" 2>/dev/null || true)
    for child in "${_children[@]}"; do
      [[ -n "$child" ]] && _kill_tree "$child" "$sig"
    done
  fi
  kill -s "$sig" "$pid" 2>/dev/null || true
}

add_skip_step() {
  local name="$1"
  if [[ -z "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]]; then
    FULL_UPGRADE_SKIP="$name"
  else
    FULL_UPGRADE_SKIP="${FULL_UPGRADE_SKIP},${name}"
  fi
}

skip_step_count() {
  local item
  local count=0
  local -a _skip_count_items=()
  [[ -z "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]] && { printf '0'; return 0; }
  IFS=',' read -ra _skip_count_items <<< "$FULL_UPGRADE_SKIP"
  for item in "${_skip_count_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && ((count++))
  done
  printf '%d' "$count"
}

log() {
  # Antes de setup_logging (ex.: --update), LOG_FILE ainda é vazio.
  local _lf="${LOG_FILE:-/dev/null}"
  [[ -z "$_lf" ]] && _lf="/dev/null"
  if (( QUIET )); then
    printf '%b\n' "$*" | _strip_ansi >> "$_lf"
  else
    printf '%b\n' "$*"                          # terminal: mantém cores
    printf '%b\n' "$*" | _strip_ansi >> "$_lf"  # arquivo: sem ANSI
  fi
}

# Sempre imprime no terminal (mesmo em --quiet): use para resumo e erros críticos.
log_always() {
  local _lf="${LOG_FILE:-/dev/null}"
  [[ -z "$_lf" ]] && _lf="/dev/null"
  printf '%b\n' "$*"                            # terminal: mantém cores
  printf '%b\n' "$*" | _strip_ansi >> "$_lf"    # arquivo: sem ANSI
}

run_logged() {
  if (( QUIET )); then
    "$@" > >(_strip_ansi >> "$LOG_FILE") 2>&1
  else
    # Terminal recebe saída com ruído de build allow-listed colapsado; arquivo
    # mantém a saída bruta sem ANSI para auditoria completa.
    "$@" 2>&1 | tee >(_strip_ansi >> "$LOG_FILE") | build_warning_filter
  fi
  return ${PIPESTATUS[0]}
}

remediation() {
  printf '  Remediação: %s\n' "$*"
}

_pacfiles_todo_marker_file() {
  [[ -n "${RUN_ID:-}" ]] || return 1
  printf '%s/full-upgrade-%s.pacfiles-todo' "${LOG_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/system-upgrade}" "$RUN_ID"
}

mark_pacfiles_todo_reported() {
  FULL_UPGRADE_PACFILES_TODO_REPORTED=1
  local marker
  marker="$(_pacfiles_todo_marker_file 2>/dev/null || true)"
  [[ -n "$marker" ]] || return 0
  mkdir -p "$(dirname "$marker")" 2>/dev/null || return 0
  : > "$marker" 2>/dev/null || true
}

pacfiles_todo_already_reported() {
  (( ${FULL_UPGRADE_PACFILES_TODO_REPORTED:-0} )) && return 0
  local marker
  marker="$(_pacfiles_todo_marker_file 2>/dev/null || true)"
  [[ -n "$marker" && -e "$marker" ]]
}

# Executa comando de rede; se falhar por DNS/conectividade retorna RC_WARN.
# Uso: run_network_cmd curl -sf https://example.com
run_network_cmd() {
  local _out _rc
  _out="$("$@" 2>&1)"
  _rc=$?
  printf '%s\n' "$_out"
  log_raw "$_out"
  if (( _rc != 0 )); then
    if printf '%s\n' "$_out" | grep -qiE "$NETWORK_TRANSIENT_RE"; then
      log "  Falha de rede transitória detectada (DNS/conectividade). Marcando como aviso."
      return "$RC_WARN"
    fi
  fi
  return "$_rc"
}

# Tenta comando N vezes com delay de 5s entre tentativas.
# Retorna RC_WARN (não fail) se toda tentativa falhar por erro de rede.
# Uso: _retry 2 cargo audit bin
_retry() {
  local n="$1"; shift
  local attempt out rc last_rc=1
  local _network_re="$NETWORK_TRANSIENT_RE"
  for (( attempt=1; attempt<=n; attempt++ )); do
    out="$("$@" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    log_raw "$out"
    if (( rc == 0 )); then
      return 0
    fi
    last_rc=$rc
    if (( attempt < n )); then
      log "  Tentativa ${attempt}/${n} falhou (rc=${rc}); aguardando 5s..."
      sleep 5
    fi
  done
  if printf '%s\n' "$out" | grep -qiE "$_network_re"; then
    log "  Todas as ${n} tentativas falharam por erro de rede — marcando como aviso."
    return "$RC_WARN"
  fi
  return "$last_rc"
}

aur_ignore_args() {
  local item
  [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]] || return 0

  for item in $FULL_UPGRADE_AUR_IGNORE; do
    [[ -n "$item" ]] || continue
    printf '%s\n' "--ignore=${item}"
  done
}

# Extrai pacotes AUR marcados pelo mantenedor como out-of-date da saída de
# helpers (paru/yay). Isso não significa update aplicável; é sinal informativo.
aur_out_of_date_pkgs() {
  sed -nE \
    -e 's/^.*marcado(s)? como desatualizado(s)?:[[:space:]]*//Ip' \
    -e 's/^.*marked (as )?out[- ]of[- ]date:[[:space:]]*//Ip' \
    -e 's/^.*flagged out[- ]of[- ]date:[[:space:]]*//Ip' \
    | tr '[:space:]' '\n' \
    | sed -E 's/^[[:punct:]]+//; s/[[:punct:]]+$//' \
    | grep -E '^[A-Za-z0-9@._+-]+$' \
    | sort -u
}

# ── Parsers puros (sem I/O; testáveis via bats) ────────────────────────────────

# Normaliza uma versão "vX.Y.Z" ou "X.Y.Z[-N-gHASH]" para "X.Y.Z".
normalize_version() {
  local v="$1"
  v="${v#v}"
  v="${v%%-*}"
  printf '%s' "$v"
}

# Compara duas versões semver. Imprime: 0 (iguais), 1 (a > b), 2 (a < b).
version_compare() {
  local a b
  a="$(normalize_version "$1")"
  b="$(normalize_version "$2")"

  [[ "$a" == "$b" ]] && { printf '0'; return 0; }

  local -a pa pb
  IFS='.' read -ra pa <<< "$a"
  IFS='.' read -ra pb <<< "$b"

  local i max=${#pa[@]}
  (( ${#pb[@]} > max )) && max=${#pb[@]}

  for (( i = 0; i < max; i++ )); do
    local na="${pa[i]:-0}" nb="${pb[i]:-0}"
    [[ "$na" =~ ^[0-9]+$ ]] || na=0
    [[ "$nb" =~ ^[0-9]+$ ]] || nb=0
    if (( na > nb )); then printf '1'; return 0; fi
    if (( na < nb )); then printf '2'; return 0; fi
  done
  printf '0'
}

version_is_outdated() {
  [[ "$(version_compare "$1" "$2")" == "2" ]]
}

build_warning_filter() {
  local suppressed=0 line
  while IFS= read -r line; do
    case "$line" in
      *SetuptoolsDeprecationWarning*|*'setup.py install is deprecated'*|*'already initialized constant RDoc::'*)
        ((suppressed++))
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
  if (( suppressed > 0 )); then
    printf '  %s warning(s) de build suprimido(s); veja o log completo.\n' "$suppressed"
  fi
}

# Lê a saída crua do `checkservices` em stdin e emite, uma por linha, apenas as
# units systemd que ele recomenda reiniciar (extraídas de "systemctl restart
# '<unit>'"), deduplicadas. Ignora contadores ("Found: N"), delimitadores
# ("---8<---"), avisos de pacnew e prompts. Saída vazia = nada a reiniciar.
parse_checkservices_units() {
  grep -oE "systemctl restart '[^']+'" \
    | sed -E "s/^systemctl restart '([^']+)'$/\1/" \
    | sort -u
}

# Lê a saída crua do `cargo audit bin` em stdin e emite, um por linha, o
# basename de cada binário com vulnerabilidade ("... found in /path/bin/<nome>"),
# deduplicado.
parse_cargo_vuln_bins() {
  grep -oiE 'vulnerabilit(y|ies) found in [^[:space:]]+' \
    | grep -oE '/[^[:space:]]+$' \
    | xargs -r -n1 basename 2>/dev/null \
    | sort -u
}

# Classifica um binário cargo: imprime "toolchain" (gerenciado por rustup/pacman,
# NÃO por `cargo install-update`) ou "cargo" (instalado via `cargo install`).
classify_cargo_bin() {
  case "$1" in
    rustup|cargo|rustc|rustfmt|cargo-clippy|clippy-driver|rust-*)
      printf 'toolchain' ;;
    *)
      printf 'cargo' ;;
  esac
}

# Mapeia o basename de um binário de $CARGO_HOME/bin para o crate que o
# instalou, lendo a saída de `cargo install --list` (passada como $2): linhas
# "crate vX.Y.Z:" seguidas dos binários indentados. Um crate pode instalar
# binários com nome diferente do seu (ex.: ripgrep → rg). Saída vazia se o
# binário não pertence a nenhum crate cargo-installed.
cargo_crate_for_bin() {
  local bin="$1" list="$2"
  printf '%s\n' "$list" | awk -v bin="$bin" '
    /^[^[:space:]]/ { crate = $1 }
    /^[[:space:]]/  { name = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
                      if (name == bin) { print crate; exit } }
  '
}

# Espaço suficiente? Recebe KiB disponíveis (coluna do `df -k`) e o mínimo em
# GiB. Retorna 0 (suficiente) se avail_kib >= min_gib*1048576, senão 1.
# Aritmética inteira pura — sem I/O, testável. min_gib<=0 sempre suficiente.
space_is_sufficient() {
  local avail_kib="$1" min_gib="$2"
  [[ "$avail_kib" =~ ^[0-9]+$ ]] || return 1
  [[ "$min_gib" =~ ^[0-9]+$ ]] || min_gib=0
  (( min_gib <= 0 )) && return 0
  (( avail_kib >= min_gib * 1048576 ))
}

# KiB disponíveis no filesystem que contém <path>. Emite o inteiro em stdout,
# vazio se não der pra determinar. Isola o I/O do `df` para o step testar a
# lógica via space_is_sufficient.
avail_kib_for_path() {
  local path="$1"
  df -Pk "$path" 2>/dev/null | awk 'NR==2 { print $4 }'
}

# Extrai o primeiro campo (hash hex) de uma linha no formato `sha256sum`
# ("<hash>  <arquivo>"). Aceita também uma linha só com o hash. Normaliza para
# minúsculas. Vazio se não parecer um hash SHA-256 (64 hex). Puro, testável.
parse_sha256_field() {
  local line="$1" hash
  hash="${line%%[[:space:]]*}"   # primeiro token
  hash="${hash,,}"               # minúsculas
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$hash"
}

# Calcula o SHA-256 de um arquivo, abstraindo o utilitário disponível
# (sha256sum no Linux, `shasum -a 256` como fallback). Emite o hash hex
# minúsculo, ou nada (rc≠0) se nenhum utilitário existir / arquivo ausente.
file_sha256() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local out
  if has sha256sum; then
    out="$(sha256sum -- "$f" 2>/dev/null)"
  elif has shasum; then
    out="$(shasum -a 256 -- "$f" 2>/dev/null)"
  else
    return 1
  fi
  parse_sha256_field "$out"
}

# Verifica que o SHA-256 de <arquivo> bate com <hash_esperado>.
# Retorna 0 se igual, 1 caso contrário (inclui erro de cálculo / hash inválido).
# Comparação case-insensitive. Sem efeitos colaterais além de ler o arquivo.
verify_sha256() {
  local file="$1" expected="$2" actual
  expected="$(parse_sha256_field "$expected" 2>/dev/null)" || return 1
  actual="$(file_sha256 "$file" 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]]
}

# Soma todos os contadores *_errs de uma saída de `btrfs device stats` (lida em
# stdin). Emite o total inteiro (0 se nenhum erro). Linhas têm o formato
# "[/dev/x].write_io_errs   0". Puro, testável.
sum_btrfs_dev_errors() {
  awk '
    /_errs/ {
      v = $NF
      if (v ~ /^[0-9]+$/) total += v
    }
    END { print total + 0 }
  '
}

# Converte uma duração estilo systemd ("1min 23.456s", "2min 5s", "45.6s",
# "1h 2min 3s") em segundos inteiros (arredonda pra baixo). Lê o texto de $1.
# Emite o inteiro; 0 se não casar nada. Puro, testável.
systemd_time_to_seconds() {
  local s="$1"
  awk -v str="$s" '
    BEGIN {
      total = 0
      n = split(str, toks, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        t = toks[i]
        if (t ~ /h$/)        { sub(/h$/, "", t);   total += t * 3600 }
        else if (t ~ /min$/) { sub(/min$/, "", t); total += t * 60 }
        else if (t ~ /ms$/)  { sub(/ms$/, "", t);  total += t / 1000 }
        else if (t ~ /s$/)   { sub(/s$/, "", t);   total += t }
      }
      printf "%d", total
    }'
}

elapsed() {
  local secs="$1"
  if (( secs >= 60 )); then
    printf '%dm %02ds' $((secs / 60)) $((secs % 60))
  else
    printf '%ds' "$secs"
  fi
}


_step_counter() {
  # número de steps executados, excluindo skips
  local count=0
  local r
  for r in "${STEP_RESULTS[@]}"; do
    [[ "$r" == "ok" || "$r" == "warn" || "$r" == "todo" || "$r" == "fail" ]] && ((count++))
  done
  printf '%d' "$count"
}

_step_skip_requested() {
  local name="$1"
  [[ -z "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]] && return 1
  local item
  IFS=',' read -ra _skip_items <<< "$FULL_UPGRADE_SKIP"
  for item in "${_skip_items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"  # ltrim
    item="${item%"${item##*[![:space:]]}"}"  # rtrim
    [[ "$item" == "$name" ]] && return 0
  done
  return 1
}

_ts() {
  # timestamp relativo MM:SS desde início do script
  local secs=$((SECONDS - TOTAL_START))
  printf '%02d:%02d' $((secs / 60)) $((secs % 60))
}

# Largura da coluna de nome p/ alinhar as linhas de status ao vivo. Memoizada:
# derivada do maior nome do catálogo (limitada a [24,50]), igual ao resumo, para
# que as durações/motivos fiquem numa coluna consistente em toda a execução.
STEP_NAME_W=0
_step_name_width() {
  if (( STEP_NAME_W == 0 )); then
    local w=0 n _rest l
    while IFS='|' read -r n _rest; do
      [[ -n "$n" ]] || continue
      l=${#n}; (( l > w )) && w=$l
    done < <(step_catalog)
    (( w > 50 )) && w=50
    (( w < 24 )) && w=24
    STEP_NAME_W=$w
  fi
  printf '%d' "$STEP_NAME_W"
}

# Resolve a categoria de um step pelo catálogo (vazio se não-catalogado).
_category_of() {
  local name="$1" category rest
  IFS='|' read -r category rest < <(catalog_info_for_step "$name")
  printf '%s' "$category"
}

# Imprime um cabeçalho de seção ao vivo quando o grupo do step muda em relação
# ao último impresso. Reaproveita o agrupamento do resumo (summary_group_specs)
# para que a execução fique visualmente dividida nos mesmos blocos do resumo.
_maybe_print_section() {
  local category="$1" group
  group="$(_group_label_for_category "$category")"
  [[ "$group" == "${LAST_SECTION_GROUP}" ]] && return 0
  LAST_SECTION_GROUP="$group"
  log ""
  log "${C_DIM}$(ui_hr "$HR_LIGHT")${C_RESET}"
  log "${C_BOLD}${C_CYAN}${SYM_ARROW}${SYM_ARROW} ${group}${C_RESET}"
}

step_start() {
  local name="$1"
  local _cat; _cat="$(_category_of "$name")"
  _maybe_print_section "$_cat"
  STEP_NAMES+=("$name")
  STEP_CATEGORIES+=("$_cat")
  STEP_START=$SECONDS
  STEP_START_ISO="$(date -Is)"
  STEP_REASON=""   # limpa motivo do step anterior; a função do step pode redefinir
  local done_count
  done_count="$(_step_counter)"
  # N = steps já concluídos + 1 (este)
  local step_n=$(( done_count + 1 ))
  local prefix="[${step_n}]"
  if (( ${TOTAL_STEPS:-0} > 0 )); then
    prefix="[${step_n}/${TOTAL_STEPS}] $(ui_bar "$step_n" "$TOTAL_STEPS" 14)"
  fi
  log ""
  log "${C_BLUE}${C_BOLD}${SYM_ARROW} ${prefix} ${name}${C_RESET}  ${C_DIM}+$(_ts)${C_RESET}"
}

step_ok() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("ok")
  STEP_TIMES+=("$dur")
  write_step_event_json "${STEP_NAMES[-1]}" "ok" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  local time_color="$C_DIM"
  (( dur >= 30 )) && time_color="${C_YELLOW}${C_BOLD}"
  log "${C_GREEN}${SYM_OK}${C_RESET} $(ui_pad "${STEP_NAMES[-1]}" "$(_step_name_width)") ${time_color}($(elapsed "$dur"))${C_RESET}"
}

step_fail() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("fail")
  STEP_TIMES+=("$dur")
  HAS_FAIL=1
  write_step_event_json "${STEP_NAMES[-1]}" "fail" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  log "${C_RED}${SYM_FAIL}${C_RESET} $(ui_pad "${STEP_NAMES[-1]}" "$(_step_name_width)") ${C_DIM}($(elapsed "$dur"))${C_RESET}"
}

step_warn() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("warn")
  STEP_TIMES+=("$dur")
  write_step_event_json "${STEP_NAMES[-1]}" "warn" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  log "${C_YELLOW}${SYM_WARN}${C_RESET} $(ui_pad "${STEP_NAMES[-1]}" "$(_step_name_width)") ${C_DIM}($(elapsed "$dur"))${C_RESET}"
}

step_todo() {
  local dur=$((SECONDS - STEP_START))
  STEP_RESULTS+=("todo")
  STEP_TIMES+=("$dur")
  if [[ "${STEP_NAMES[-1]}" == "Doctor: reboot pendente" && -n "${STEP_REASON//[[:space:]]/}" ]]; then
    REBOOT_RECOMMENDATION="$STEP_REASON"
  fi
  write_step_event_json "${STEP_NAMES[-1]}" "todo" "$dur" "$STEP_LAST_RC" "$STEP_REASON"
  log "${C_CYAN}${SYM_TODO}${C_RESET} $(ui_pad "${STEP_NAMES[-1]}" "$(_step_name_width)") ${C_DIM}($(elapsed "$dur"))${C_RESET}"
}

step_skip() {
  local name="$1"
  local reason="$2"
  local _cat; _cat="$(_category_of "$name")"
  _maybe_print_section "$_cat"
  STEP_NAMES+=("$name")
  STEP_CATEGORIES+=("$_cat")
  STEP_RESULTS+=("skip")
  STEP_TIMES+=(0)
  STEP_START_ISO="$(date -Is)"
  write_step_event_json "$name" "skip" 0 0 "$reason"
  log "${C_YELLOW}${SYM_SKIP}${C_RESET} $(ui_pad "${name}" "$(_step_name_width)") ${C_DIM}(${reason})${C_RESET}"
}

run_step() {
  local name="$1"
  shift
  # fail-fast: após o primeiro fail, os steps restantes viram skip sem rodar
  if (( ${RUN_ABORTED:-0} )); then
    step_skip "$name" "abortado por --fail-fast"
    return 0
  fi
  # pular se solicitado via FULL_UPGRADE_SKIP
  if _step_skip_requested "$name"; then
    step_skip "$name" "FULL_UPGRADE_SKIP"
    return 0
  fi
  # dry-run: registrar como skip sem executar
  if (( DRY_RUN )); then
    step_skip "$name" "dry-run"
    return 0
  fi

  # verificar dependências de comando do catálogo
  local _cat_category _cat_tags _cat_effect _cat_timeout _cat_cmd_deps _cat_func _cat_desc
  IFS='|' read -r _cat_category _cat_tags _cat_effect _cat_timeout _cat_cmd_deps _cat_func _cat_desc \
    < <(catalog_info_for_step "$name")

  if [[ -n "$_cat_cmd_deps" ]]; then
    local dep
    IFS=',' read -ra _deps_arr <<< "$_cat_cmd_deps"
    for dep in "${_deps_arr[@]}"; do
      dep="${dep#"${dep%%[![:space:]]*}"}"
      dep="${dep%"${dep##*[![:space:]]}"}"
      if [[ -n "$dep" ]] && ! dep_satisfied "$dep"; then
        step_skip "$name" "cmd-ausente: $dep"
        return 0
      fi
    done
  fi

  step_start "$name"

  if (( VERBOSE )); then
    log "${C_DIM}  [verbose] func: ${_cat_func:-$2} | args: $*${C_RESET}"
  fi

  local rc
  local _to="${_cat_timeout:-0}"
  if [[ "$_to" == "0" || -z "$_to" ]]; then
    "$@"
    rc=$?
  else
    # timeout de função Bash: roda a função em subshell + poll de liveness.
    # Sem `wait -n` com PIDs (exige Bash 5.1) e sem race entre função e
    # sentinela: o veredito de timeout vem de kill -0, não do rc reaped.
    # IMPORTANTE: por rodar em subshell, estado global setado pela função
    # (exceto STEP_REASON, capturado via arquivo) NÃO propaga ao pai. Steps
    # que mutam estado do processo (flock, keepalive) usam timeout=0.
    local _reason_file
    _reason_file="$(mktemp 2>/dev/null || printf '')"
    ( "$@"; _rc=$?; [[ -n "$_reason_file" && -n "$STEP_REASON" ]] && printf '%s' "$STEP_REASON" > "$_reason_file"; exit "$_rc" ) &
    local _bg_pid=$!
    local _deadline=$(( SECONDS + _to ))
    local _timed_out=0
    while kill -0 "$_bg_pid" 2>/dev/null; do
      if (( SECONDS >= _deadline )); then
        _timed_out=1
        break
      fi
      sleep 0.25
    done

    if (( _timed_out )); then
      # Matar a árvore inteira: matar só o subshell deixaria os netos
      # (paru, npm, nvim...) órfãos rodando em paralelo com os próximos steps.
      _kill_tree "$_bg_pid" TERM
      local _grace_deadline=$(( SECONDS + 5 ))
      while kill -0 "$_bg_pid" 2>/dev/null && (( SECONDS < _grace_deadline )); do
        sleep 0.25
      done
      _kill_tree "$_bg_pid" KILL
      wait "$_bg_pid" 2>/dev/null
      rc=124
    else
      wait "$_bg_pid" 2>/dev/null
      rc=$?
    fi

    # Recupera o motivo definido dentro do subshell (se houver).
    if [[ -n "$_reason_file" && -s "$_reason_file" ]]; then
      STEP_REASON="$(cat "$_reason_file" 2>/dev/null)"
    fi
    [[ -n "$_reason_file" ]] && rm -f "$_reason_file"

    if (( _timed_out )); then
      STEP_LAST_RC=$rc
      local dur=$((SECONDS - STEP_START))
      STEP_RESULTS+=("warn")
      STEP_TIMES+=("$dur")
      write_step_event_json "$name" "warn" "$dur" "$rc" "timed_out"
      log "${C_YELLOW}[warn]${C_RESET} ${name} ${C_DIM}(timeout ${_to}s excedido)${C_RESET}"
      return 0
    fi
  fi

  STEP_LAST_RC=$rc
  case "$rc" in
    0) step_ok ;;
    "$RC_WARN") step_warn ;;
    "$RC_TODO") step_todo ;;
    *)
      step_fail
      # Sob --fail-fast, marca o run como abortado: o gate no topo de run_step
      # transforma todos os steps seguintes em skip "abortado por --fail-fast".
      (( ${FAIL_FAST:-0} )) && RUN_ABORTED=1
      ;;
  esac
  return 0
}


# L3 — captura a lista de pacotes instalados (nome versão) ordenada em $1, para
# o diff "o que mudou" no resumo. No-op sob --dry-run ou sem pacman.
capture_installed_pkgs() {
  local out="$1"
  [[ -n "$out" ]] || return 0
  (( DRY_RUN )) && return 0
  has pacman || return 0
  pacman -Q 2>/dev/null | sort > "$out" 2>/dev/null || true
}

# L3 — diff puro entre dois snapshots de `pacman -Q` (nome versão por linha).
# Emite, uma por linha: "U nome velha nova" (atualizado), "I nome versão"
# (instalado), "R nome versão" (removido). rc 1 se algum arquivo não é legível.
pkg_diff() {
  local before="$1" after="$2"
  [[ -r "$before" && -r "$after" ]] || return 1
  awk '
    FNR == NR { b[$1] = $2; next }
    {
      a[$1] = $2
      if ($1 in b) { if (b[$1] != $2) print "U " $1 " " b[$1] " " $2 }
      else print "I " $1 " " $2
    }
    END { for (n in b) if (!(n in a)) print "R " n " " b[n] }
  ' "$before" "$after" | sort -k2
}
