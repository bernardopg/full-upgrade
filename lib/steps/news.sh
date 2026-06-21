#!/usr/bin/env bash
# lib/steps/news.sh — checagem de Arch Linux News antes das mutações (I1).
# Sourced por full-upgrade.sh (glob de steps). Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Arquivo de estado: epoch (UTC) do item de news mais recente já visto.
ARCH_NEWS_STATE="${ARCH_NEWS_STATE:-${LOG_DIR}/arch-news-last}"

# Helper puro: extrai do RSS de news (stdin) os itens com pubDate mais recente
# que <cutoff_epoch>, emitindo uma linha "<epoch>\t<title>" por item (mais novo
# primeiro não é garantido; o chamador ordena/limita). Datas parseadas sob
# LC_ALL=C. Itens sem pubDate parseável são ignorados.
# Uso: parse_arch_news_rss <cutoff_epoch>   (lê o XML por stdin)
parse_arch_news_rss() {
  local cutoff="${1:-0}"
  # Achata o XML para uma linha por <item> e extrai title/pubDate.
  tr '\n' ' ' \
    | sed -e 's#<item>#\n<item>#g' \
    | grep '<item>' \
    | while IFS= read -r item; do
        local title date epoch
        title="$(printf '%s' "$item" | sed -nE 's#.*<title>(<!\[CDATA\[)?(.*)#\2#p' | sed -E 's#(\]\]>)?</title>.*##')"
        date="$(printf '%s' "$item"  | sed -nE 's#.*<pubDate>([^<]*)</pubDate>.*#\1#p')"
        [[ -n "$date" ]] || continue
        epoch="$(LC_ALL=C date -d "$date" +%s 2>/dev/null || true)"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        (( epoch > cutoff )) || continue
        printf '%s\t%s\n' "$epoch" "$title"
      done
}

# I1 — checa o feed de Arch News e alerta sobre itens novos desde a última
# verificação. Read-only (não muta o sistema), roda antes do -Syu. Persiste o
# epoch do item mais novo visto em ARCH_NEWS_STATE (modelo "reconhece ao rodar").
# RC: RC_TODO se houver news nova (atenção antes de atualizar); 0 se nada novo;
# RC_WARN em falha de rede.
check_arch_news() {
  has curl || { log "  curl não instalado; pulando."; return 0; }

  local rss rc
  rss="$(run_network_cmd curl -fsSL https://archlinux.org/feeds/news/)"
  rc=$?
  if (( rc == RC_WARN )); then
    log "  Falha de rede ao buscar Arch News; adiando checagem."
    STEP_REASON="rede indisponível para Arch News"
    return "$RC_WARN"
  fi
  if (( rc != 0 )) || [[ -z "${rss//[[:space:]]/}" ]]; then
    log "  Não foi possível obter o feed de Arch News."
    return 0
  fi

  local cutoff=0
  if [[ -r "$ARCH_NEWS_STATE" ]]; then
    cutoff="$(tr -dc '0-9' < "$ARCH_NEWS_STATE" 2>/dev/null || true)"
    [[ "$cutoff" =~ ^[0-9]+$ ]] || cutoff=0
  fi

  local -a items=()
  mapfile -t items < <(parse_arch_news_rss "$cutoff" <<< "$rss" | sort -rn)

  if (( ${#items[@]} == 0 )); then
    log "  Sem novas Arch News desde a última verificação."
    return 0
  fi

  log "  ${C_YELLOW}${#items[@]} nova(s) Arch News — revise antes de atualizar:${C_RESET}"
  local line epoch title newest=0 shown=0
  for line in "${items[@]}"; do
    epoch="${line%%$'\t'*}"
    title="${line#*$'\t'}"
    (( epoch > newest )) && newest="$epoch"
    if (( shown < 10 )); then
      log "    • $(LC_ALL=C date -d "@${epoch}" '+%Y-%m-%d' 2>/dev/null): ${title}"
      shown=$((shown + 1))
    fi
  done
  log "  Detalhes: https://archlinux.org/news/"

  # Persiste o epoch mais novo visto (reconhece ao rodar). Falha de escrita não
  # é fatal — apenas re-alertaria no próximo run.
  if [[ -n "${ARCH_NEWS_STATE:-}" ]]; then
    printf '%s\n' "$newest" > "$ARCH_NEWS_STATE" 2>/dev/null || true
  fi

  STEP_REASON="${#items[@]} nova(s) Arch News — revise https://archlinux.org/news/"
  return "$RC_TODO"
}
