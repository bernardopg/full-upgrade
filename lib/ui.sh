#!/usr/bin/env bash
# lib/ui.sh — camada visual: cores, símbolos, largura adaptativa, banner,
# barra de progresso, resumo agrupado por categoria.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# ── Cores (TTY-aware; respeita NO_COLOR) ────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_BOLD=$'\033[1m'
  C_RED=$'\033[1;31m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[1;34m'
  C_CYAN=$'\033[1;36m'
  C_DIM=$'\033[2m'
  C_RESET=$'\033[0m'
else
  C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_CYAN=""; C_DIM=""; C_RESET=""
fi

# ── Símbolos de status (Unicode com fallback ASCII) ─────────────────────────────
# NO_UNICODE=1 ou locale não-UTF8 → fallback ASCII.
if [[ "${NO_UNICODE:-0}" != "1" && "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *[Uu][Tt][Ff]* ]]; then
  SYM_OK="✔"; SYM_FAIL="✘"; SYM_WARN="⚠"; SYM_TODO="→"; SYM_SKIP="⊘"
  SYM_ARROW="▶"; BAR_FULL="▓"; BAR_EMPTY="░"; HR_HEAVY="━"; HR_LIGHT="─"
  BOX_TL="╔"; BOX_TR="╗"; BOX_BL="╚"; BOX_BR="╝"; BOX_H="═"; BOX_V="║"
else
  SYM_OK="ok"; SYM_FAIL="XX"; SYM_WARN="!!"; SYM_TODO="->"; SYM_SKIP="--"
  SYM_ARROW=">"; BAR_FULL="#"; BAR_EMPTY="."; HR_HEAVY="="; HR_LIGHT="-"
  BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="="; BOX_V="|"
fi

# ── Largura adaptativa do terminal ──────────────────────────────────────────────
ui_width() {
  local w="${COLUMNS:-0}"
  # Sem COLUMNS (caso normal fora de shell interativo) o `tput` seria um fork
  # por linha de log; memoriza o resultado. Com COLUMNS setado nada é
  # memorizado, então os testes continuam podendo variar a largura.
  if (( w == 0 )); then
    [[ -n "${UI_WIDTH_TPUT_CACHE:-}" ]] || UI_WIDTH_TPUT_CACHE="$(tput cols 2>/dev/null || echo 0)"
    w="$UI_WIDTH_TPUT_CACHE"
  fi
  [[ "$w" =~ ^[0-9]+$ ]] || w=0
  (( w == 0 )) && w=80
  (( w < 40 )) && w=40
  (( w > 100 )) && w=100
  printf '%d' "$w"
}

# Preenche $1 com espaços à direita até a largura $2, medindo por LARGURA DE
# EXIBIÇÃO (número de caracteres, não bytes). Em locale UTF-8 `${#s}` conta
# caracteres, então nomes com acento PT-BR (ã, ç, é…) alinham corretamente —
# `printf '%-*s'` preenche por bytes e desalinha qualquer nome acentuado.
# Texto já maior que a largura é devolvido sem corte.
ui_pad() {
  local s="$1" w="$2" len="${#1}" i pad=""
  (( len >= w )) && { printf '%s' "$s"; return; }
  for (( i = len; i < w; i++ )); do pad+=" "; done
  printf '%s%s' "$s" "$pad"
}

# Como ui_pad, mas preenchendo à esquerda (alinhamento à direita). Usado para
# números em coluna (contador de steps, durações do "top mais lentos").
ui_pad_left() {
  local s="$1" w="$2" len="${#1}" i pad=""
  (( len >= w )) && { printf '%s' "$s"; return; }
  for (( i = len; i < w; i++ )); do pad+=" "; done
  printf '%s%s' "$pad" "$s"
}

# Quebra $2 em no máximo $3 colunas de exibição com RECUO PENDENTE (hanging
# indent): a 1ª linha sai prefixada com $1 e as continuações alinham sob o
# início do texto (coluna = largura visível do prefixo). O ui_wrap puro
# re-tokeniza a linha inteira e por isso colapsa espaços deliberados do
# prefixo (o "→  " do rodapé de próximos passos virava "→ " em linhas longas)
# e indenta a continuação na coluna do marcador, não do texto. Prefixo deve
# virar sem ANSI (a versão colorida é aplicada pelo chamador ao imprimir).
# Token maior que a largura fica sozinho e intacto, como no ui_wrap.
ui_wrap_hang() {
  local prefix="$1" text="$2" w="${3:-0}" tokw tok line="" linew=0
  local pw=${#prefix}
  (( w <= 0 )) && w="$(ui_width)"
  (( ${#prefix} + ${#text} <= w )) && { printf '%s%s\n' "$prefix" "$text"; return 0; }

  local -a toks=() lines=()
  local _restore_glob=0
  [[ -o noglob ]] || { set -f; _restore_glob=1; }
  read -ra toks <<< "$text"
  (( _restore_glob )) && set +f

  for tok in "${toks[@]}"; do
    tokw=${#tok}
    if [[ -z "$line" ]]; then
      line="${prefix}${tok}"; linew=$(( pw + tokw ))
    elif (( linew + 1 + tokw <= w )); then
      line+=" ${tok}"; linew=$(( linew + 1 + tokw ))
    else
      lines+=("$line")
      line="$(printf '%*s' "$pw" '')${tok}"
      linew=$(( pw + tokw ))
    fi
  done
  (( ${#lines[@]} == 0 )) && { printf '%s\n' "$line"; return 0; }
  lines+=("$line")
  printf '%s\n' "${lines[@]}"
}

# Corta texto pela largura de exibição, usando reticências quando necessário.
# Larguras muito pequenas ainda produzem uma saída determinística.
ui_truncate() {
  local s="$1" w="$2"
  (( w <= 0 )) && return 0
  (( ${#s} <= w )) && { printf '%s' "$s"; return 0; }
  (( w == 1 )) && { printf '…'; return 0; }
  printf '%s…' "${s:0:w-1}"
}

ui_fit() {
  local s="$1" w="$2"
  ui_pad "$(ui_truncate "$s" "$w")" "$w"
}

# Remove sequências ANSI de uma STRING em Bash puro (sem fork), ao contrário de
# `_strip_ansi`, que é um filtro de stdin. Usado só para medir largura de
# exibição em caminhos quentes (cada linha de `log`), onde um `sed` extra por
# linha pesaria. Cobre o subconjunto CSI que o projeto emite: ESC '[' … letra.
ui_strip_ansi() {
  local s="$1" out="" pre rest
  while [[ "$s" == *$'\e['* ]]; do
    pre="${s%%$'\e['*}"
    rest="${s#*$'\e['}"
    out+="$pre"
    while [[ -n "$rest" && "${rest:0:1}" != [a-zA-Z] ]]; do rest="${rest:1}"; done
    s="${rest:1}"
  done
  printf '%s' "${out}${s}"
}

# Quebra $1 em linhas de no máximo $2 colunas de EXIBIÇÃO (ANSI não conta),
# repetindo a indentação inicial nas continuações. Quebra só em espaços: um
# token maior que a largura (URL, caminho longo, régua) fica sozinho e intacto,
# em vez de ser cortado no meio. As cores viajam junto com o token que as
# carrega, então o texto continua colorido depois da quebra.
# Uso: ui_wrap <texto> <largura>   → uma linha por saída (pode ser 1 só).
ui_wrap() {
  local s="$1" w="${2:-0}"
  (( w <= 0 )) && { printf '%s\n' "$s"; return 0; }

  local plain; plain="$(ui_strip_ansi "$s")"
  (( ${#plain} <= w )) && { printf '%s\n' "$s"; return 0; }

  # Indentação da 1ª linha, replicada nas continuações.
  local indent="${plain%%[![:space:]]*}"
  local -a toks=()
  local _restore_glob=0
  [[ -o noglob ]] || { set -f; _restore_glob=1; }
  read -ra toks <<< "$s"
  (( _restore_glob )) && set +f

  local line="" linew=0 tok tokw
  for tok in "${toks[@]}"; do
    tokw=${#tok}
    [[ "$tok" == *$'\e['* ]] && { local _p; _p="$(ui_strip_ansi "$tok")"; tokw=${#_p}; }
    if [[ -z "$line" ]]; then
      line="${indent}${tok}"; linew=$(( ${#indent} + tokw ))
    elif (( linew + 1 + tokw > w )); then
      printf '%s\n' "$line"
      line="${indent}${tok}"; linew=$(( ${#indent} + tokw ))
    else
      line+=" ${tok}"; linew=$(( linew + 1 + tokw ))
    fi
  done
  [[ -n "$line" ]] && printf '%s\n' "$line"
  return 0
}

# Linha horizontal de largura adaptativa. $1 = char (default HR_HEAVY).
# $2 = largura explícita, para réguas que saem indentadas e precisam descontar
# a indentação em vez de estourar a tela por 2 colunas.
ui_hr() {
  local ch="${1:-$HR_HEAVY}" w="${2:-0}"
  (( w > 0 )) || w="$(ui_width)"
  local line=""; local i
  for (( i = 0; i < w; i++ )); do line+="$ch"; done
  printf '%s' "$line"
}

# ── Barra de progresso textual: ui_bar <atual> <total> [largura] ────────────────
ui_bar() {
  local cur="$1" total="$2" width="${3:-16}"
  (( total <= 0 )) && { printf ''; return; }
  local filled=$(( cur * width / total ))
  (( filled > width )) && filled=width
  (( filled < 0 )) && filled=0
  local pct=$(( cur * 100 / total ))
  local bar="" i
  for (( i = 0; i < filled; i++ )); do bar+="$BAR_FULL"; done
  for (( i = filled; i < width; i++ )); do bar+="$BAR_EMPTY"; done
  printf '%s %3d%%' "$bar" "$pct"
}

# Progresso responsivo: barra completa em telas largas, curta nas médias e
# somente percentual em terminais estreitos.
ui_progress() {
  local cur="$1" total="$2" w
  w="$(ui_width)"
  if (( w >= 76 )); then
    ui_bar "$cur" "$total" 14
  elif (( w >= 56 )); then
    ui_bar "$cur" "$total" 8
  elif (( total > 0 )); then
    printf '%3d%%' "$(( cur * 100 / total ))"
  fi
}

# ── Banner de cabeçalho (largura adaptativa) ────────────────────────────────────
print_banner() {
  local w title="full-upgrade  ${SCRIPT_VERSION}"
  w="$(ui_width)"
  local inner=$(( w - 2 ))
  # centraliza o título
  local pad=$(( (inner - ${#title}) / 2 ))
  (( pad < 0 )) && pad=0
  local top="" mid="" bot="" i
  for (( i = 0; i < inner; i++ )); do top+="$BOX_H"; bot+="$BOX_H"; done
  local spaces_l="" spaces_r=""
  for (( i = 0; i < pad; i++ )); do spaces_l+=" "; done
  local rem=$(( inner - pad - ${#title} ))
  (( rem < 0 )) && rem=0
  for (( i = 0; i < rem; i++ )); do spaces_r+=" "; done

  log_always "${C_BOLD}${C_CYAN}${BOX_TL}${top}${BOX_TR}${C_RESET}"
  log_always "${C_BOLD}${C_CYAN}${BOX_V}${spaces_l}${title}${spaces_r}${BOX_V}${C_RESET}"
  log_always "${C_BOLD}${C_CYAN}${BOX_BL}${bot}${BOX_BR}${C_RESET}"
  local sha_short="${SCRIPT_SHA256:0:12}" meta log_line
  meta="$(date '+%Y-%m-%d %H:%M:%S')  ${SYM_ARROW}  $(hostname)  ${SYM_ARROW}  kernel $(uname -r)  ${SYM_ARROW}  sha ${sha_short}"
  log_always "${C_DIM}$(ui_truncate "$meta" "$w")${C_RESET}"
  log_line="Log: ${LOG_FILE}"
  log_always "${C_DIM}$(ui_truncate "$log_line" "$w")${C_RESET}"
  log_raw "JSONL: ${JSONL_FILE}"
  if (( DRY_RUN )); then
    log_always "${C_YELLOW}${C_BOLD}  [DRY-RUN] Nenhum comando será executado.${C_RESET}"
  fi
  if (( QUIET )); then
    log_always "${C_DIM}  [QUIET] Output suprimido; log completo em: ${LOG_FILE}${C_RESET}"
  fi
  if (( VERBOSE )); then
    log_always "${C_DIM}  [VERBOSE] Função e argumentos de cada step serão exibidos.${C_RESET}"
  fi
  if [[ -n "$MODE" && "$MODE" != "full" ]]; then
    log_always "${C_CYAN}${C_BOLD}  [MODE:${MODE}] Rodando apenas steps do modo ${MODE}.${C_RESET}"
  fi
  if [[ -n "$ONLY_CATEGORY" ]]; then
    log_always "${C_CYAN}  [ONLY] Rodando apenas (categoria/tag/nome): ${ONLY_CATEGORY}${C_RESET}"
  fi
  if [[ -n "$RESUME_STEPS" ]]; then
    log_always "${C_CYAN}  [RESUME] Retomando steps não-ok do último run: ${RESUME_STEPS}${C_RESET}"
  fi
  if (( NO_REPAIR )); then
    log_always "${C_YELLOW}  [NO-REPAIR] Reparos mutáveis serão pulados.${C_RESET}"
  fi
  if (( NO_CLEANUP )); then
    log_always "${C_YELLOW}  [NO-CLEANUP] Limpeza de cache/snapshots/órfãos/symlinks/journal será pulada.${C_RESET}"
  fi
  if (( DEVEL_UPDATE )); then
    log_always "${C_CYAN}  [--devel] Pacotes AUR -git/-svn incluídos no update.${C_RESET}"
  fi
  if (( JSON_SUMMARY )); then
    log_always "${C_CYAN}  [JSON] Resumo JSON será impresso ao final.${C_RESET}"
  fi
  if [[ -n "${FULL_UPGRADE_SKIP//[[:space:]]/}" ]]; then
    local skip_count; skip_count="$(skip_step_count)"
    if (( skip_count > 8 )); then
      COMPACT_SKIP_OUTPUT=1
      log_always "${C_YELLOW}  [SKIP] ${skip_count} step(s) filtrados; detalhes no log/JSONL.${C_RESET}"
    else
      log_always "${C_YELLOW}  [SKIP] Steps ignorados: ${FULL_UPGRADE_SKIP}${C_RESET}"
    fi
  fi
  if [[ -n "${FULL_UPGRADE_DISABLED_INTEGRATIONS//[[:space:]]/}" ]]; then
    log_always "${C_YELLOW}  [INTEGRAÇÕES DESABILITADAS] ${FULL_UPGRADE_DISABLED_INTEGRATIONS}${C_RESET}"
  fi
}

# ── Mapeia status → símbolo + cor ───────────────────────────────────────────────
_status_sym() {  # $1 = status → ecoa "SÍMBOLO|COR"
  case "$1" in
    ok)   printf '%s|%s' "$SYM_OK"   "$C_GREEN" ;;
    warn) printf '%s|%s' "$SYM_WARN" "$C_YELLOW" ;;
    todo) printf '%s|%s' "$SYM_TODO" "$C_CYAN" ;;
    fail) printf '%s|%s' "$SYM_FAIL" "$C_RED" ;;
    skip) printf '%s|%s' "$SYM_SKIP" "$C_YELLOW" ;;
  esac
}

# Especificação dos grupos do resumo: "rótulo|categoria categoria ...".
# Centraliza a ordem e permite agrupar categorias distintas sob o mesmo header
# (ex.: editor+shell), evitando headers duplicados e categorias órfãs no fim.
summary_group_specs() {
  cat <<'EOF'
Preflight|core
Reparos|repair
Sistema / Pacman|pacman
Contêineres|containers flatpak docker snap
Linguagens|lang
Firmware / Boot|firmware
IA|ai
Apps manuais|manual
Rede|network
Shell / Editor|editor shell
Hyprland|hyprland
Limpeza|cleanup
Verificação final|final
Doctor (auditorias)|doctor
EOF
}

summary_category_in_group_list() {
  local category="$1" groups="$2" group
  for group in $groups; do
    [[ "$group" == "$category" ]] && return 0
  done
  return 1
}

summary_category_in_groups() {
  local category="$1" line groups
  while IFS='|' read -r _label groups; do
    summary_category_in_group_list "$category" "$groups" && return 0
  done < <(summary_group_specs)
  return 1
}

# Rótulo do grupo de resumo ao qual uma categoria pertence (mesma fonte de
# verdade do resumo). Usado para imprimir cabeçalhos de seção no output ao vivo,
# mantendo a organização da execução idêntica à do resumo final.
_group_label_for_category() {
  local category="$1" label cats
  while IFS='|' read -r label cats; do
    summary_category_in_group_list "$category" "$cats" && { printf '%s' "$label"; return 0; }
  done < <(summary_group_specs)
  printf 'Outros'
}

# Rótulo legível por categoria (fallback para callers antigos; o resumo usa
# summary_group_specs para evitar duplicação de headers).
_category_label() {
  case "$1" in
    core)     printf 'Preflight' ;;
    repair)   printf 'Reparos' ;;
    pacman)   printf 'Sistema / Pacman' ;;
    flatpak|docker|containers) printf 'Contêineres' ;;
    lang)     printf 'Linguagens' ;;
    firmware) printf 'Firmware / Boot' ;;
    editor|shell) printf 'Shell / Editor' ;;
    hyprland) printf 'Hyprland' ;;
    ai)       printf 'IA' ;;
    manual)   printf 'Apps manuais' ;;
    network)  printf 'Rede' ;;
    cleanup)  printf 'Limpeza' ;;
    final)    printf 'Verificação final' ;;
    doctor)   printf 'Doctor (auditorias)' ;;
    *)        printf 'Outros' ;;
  esac
}

summary_group_total_seconds() {
  local groups="$1" i total=0
  for i in "${!STEP_RESULTS[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    summary_category_in_group_list "${STEP_CATEGORIES[$i]:-}" "$groups" || continue
    total=$(( total + ${STEP_TIMES[$i]:-0} ))
  done
  printf '%s' "$total"
}

summary_slowest_steps() {
  local limit="${1:-3}" i
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    printf '%s\t%s\t%s\n' "${STEP_TIMES[$i]:-0}" "${STEP_NAMES[$i]}" "${STEP_RESULTS[$i]}"
  done | sort -rn | head -n "$limit"
}

# Itens acionáveis do run (fail, todo e warn, nessa ordem de urgência), um por
# linha no formato "status<TAB>nome<TAB>motivo". Alimenta o bloco "Próximos
# passos" do resumo: os motivos já saem soltos dentro de cada categoria, mas em
# um run de 120 steps eles rolam para fora da tela e o usuário só ficava com a
# contagem ("2 item(ns) precisam de decisão"). Puro.
summary_action_items() {
  local wanted i
  for wanted in fail todo warn; do
    for i in "${!STEP_NAMES[@]}"; do
      [[ "${STEP_RESULTS[$i]}" == "$wanted" ]] || continue
      printf '%s\t%s\t%s\n' "$wanted" "${STEP_NAMES[$i]}" "${STEP_REASONS[$i]:-}"
    done
  done
}

summary_category_totals_json() {
  local first=1 group_label group_cats i status total ok warn todo fail skip
  printf '{'
  while IFS='|' read -r group_label group_cats; do
    total=0; ok=0; warn=0; todo=0; fail=0; skip=0
    for i in "${!STEP_RESULTS[@]}"; do
      summary_category_in_group_list "${STEP_CATEGORIES[$i]:-}" "$group_cats" || continue
      status="${STEP_RESULTS[$i]}"
      case "$status" in
        ok) ((ok++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        warn) ((warn++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        todo) ((todo++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        fail) ((fail++)); total=$(( total + ${STEP_TIMES[$i]:-0} )) ;;
        skip) ((skip++)) ;;
      esac
    done
    (( ok + warn + todo + fail + skip == 0 )) && continue
    (( first == 0 )) && printf ','
    first=0
    printf '%s:{"duration_seconds":%s,"ok":%s,"warn":%s,"todo":%s,"fail":%s,"skip":%s}' \
      "$(json_escape "$group_label")" "$total" "$ok" "$warn" "$todo" "$fail" "$skip"
  done < <(summary_group_specs)
  printf '}'
}

summary_slowest_steps_json() {
  local first=1 line dur name status
  printf '['
  while IFS=$'\t' read -r dur name status; do
    [[ -n "$name" ]] || continue
    (( first == 0 )) && printf ','
    first=0
    printf '{"step":%s,"status":%s,"duration_seconds":%s}' \
      "$(json_escape "$name")" "$(json_escape "$status")" "${dur:-0}"
  done < <(summary_slowest_steps 3)
  printf ']'
}

reboot_recommendation_from_reason() {
  local reason="$1"
  [[ -n "${reason//[[:space:]]/}" ]] || return 1
  printf 'Reboot recomendado: %s\n' "$reason"
}

# ── Resumo agrupado por categoria ───────────────────────────────────────────────
print_summary() {
  local total_dur=$((SECONDS - TOTAL_START))
  local ok=0 warn=0 todo=0 fail=0 skip=0 i

  for i in "${!STEP_RESULTS[@]}"; do
    case "${STEP_RESULTS[$i]}" in
      ok) ((ok++));; warn) ((warn++));; todo) ((todo++));; fail) ((fail++));; skip) ((skip++));;
    esac
  done

  log_always ""
  log_always "${C_BOLD}$(ui_hr "$HR_HEAVY")${C_RESET}"
  log_always "${C_BOLD}Resumo${C_RESET}"

  # Largura da coluna de nome p/ alinhar as durações: maior nome não-pulado,
  # limitado a [24, 50] para não empurrar demais em terminais estreitos.
  local namew=0 _nlen
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    _nlen=${#STEP_NAMES[$i]}
    (( _nlen > namew )) && namew=$_nlen
  done
  local terminal_namew=$(( $(ui_width) - 16 ))
  (( terminal_namew < 16 )) && terminal_namew=16
  (( namew > 50 )) && namew=50
  (( namew > terminal_namew )) && namew=$terminal_namew
  (( namew < 24 )) && namew=24

  # Ordem/grupos de categorias para exibição.
  local group_label group_cats
  while IFS='|' read -r group_label group_cats; do
    local printed_header=0
    local group_total
    group_total="$(summary_group_total_seconds "$group_cats")"
    for i in "${!STEP_NAMES[@]}"; do
      summary_category_in_group_list "${STEP_CATEGORIES[$i]:-}" "$group_cats" || continue
      [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
      if (( printed_header == 0 )); then
        log_always "  ${C_BOLD}${C_BLUE}${group_label}${C_RESET} ${C_DIM}($(elapsed "$group_total"))${C_RESET}"
        printed_header=1
      fi
      local sym color dur time_color symcolor
      symcolor="$(_status_sym "${STEP_RESULTS[$i]}")"
      sym="${symcolor%%|*}"; color="${symcolor##*|}"
      dur="$(elapsed "${STEP_TIMES[$i]}")"
      time_color="$C_DIM"
      (( "${STEP_TIMES[$i]}" >= 30 )) && time_color="${C_YELLOW}"
      log_always "    ${color}${sym}${C_RESET}  $(ui_fit "${STEP_NAMES[$i]}" "$namew")  ${time_color}(${dur})${C_RESET}"
      if [[ "${STEP_RESULTS[$i]}" != "ok" && -n "${STEP_REASONS[$i]:-}" ]]; then
        log_always "       ${C_DIM}↳ $(ui_truncate "${STEP_REASONS[$i]}" "$(( $(ui_width) - 9 ))")${C_RESET}"
      fi
    done
  done < <(summary_group_specs)

  # Steps sem categoria conhecida (defensivo).
  for i in "${!STEP_NAMES[@]}"; do
    [[ "${STEP_RESULTS[$i]}" == "skip" ]] && continue
    local c="${STEP_CATEGORIES[$i]:-}"
    summary_category_in_groups "$c" && continue
    local symcolor sym color dur
    symcolor="$(_status_sym "${STEP_RESULTS[$i]}")"; sym="${symcolor%%|*}"; color="${symcolor##*|}"
    dur="$(elapsed "${STEP_TIMES[$i]}")"
    log_always "    ${color}${sym}${C_RESET}  $(ui_fit "${STEP_NAMES[$i]}" "$namew")  ${C_DIM}(${dur})${C_RESET}"
    if [[ -n "${STEP_REASONS[$i]:-}" ]]; then
      log_always "       ${C_DIM}↳ $(ui_truncate "${STEP_REASONS[$i]}" "$(( $(ui_width) - 9 ))")${C_RESET}"
    fi
  done

  # Skips agrupados ao final.
  if (( skip > 0 )); then
    log_always "  ${C_DIM}$(ui_hr "$HR_LIGHT" "$(( $(ui_width) - 2 ))")${C_RESET}"
    if (( ${COMPACT_SKIP_OUTPUT:-0} && skip > 8 )); then
      log_always "    ${C_YELLOW}${SYM_SKIP}${C_RESET}  ${C_DIM}${skip} steps omitidos por filtro; detalhes no log/JSONL.${C_RESET}"
    else
      log_always "  ${C_DIM}Pulados (${skip})${C_RESET}"
      for i in "${!STEP_NAMES[@]}"; do
        [[ "${STEP_RESULTS[$i]}" != "skip" ]] && continue
        log_always "    ${C_YELLOW}${SYM_SKIP}${C_RESET}  ${C_DIM}${STEP_NAMES[$i]}${C_RESET}"
      done
    fi
  fi

  log_always "${C_BOLD}$(ui_hr "$HR_HEAVY")${C_RESET}"
  log_always "  Total: ${C_GREEN}${ok} ok${C_RESET}, ${C_YELLOW}${warn} warn${C_RESET}, ${C_CYAN}${todo} todo${C_RESET}, ${C_RED}${fail} fail${C_RESET}, ${C_YELLOW}${skip} skip${C_RESET} em ${C_BOLD}$(elapsed "$total_dur")${C_RESET}"
  if [[ -n "${REBOOT_RECOMMENDATION:-}" ]]; then
    log_always "  ${C_YELLOW}${C_BOLD}$(reboot_recommendation_from_reason "$REBOOT_RECOMMENDATION")${C_RESET}"
  fi
  local slow_line slow_dur slow_name slow_status printed_slow=0
  while IFS=$'\t' read -r slow_dur slow_name slow_status; do
    [[ -n "$slow_name" ]] || continue
    if (( printed_slow == 0 )); then
      log_always "  ${C_BOLD}Top 3 mais lentos:${C_RESET}"
      printed_slow=1
    fi
    log_always "    ${C_DIM}$(ui_pad_left "$(elapsed "$slow_dur")" 7)${C_RESET}  ${slow_name} (${slow_status})"
  done < <(summary_slowest_steps 3)
  if (( todo > 0 )); then
    log_always "  ${C_CYAN}${C_BOLD}Ação necessária: ${todo} item(ns) precisam de decisão ou ação manual.${C_RESET}"
  fi
  if (( warn > 0 )); then
    log_always "  ${C_YELLOW}${C_BOLD}Aviso: ${warn} item(ns) merecem revisão, mas não bloquearam o update.${C_RESET}"
  fi
  if (( fail > 0 )); then
    log_always "  ${C_RED}${C_BOLD}Atenção: ${fail} step(s) com falha — verifique o log: ${LOG_FILE}${C_RESET}"
  fi

  if (( todo + warn + fail > 0 )); then
    local act_status act_name act_reason act_symcolor act_sym act_color printed_act=0
    while IFS=$'\t' read -r act_status act_name act_reason; do
      [[ -n "$act_name" ]] || continue
      if (( printed_act == 0 )); then
        log_always "  ${C_BOLD}Próximos passos:${C_RESET}"
        printed_act=1
      fi
      act_symcolor="$(_status_sym "$act_status")"
      act_sym="${act_symcolor%%|*}"; act_color="${act_symcolor##*|}"
      # Item quebrado com recuo pendente (ui_wrap_hang): linhas longas mantêm o
      # alinhamento "→  " e a continuação fica sob o nome, não sob o marcador —
      # pelo ui_wrap puro a linha colapsava para "→ " e a continuação voltava
      # para a coluna do marcador, destoando das linhas curtas ao redor.
      local act_text="$act_name" act_pad=$(( 4 + ${#act_sym} + 2 ))
      [[ -n "${act_reason//[[:space:]]/}" ]] && act_text="${act_name} — ${act_reason}"
      local act_prefix="    ${act_sym}  " act_indent
      act_indent="$(printf '%*s' "$act_pad" '')"
      local -a act_lines=()
      mapfile -t act_lines < <(ui_wrap_hang "$act_prefix" "$act_text" "$(ui_width)")
      local li=0 in_reason=0 li_line li_body li_out l_left l_right
      for li_line in "${act_lines[@]}"; do
        # ui_wrap_hang já devolve a linha montada (prefixo na 1ª, recuo nas
        # demais); aqui só trocamos essa moldura pela versão colorida.
        if (( li == 0 )); then
          li_body="${li_line#"$act_prefix"}"
          li_out="    ${act_color}${act_sym}${C_RESET}  "
        else
          li_body="${li_line#"$act_indent"}"
          li_out="$act_indent"
        fi
        # Pinta a partir do separador " — " (nome em cor normal, motivo em dim);
        # linhas de continuação são motivo, então inteiras em dim. Nome de step
        # não contém " — ", então o primeiro separador é sempre o do join.
        if (( in_reason == 0 )) && [[ "$li_body" == *" — "* ]]; then
          l_left="${li_body%% — *}"; l_right="${li_body#* — }"
          log_always "${li_out}${l_left} — ${C_DIM}${l_right}${C_RESET}"
          in_reason=1
        elif (( in_reason )); then
          log_always "${li_out}${C_DIM}${li_body}${C_RESET}"
        else
          log_always "${li_out}${li_body}"
        fi
        (( li++ ))
      done
    done < <(summary_action_items)
  fi

  write_summary_event_json "$ok" "$warn" "$todo" "$fail" "$skip" "$total_dur"
  if (( JSON_SUMMARY )); then
    printf '%s\n' "$(summary_json_line "$ok" "$warn" "$todo" "$fail" "$skip" "$total_dur")"
  fi
}


# L3 — bloco "Pacotes alterados" no resumo: lê dois snapshots de pacman -Q
# (antes/depois do run) e mostra atualizados (nome velha → nova), instalados e
# removidos. Lista capada; sem diff => nada é impresso. rc 0 sempre.
print_pkg_changes() {
  local before="$1" after="$2"
  [[ -r "$before" && -r "$after" ]] || return 0
  local diff
  diff="$(pkg_diff "$before" "$after" 2>/dev/null)"
  [[ -n "${diff//[[:space:]]/}" ]] || return 0

  local up ins rem
  up="$(grep -c '^U ' <<< "$diff" || true)"
  ins="$(grep -c '^I ' <<< "$diff" || true)"
  rem="$(grep -c '^R ' <<< "$diff" || true)"

  # Indentado em 2 como o resto do corpo do resumo; antes o título ficava
  # colado na coluna 0 e destoava do bloco inteiro logo acima.
  local up_color="$C_DIM"; (( up > 0 )) && up_color="$C_GREEN"
  log_always "  ${C_BOLD}Pacotes alterados${C_RESET} (${up_color}${up} atualizados${C_RESET}, ${ins} instalados, ${rem} removidos)"

  local shown=0 max=30 tag a b c namew=0
  # Alinhar a coluna de versões pela maior nome da lista (o catálogo de steps
  # alinha por ui_fit; aqui "lld" e "extra-codem-modules" no mesmo bloco
  # deixavam as versões em colunas tortas).
  while read -r tag a b c; do
    [[ -n "$tag" ]] || continue
    (( ${#a} > namew )) && namew=${#a}
  done <<< "$diff"
  while read -r tag a b c; do
    [[ -n "$tag" ]] || continue
    if (( shown >= max )); then
      log_always "    ${C_DIM}… e mais $(( up + ins + rem - shown )) (lista completa no log)${C_RESET}"
      break
    fi
    case "$tag" in
      U) log_always "    ${C_GREEN}↑${C_RESET} $(ui_pad "${a}" "$namew")  ${C_DIM}${b} → ${c}${C_RESET}" ;;
      I) log_always "    ${C_CYAN}+${C_RESET} $(ui_pad "${a}" "$namew")  ${C_DIM}${b}${C_RESET}" ;;
      R) log_always "    ${C_RED}−${C_RESET} $(ui_pad "${a}" "$namew")  ${C_DIM}${b}${C_RESET}" ;;
    esac
    (( shown++ ))
  done <<< "$diff"
}
