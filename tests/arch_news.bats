#!/usr/bin/env bats
# tests/arch_news.bats — checagem de Arch News pré-upgrade (I1).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/news.sh"
  QUIET=0
  STEP_REASON=""
  LOG_DIR="$(mktemp -d)"
  ARCH_NEWS_STATE="${LOG_DIR}/arch-news-last"
  RSS="$(cat <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
<item><title>Notícia antiga</title><link>https://archlinux.org/news/a/</link><pubDate>Mon, 01 Jan 2024 10:00:00 +0000</pubDate></item>
<item><title>Intervenção manual necessária</title><link>https://archlinux.org/news/b/</link><pubDate>Wed, 18 Jun 2025 12:00:00 +0000</pubDate></item>
<item><title>Troca de chaves do keyring</title><link>https://archlinux.org/news/c/</link><pubDate>Fri, 20 Jun 2025 08:00:00 +0000</pubDate></item>
</channel></rss>
XML
)"
}

teardown() {
  [[ -n "${LOG_DIR:-}" ]] && rm -rf "$LOG_DIR"
}

# ── parser puro parse_arch_news_rss ───────────────────────────────────────────

@test "parse: cutoff 0 retorna todos os itens com pubDate" {
  run bash -c 'source '"${FU_LIB}"'/globals.sh; source '"${FU_LIB}"'/steps/news.sh; parse_arch_news_rss 0 <<<'"'"''"$RSS"''"'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Intervenção manual necessária"* ]]
  [[ "$output" == *"Troca de chaves do keyring"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '	')" -eq 3 ]
}

@test "parse: cutoff recente filtra os antigos" {
  # cutoff = 2025-06-19 → só a notícia de 2025-06-20 passa
  local cut; cut="$(LC_ALL=C date -d '2025-06-19 00:00:00 +0000' +%s)"
  out="$(parse_arch_news_rss "$cut" <<< "$RSS")"
  [[ "$out" == *"Troca de chaves do keyring"* ]]
  [[ "$out" != *"Intervenção manual"* ]]
  [ "$(printf '%s\n' "$out" | grep -c '	')" -eq 1 ]
}

@test "parse: RSS sem itens => vazio" {
  out="$(printf '<rss><channel></channel></rss>' | parse_arch_news_rss 0)"
  [ -z "$out" ]
}

# ── step check_arch_news ──────────────────────────────────────────────────────

@test "step: news nova vira RC_TODO e grava estado" {
  has() { [[ "$1" == curl ]]; }
  run_network_cmd() { printf '%s\n' "$RSS"; return 0; }
  run check_arch_news
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"nova(s) Arch News"* ]]
  [ -f "$ARCH_NEWS_STATE" ]
}

@test "step: segunda checagem sem novidade vira 0" {
  has() { [[ "$1" == curl ]]; }
  run_network_cmd() { printf '%s\n' "$RSS"; return 0; }
  check_arch_news >/dev/null || true    # 1ª: grava o epoch mais novo (RC_TODO)
  run check_arch_news                   # 2ª: cutoff = mais novo → nada novo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem novas Arch News"* ]]
}

@test "step: falha de rede vira RC_WARN" {
  has() { [[ "$1" == curl ]]; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run check_arch_news
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}

@test "step: sem curl retorna 0" {
  has() { return 1; }
  run check_arch_news
  [ "$status" -eq 0 ]
}
