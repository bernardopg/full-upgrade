#!/usr/bin/env bats
# tests/news.bats — helpers puros do step de notícias do Arch
# (lib/steps/news.sh): parser RSS e classificador de título.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/lib/steps/news.sh"
  export LOG_FILE="/dev/null"
}

_sample_feed() {
  cat <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
<title>Arch Linux: Recent news updates</title>
<item>
<title>linux-firmware &gt;= 20250613 requires manual intervention</title>
<link>https://archlinux.org/news/linux-firmware-2025/</link>
<pubDate>Sat, 21 Jun 2025 10:00:00 +0000</pubDate>
</item>
<item>
<title>Plasma 6.1 is now available</title>
<link>https://archlinux.org/news/plasma-61/</link>
<pubDate>Wed, 19 Jun 2024 08:30:00 +0000</pubDate>
</item>
</channel></rss>
EOF
}

@test "arch_news_parse: extrai epoch|título|link por item" {
  run bash -c 'source "'"${FU_ROOT}"'/lib/steps/news.sh"; _sample() { cat; }; arch_news_parse' < <(_sample_feed)
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"|linux-firmware >= 20250613 requires manual intervention|https://archlinux.org/news/linux-firmware-2025/" ]]
  [[ "${lines[0]}" =~ ^[0-9]+\| ]]
  [ "${#lines[@]}" -eq 2 ]
}

@test "arch_news_parse: epoch corresponde ao pubDate" {
  local out
  out="$(_sample_feed | arch_news_parse | head -1)"
  local epoch="${out%%|*}"
  [ "$(date -u -d "@${epoch}" +%Y-%m-%d)" = "2025-06-21" ]
}

@test "arch_news_classify: intervenção manual => action" {
  run arch_news_classify "linux-firmware >= 20250613 requires manual intervention"
  [ "$output" = "action" ]
}

@test "arch_news_classify: release comum => info" {
  run arch_news_classify "Plasma 6.1 is now available"
  [ "$output" = "info" ]
}

@test "arch_news_classify: breaking change => action" {
  run arch_news_classify "OpenSSL 4.0 breaking change in core"
  [ "$output" = "action" ]
}

@test "check_arch_news: notícia action nova => RC_TODO e marca visto" {
  local tmp="$BATS_TEST_TMPDIR"
  ARCH_NEWS_SEEN_FILE="$tmp/seen"
  # stub de curl devolvendo o feed
  mkdir -p "$tmp/bin"
  _sample_feed > "$tmp/feed.xml"
  cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
cat "$tmp/feed.xml"
EOF
  chmod +x "$tmp/bin/curl"
  PATH="$tmp/bin:$PATH"
  QUIET=0
  run check_arch_news
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"intervenção manual"* ]]
  [ -s "$tmp/seen" ]
}

@test "check_arch_news: segunda checagem sem novidade => ok" {
  local tmp="$BATS_TEST_TMPDIR"
  ARCH_NEWS_SEEN_FILE="$tmp/seen"
  mkdir -p "$tmp/bin"
  _sample_feed > "$tmp/feed.xml"
  cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
cat "$tmp/feed.xml"
EOF
  chmod +x "$tmp/bin/curl"
  PATH="$tmp/bin:$PATH"
  QUIET=0
  run check_arch_news
  [ "$status" -eq "$RC_TODO" ]
  run check_arch_news
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem notícias novas"* ]]
}

@test "check_arch_news: feed vazio => RC_WARN" {
  local tmp="$BATS_TEST_TMPDIR"
  ARCH_NEWS_SEEN_FILE="$tmp/seen"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '<rss></rss>\n'
EOF
  chmod +x "$tmp/bin/curl"
  PATH="$tmp/bin:$PATH"
  QUIET=0
  run check_arch_news
  [ "$status" -eq "$RC_WARN" ]
}
