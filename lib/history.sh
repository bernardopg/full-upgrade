#!/usr/bin/env bash
# lib/history.sh — tendência/histórico de runs a partir dos JSONL rotacionados.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Lista os N JSONL de run mais recentes (por mtime), um caminho por linha,
# do mais novo para o mais antigo. Ignora o symlink latest.jsonl (não é -type f
# real do find quando aponta para fora? é; mas os arquivos reais bastam).
_history_jsonl_files() {
  local n="$1"
  find "$LOG_DIR" -maxdepth 1 -name 'full-upgrade-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -n "$n" | cut -d' ' -f2-
}

# Extrai de um JSONL a linha TSV do run:
#   version<TAB>date<TAB>ok<TAB>warn<TAB>todo<TAB>fail<TAB>skip<TAB>duration
# Lê script_version/timestamp do run_start e as contagens do summary.
_history_row_for() {
  awk '
    function jnum(line, key,   p, c, o, kk) {
      kk = "\"" key "\":"; p = index(line, kk); if (!p) return ""
      p += length(kk); o = ""
      while (p <= length(line)) { c = substr(line, p, 1)
        if (c ~ /[0-9.\-]/) o = o c; else break; p++ }
      return o
    }
    function jstr(line, key,   p, c, o, kk) {
      kk = "\"" key "\":\""; p = index(line, kk); if (!p) return ""
      p += length(kk); o = ""
      while (p <= length(line)) { c = substr(line, p, 1)
        if (c == "\"") break
        if (c == "\\") { p++; c = substr(line, p, 1) }
        o = o c; p++ }
      return o
    }
    /"event":"run_start"/ { if (ver == "") ver = jstr($0, "script_version"); if (sdate == "") sdate = jstr($0, "timestamp") }
    /"event":"summary"/ {
      ok = jnum($0, "ok"); warn = jnum($0, "warn"); todo = jnum($0, "todo")
      fail = jnum($0, "fail"); skip = jnum($0, "skip"); dur = jnum($0, "duration_seconds")
      if (mdate == "") mdate = jstr($0, "timestamp")
      seen = 1
    }
    END {
      if (!seen) exit 1   # sem summary: run incompleto, ignora
      d = (sdate != "") ? sdate : mdate
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", (ver == "" ? "—" : ver), d, ok, warn, todo, fail, skip, dur
    }
  ' "$1"
}

# Emite (stdout) os nomes de step com status warn/todo de um JSONL, deduplicados
# dentro do run. Usado para detectar recorrências entre runs.
_history_warn_todo_steps() {
  awk '
    function jstr(line, key,   p, c, o, kk) {
      kk = "\"" key "\":\""; p = index(line, kk); if (!p) return ""
      p += length(kk); o = ""
      while (p <= length(line)) { c = substr(line, p, 1)
        if (c == "\"") break
        if (c == "\\") { p++; c = substr(line, p, 1) }
        o = o c; p++ }
      return o
    }
    /"event":"step"/ {
      st = jstr($0, "status")
      if (st == "warn" || st == "todo") print jstr($0, "step")
    }
  ' "$1" | sort -u
}

# F8 — tabela/tendência dos últimos N runs. Read-only, sem rede.
report_history() {
  local n="${1:-10}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=10
  (( n < 1 )) && n=1

  local -a files=()
  mapfile -t files < <(_history_jsonl_files "$n")
  if (( ${#files[@]} == 0 )); then
    printf 'full-upgrade: nenhum run encontrado em %s\n' "$LOG_DIR" >&2
    printf '  Rode o full-upgrade ao menos uma vez para gerar histórico.\n' >&2
    return 1
  fi

  local -a vers dates oks warns todos fails skips durs
  local f row v d ok wa to fa sk du
  for f in "${files[@]}"; do
    row="$(_history_row_for "$f")" || continue   # pula runs sem summary
    IFS=$'\t' read -r v d ok wa to fa sk du <<< "$row"
    vers+=("$v"); dates+=("$d"); oks+=("$ok"); warns+=("$wa")
    todos+=("$to"); fails+=("$fa"); skips+=("$sk"); durs+=("$du")
  done

  if (( ${#vers[@]} == 0 )); then
    printf 'full-upgrade: nenhum run com resumo (summary) encontrado.\n' >&2
    return 1
  fi

  printf 'Histórico dos últimos %d run(s) — %s\n\n' "${#vers[@]}" "$LOG_DIR"
  printf '%-16s  %-12s  %3s %4s %4s %4s %4s  %9s\n' "DATA" "VERSÃO" "ok" "warn" "todo" "fail" "skip" "DURAÇÃO"
  printf '%-16s  %-12s  %3s %4s %4s %4s %4s  %9s\n' "----" "------" "---" "----" "----" "----" "----" "-------"
  local i dshort
  for i in "${!vers[@]}"; do
    dshort="${dates[$i]:0:16}"; dshort="${dshort/T/ }"
    printf '%-16s  %-12s  %3s %4s %4s %4s %4s  %9s\n' \
      "$dshort" "${vers[$i]}" "${oks[$i]}" "${warns[$i]}" "${todos[$i]}" \
      "${fails[$i]}" "${skips[$i]}" "$(elapsed "${durs[$i]}")"
  done

  # ── Tendência de duração: run mais recente vs. anterior ──
  if (( ${#durs[@]} >= 2 )); then
    local delta=$(( durs[0] - durs[1] )) arrow
    if (( delta > 0 )); then arrow="↑ +$(elapsed "$delta")"
    elif (( delta < 0 )); then arrow="↓ -$(elapsed "$(( -delta ))")"
    else arrow="estável"; fi
    printf '\nTendência de duração: %s → %s (%s).\n' \
      "$(elapsed "${durs[1]}")" "$(elapsed "${durs[0]}")" "$arrow"
  fi

  # ── Warns/todos recorrentes (em >=2 runs) ──
  local -a recur=()
  mapfile -t recur < <(
    for f in "${files[@]}"; do
      _history_warn_todo_steps "$f"
    done | sort | uniq -c | sort -rn | awk '$1 >= 2 { c = $1; $1 = ""; sub(/^ +/, ""); printf "%d× %s\n", c, $0 }'
  )
  if (( ${#recur[@]} > 0 )); then
    printf '\nWarns/todos recorrentes (em ≥2 runs):\n'
    for row in "${recur[@]}"; do
      printf '  %s\n' "$row"
    done
  fi

  return 0
}
