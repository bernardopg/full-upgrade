#!/usr/bin/env bash
# steps/news.sh — notícias do Arch Linux antes do upgrade.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

ARCH_NEWS_FEED_URL="${ARCH_NEWS_FEED_URL:-https://archlinux.org/feeds/news/}"
ARCH_NEWS_SEEN_FILE="${ARCH_NEWS_SEEN_FILE:-${LOG_DIR}/arch-news-last-seen}"

# Palavras que indicam intervenção manual num título de notícia do Arch.
# Mantidas específicas: título de news comum ("... is now available") não casa.
_ARCH_NEWS_ACTION_RE='manual intervention|action required|requires (manual|attention|action)|breaking change|deprecat|incompatib|must be (re)?installed|reinstall required'

# Extrai "epoch|título|link" de cada <item> de um feed RSS do Arch (stdin).
# Puro (sem rede): parseia com awk, sem dependência de xmllint. A data RFC-2822
# do pubDate vira epoch via `date -d` por item (GNU date, presente no Arch).
arch_news_parse() {
  awk 'BEGIN { RS="<item>"; FS="\n" }
    NR > 1 {
      title = ""; link = ""; pub = ""
      if (match($0, /<title>[^<]*<\/title>/)) {
        title = substr($0, RSTART + 7, RLENGTH - 15)
      }
      if (match($0, /<link>[^<]*<\/link>/)) {
        link = substr($0, RSTART + 6, RLENGTH - 13)
      }
      if (match($0, /<pubDate>[^<]*<\/pubDate>/)) {
        pub = substr($0, RSTART + 9, RLENGTH - 19)
      }
      if (title != "" && pub != "") {
        printf "%s|%s|%s\n", pub, title, link
      }
    }' \
  | sed -e 's/&gt;/>/g' -e 's/&lt;/</g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" -e 's/&amp;/\&/g' \
  | while IFS='|' read -r pub title link; do
      local epoch
      epoch="$(date -d "$pub" +%s 2>/dev/null)" || continue
      printf '%s|%s|%s\n' "$epoch" "$title" "$link"
    done
}

# Classifica um título de notícia: "action" (intervenção manual provável) ou
# "info". Puro; case-insensitive.
arch_news_classify() {
  if printf '%s\n' "$1" | grep -qiE "$_ARCH_NEWS_ACTION_RE"; then
    printf 'action'
  else
    printf 'info'
  fi
}

# Checar notícias do Arch Linux.
# Prática clássica pré-`pacman -Syu`: news de "manual intervention" avisam de
# passos manuais que um update às cegas quebraria. Mostra o que for mais novo
# que a última checagem; título com cara de intervenção => RC_TODO.
check_arch_news() {
  local out
  if ! out="$(run_network_cmd curl -fsSL --max-time 20 "$ARCH_NEWS_FEED_URL")"; then
    local rc=$?
    if (( rc == RC_WARN )); then
      log "  Feed de notícias inacessível (rede); seguindo sem checagem."
      return "$RC_WARN"
    fi
    log "  Falha ao baixar o feed de notícias do Arch."
    return "$RC_WARN"
  fi

  local parsed
  parsed="$(printf '%s\n' "$out" | arch_news_parse)"
  if [[ -z "${parsed//[[:space:]]/}" ]]; then
    log "  Feed de notícias vazio ou em formato inesperado; seguindo."
    return "$RC_WARN"
  fi

  local last_seen=0
  [[ -r "$ARCH_NEWS_SEEN_FILE" ]] && last_seen="$(cat "$ARCH_NEWS_SEEN_FILE" 2>/dev/null)"
  [[ "$last_seen" =~ ^[0-9]+$ ]] || last_seen=0

  local newest_epoch=0 fresh_count=0 action_count=0
  local epoch title link kind
  local -a action_lines=() info_lines=()
  while IFS='|' read -r epoch title link; do
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    (( epoch > newest_epoch )) && newest_epoch=$epoch
    (( epoch > last_seen )) || continue
    (( fresh_count++ ))
    kind="$(arch_news_classify "$title")"
    if [[ "$kind" == action ]]; then
      (( action_count++ ))
      action_lines+=("$(date -d "@${epoch}" +%Y-%m-%d 2>/dev/null)  ${title}  ${link}")
    else
      info_lines+=("$(date -d "@${epoch}" +%Y-%m-%d 2>/dev/null)  ${title}")
    fi
  done <<< "$parsed"

  if (( fresh_count == 0 )); then
    log "  Sem notícias novas do Arch desde a última checagem."
    return 0
  fi

  local ln
  if (( ${#info_lines[@]} > 0 )); then
    log "  Notícias novas do Arch (informativas):"
    for ln in "${info_lines[@]}"; do log "    ${ln}"; done
  fi
  if (( ${#action_lines[@]} > 0 )); then
    log "  ${C_YELLOW}Notícias com possível intervenção manual:${C_RESET}"
    for ln in "${action_lines[@]}"; do log "    ${ln}"; done
  fi

  # Marca como visto: a notícia foi exibida; não reprisar a cada run.
  mkdir -p "$(dirname "$ARCH_NEWS_SEEN_FILE")" 2>/dev/null
  printf '%s\n' "$newest_epoch" > "$ARCH_NEWS_SEEN_FILE" 2>/dev/null

  if (( action_count > 0 )); then
    remediation "leia a(s) notícia(s) acima antes de prosseguir: https://archlinux.org/news/"
    STEP_REASON="${action_count} notícia(s) do Arch com possível intervenção manual"
    return "$RC_TODO"
  fi
  return 0
}
