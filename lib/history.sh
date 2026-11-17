#!/usr/bin/env bash
# lib/history.sh — tendência/histórico de runs a partir dos JSONL rotacionados.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Lista os N JSONL de run mais recentes (por mtime), um caminho por linha,
# do mais novo para o mais antigo. Ignora o symlink latest.jsonl (não é -type f
# real do find quando aponta para fora? é; mas os arquivos reais bastam).
_history_jsonl_files() {
  local n="$1" f
  # Descarta dry-runs: eles têm a forma de um run real (todo step vira skip) e
  # entrariam na tabela como um run de 5s com 0 ok, sujando também a tendência.
  # O head vem DEPOIS do filtro, senão N dry-runs seguidos zeravam o histórico.
  while IFS= read -r f; do
    jsonl_is_dry_run "$f" && continue
    printf '%s\n' "$f"
  done < <(
    find "$LOG_DIR" -maxdepth 1 -name 'full-upgrade-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | cut -d' ' -f2-
  ) | head -n "$n"
}

# Extrai de um JSONL a linha TSV do run:
#   version<TAB>date<TAB>ok<TAB>warn<TAB>todo<TAB>fail<TAB>skip<TAB>duration<TAB>scope
# Lê script_version/timestamp/scope do run_start e as contagens do summary.
# Runs gravados antes do campo scope saem com "—".
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
    /"event":"run_start"/ {
      if (ver == "") ver = jstr($0, "script_version")
      if (sdate == "") sdate = jstr($0, "timestamp")
      if (scope == "") scope = jstr($0, "scope")
    }
    /"event":"summary"/ {
      ok = jnum($0, "ok"); warn = jnum($0, "warn"); todo = jnum($0, "todo")
      fail = jnum($0, "fail"); skip = jnum($0, "skip"); dur = jnum($0, "duration_seconds")
      if (mdate == "") mdate = jstr($0, "timestamp")
      seen = 1
    }
    END {
      if (!seen) exit 1   # sem summary: run incompleto, ignora
      d = (sdate != "") ? sdate : mdate
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", (ver == "" ? "—" : ver), d, ok, warn, todo, fail, skip, dur, (scope == "" ? "—" : scope)
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

# Uma linha da tabela do --history, alinhada por caractere.
_history_line() {
  printf '%s  %s  %s  %s %s %s %s %s  %s\n' \
    "$(ui_pad "$1" 16)" "$(ui_pad "$2" 12)" "$(ui_pad "$3" 9)" \
    "$(ui_pad_left "$4" 3)" "$(ui_pad_left "$5" 4)" "$(ui_pad_left "$6" 4)" \
    "$(ui_pad_left "$7" 4)" "$(ui_pad_left "$8" 4)" "$(ui_pad_left "$9" 9)"
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

  local -a vers dates oks warns todos fails skips durs scopes
  local f row v d ok wa to fa sk du sc
  for f in "${files[@]}"; do
    row="$(_history_row_for "$f")" || continue   # pula runs sem summary
    IFS=$'\t' read -r v d ok wa to fa sk du sc <<< "$row"
    vers+=("$v"); dates+=("$d"); oks+=("$ok"); warns+=("$wa")
    todos+=("$to"); fails+=("$fa"); skips+=("$sk"); durs+=("$du"); scopes+=("${sc:-—}")
  done

  if (( ${#vers[@]} == 0 )); then
    printf 'full-upgrade: nenhum run com resumo (summary) encontrado.\n' >&2
    return 1
  fi

  # J2 — saída JSON estruturada quando --json acompanha --history.
  if (( ${JSON_SUMMARY:-0} == 1 )); then
    printf '{"runs":['
    for i in "${!vers[@]}"; do
      (( i > 0 )) && printf ','
      printf '{"version":"%s","timestamp":"%s","scope":"%s","ok":%d,"warn":%d,"todo":%d,"fail":%d,"skip":%d,"duration_seconds":%d}' \
        "${vers[$i]}" "${dates[$i]}" "${scopes[$i]/—/}" \
        "${oks[$i]}" "${warns[$i]}" "${todos[$i]}" "${fails[$i]}" "${skips[$i]}" "${durs[$i]}"
    done
    printf ']}\n'
    return 0
  fi

  printf 'Histórico dos últimos %d run(s) — %s\n\n' "${#vers[@]}" "$LOG_DIR"
  # ui_pad conta caracteres: o printf %-Ns do Bash conta bytes e desalinhava as
  # colunas depois de "VERSÃO"/"DURAÇÃO" e de versões "—".
  _history_line "DATA" "VERSÃO" "ESCOPO" "ok" "warn" "todo" "fail" "skip" "DURAÇÃO"
  _history_line "----" "------" "------" "---" "----" "----" "----" "----" "-------"
  local i dshort
  for i in "${!vers[@]}"; do
    dshort="${dates[$i]:0:16}"; dshort="${dshort/T/ }"
    _history_line "$dshort" "${vers[$i]}" "${scopes[$i]}" "${oks[$i]}" "${warns[$i]}" \
      "${todos[$i]}" "${fails[$i]}" "${skips[$i]}" "$(elapsed "${durs[$i]}")"
  done

  # ── Tendência de duração: run mais recente vs. o anterior COMPARÁVEL ──
  # Comparar com o run imediatamente anterior mentia quando esse anterior era
  # filtrado: um `--only doctor` de 5s virava "5s → 7m 10s (↑ +7m 05s)", como se
  # o upgrade tivesse ficado 85× mais lento. Compara-se com o run anterior mais
  # recente que executou um número de steps parecido (≥50% do atual).
  if (( ${#durs[@]} >= 2 )); then
    local ran0=$(( oks[0] + warns[0] + todos[0] + fails[0] ))
    local j prev=-1
    for (( j = 1; j < ${#durs[@]}; j++ )); do
      local ranj=$(( oks[j] + warns[j] + todos[j] + fails[j] ))
      # Escopo gravado nos dois runs e diferente (ex.: doctor x completo): não
      # compara. Runs antigos sem escopo ("—") caem na heurística de contagem.
      [[ "${scopes[0]}" != "—" && "${scopes[j]}" != "—" && "${scopes[0]}" != "${scopes[j]}" ]] && continue
      # Run atual parcial (doctor, filtrado…) não se compara a um run antigo de
      # escopo desconhecido: a heurística de contagem só vale para "completo".
      [[ "${scopes[0]}" != "—" && "${scopes[0]}" != "completo" && "${scopes[j]}" == "—" ]] && continue
      if (( ran0 == 0 || ranj * 2 >= ran0 )); then prev=$j; break; fi
    done

    if (( prev < 0 )); then
      printf '\nTendência de duração: sem run anterior de escopo comparável (%d step(s) executado(s)).\n' "$ran0"
    else
      local delta=$(( durs[0] - durs[prev] )) arrow
      if (( delta > 0 )); then arrow="↑ +$(elapsed "$delta")"
      elif (( delta < 0 )); then arrow="↓ -$(elapsed "$(( -delta ))")"
      else arrow="estável"; fi
      printf '\nTendência de duração: %s → %s (%s).\n' \
        "$(elapsed "${durs[$prev]}")" "$(elapsed "${durs[0]}")" "$arrow"
      (( prev > 1 )) && printf 'Comparado com o run de %s: os %d run(s) entre eles rodaram com filtro.\n' \
        "${dates[$prev]:0:16}" "$(( prev - 1 ))"
    fi
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
