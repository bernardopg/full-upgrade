#!/usr/bin/env bash
# lib/report.sh — geração de relatório Markdown a partir do JSONL de um run.
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Resolve o JSONL a usar no relatório:
#   - se <run_id> dado: tenta full-upgrade-<run_id>.jsonl, depois match parcial;
#   - senão: o symlink latest.jsonl, ou o JSONL mais novo em LOG_DIR.
# Emite o caminho em stdout (rc 0) ou nada (rc 1).
_report_resolve_jsonl() {
  local from="$1" f
  if [[ -n "$from" ]]; then
    f="${LOG_DIR}/full-upgrade-${from}.jsonl"
    [[ -r "$f" ]] && { printf '%s' "$f"; return 0; }
    # match parcial: run_id pode ser só o prefixo de data (ex.: 20260613-142301)
    f="$(find "$LOG_DIR" -maxdepth 1 -name "full-upgrade-*${from}*.jsonl" -type f 2>/dev/null \
          | sort | tail -n1)"
    [[ -n "$f" && -r "$f" ]] && { printf '%s' "$f"; return 0; }
    return 1
  fi
  if [[ -r "$LATEST_JSONL_LINK" ]]; then
    printf '%s' "$LATEST_JSONL_LINK"; return 0
  fi
  f="$(find "$LOG_DIR" -maxdepth 1 -name 'full-upgrade-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n1 | cut -d' ' -f2-)"
  [[ -n "$f" && -r "$f" ]] && { printf '%s' "$f"; return 0; }
  return 1
}

# Converte um JSONL de run (eventos run_start/step/summary/run_end) em Markdown.
# Lê o arquivo passado em $1 e emite o relatório em stdout. Pura quanto a estado
# do processo (só lê o arquivo); testável via bats com um JSONL de fixture.
report_markdown_from_jsonl() {
  local jsonl="$1"
  [[ -r "$jsonl" ]] || return 1
  awk '
    function fmt_dur(s,   m) {
      s = s + 0
      if (s >= 60) { m = int(s / 60); return m "m " sprintf("%02d", s % 60) "s" }
      return s "s"
    }
    # Extrai o valor string da chave <key> de uma linha JSON plana, decodificando
    # os escapes que json_escape() produz (\\ \" \n \r \t). Vazio se ausente.
    function json_str(line, key,   p, c, out, esc, kk) {
      kk = "\"" key "\":\""
      p = index(line, kk)
      if (p == 0) return ""
      p += length(kk)
      out = ""; esc = 0
      while (p <= length(line)) {
        c = substr(line, p, 1)
        if (esc) {
          if (c == "n" || c == "t" || c == "r") out = out " "
          else out = out c
          esc = 0
        } else if (c == "\\") { esc = 1 }
        else if (c == "\"") { break }
        else { out = out c }
        p++
      }
      return out
    }
    # Extrai o valor numérico da chave <key> (primeira ocorrência). Vazio se ausente.
    function json_num(line, key,   p, c, out, kk) {
      kk = "\"" key "\":"
      p = index(line, kk)
      if (p == 0) return ""
      p += length(kk)
      out = ""
      while (p <= length(line)) {
        c = substr(line, p, 1)
        if (c ~ /[0-9]/ || c == "." || c == "-") out = out c
        else break
        p++
      }
      return out
    }
    function md_cell(s) { gsub(/\|/, "\\|", s); return s }

    /"event":"run_start"/ {
      version  = json_str($0, "script_version")
      run_id   = json_str($0, "run_id")
      start_ts = json_str($0, "timestamp")
      log_file = json_str($0, "log_file")
      next
    }
    /"event":"run_end"/   { end_ts = json_str($0, "timestamp"); next }
    /"event":"step"/ {
      n++
      st_name[n]   = json_str($0, "step")
      st_status[n] = json_str($0, "status")
      st_dur[n]    = json_num($0, "duration_seconds")
      st_reason[n] = json_str($0, "reason")
      next
    }
    /"event":"summary"/ {
      s_ok = json_num($0, "ok"); s_warn = json_num($0, "warn")
      s_todo = json_num($0, "todo"); s_fail = json_num($0, "fail")
      s_skip = json_num($0, "skip"); s_dur = json_num($0, "duration_seconds")
      has_summary = 1
      next
    }
    END {
      # Contagens de fallback a partir dos próprios steps (run sem evento summary).
      c_ok = c_warn = c_todo = c_fail = c_skip = 0
      c_note = 0
      for (i = 1; i <= n; i++) {
        s = st_status[i]
        if (s == "ok") c_ok++
        else if (s == "warn") c_warn++
        else if (s == "todo") c_todo++
        else if (s == "fail") c_fail++
        else if (s == "skip") c_skip++
        if (s == "ok" && st_reason[i] != "") c_note++
      }
      if (!has_summary) {
        s_ok = c_ok; s_warn = c_warn; s_todo = c_todo; s_fail = c_fail; s_skip = c_skip
      }

      if (run_id == "") run_id = "(desconhecido)"
      print "# Relatório full-upgrade — " run_id
      print ""
      print "- **Versão:** " (version == "" ? "—" : version)
      if (start_ts != "") print "- **Início:** " start_ts
      if (end_ts != "")   print "- **Fim:** " end_ts
      if (has_summary)    print "- **Duração:** " fmt_dur(s_dur)
      print "- **Resultado:** " s_ok " ok · " s_warn " warn · " s_todo " todo · " s_fail " fail · " s_skip " skip"
      if (log_file != "") print "- **Log:** `" log_file "`"
      print ""

      print "## Steps"
      print ""
      print "| Status | Step | Tempo | Motivo |"
      print "|--------|------|-------|--------|"
      for (i = 1; i <= n; i++) {
        print "| " st_status[i] " | " md_cell(st_name[i]) " | " fmt_dur(st_dur[i]) " | " md_cell(st_reason[i]) " |"
      }
      print ""

      if (c_fail > 0) {
        print "## Falhas"
        print ""
        for (i = 1; i <= n; i++) if (st_status[i] == "fail")
          print "- **" md_cell(st_name[i]) "**" (st_reason[i] == "" ? "" : ": " st_reason[i])
        print ""
      }
      if (c_todo > 0) {
        print "## Pendências (ação manual)"
        print ""
        for (i = 1; i <= n; i++) if (st_status[i] == "todo")
          print "- **" md_cell(st_name[i]) "**" (st_reason[i] == "" ? "" : ": " st_reason[i])
        print ""
      }
      if (c_warn > 0) {
        print "## Avisos"
        print ""
        for (i = 1; i <= n; i++) if (st_status[i] == "warn")
          print "- **" md_cell(st_name[i]) "**" (st_reason[i] == "" ? "" : ": " st_reason[i])
        print ""
      }
      if (c_note > 0) {
        print "## Notas operacionais"
        print ""
        for (i = 1; i <= n; i++) if (st_status[i] == "ok" && st_reason[i] != "")
          print "- **" md_cell(st_name[i]) "**: " st_reason[i]
        print ""
      }
    }
  ' "$jsonl"
}

# Orquestra --report: resolve o JSONL (latest ou --from), gera o Markdown e
# grava em <outfile> (ou stdout se vazio). Mensagens de erro em PT-BR.
generate_report() {
  local from="$1" outfile="$2" jsonl
  jsonl="$(_report_resolve_jsonl "$from")" || {
    if [[ -n "$from" ]]; then
      printf 'full-upgrade: JSONL não encontrado para run_id: %s\n' "$from" >&2
    else
      printf 'full-upgrade: nenhum JSONL de run encontrado em %s\n' "$LOG_DIR" >&2
      printf '  Rode o full-upgrade ao menos uma vez para gerar eventos.\n' >&2
    fi
    return 1
  }

  local formatter
  if (( ${JSON_SUMMARY:-0} == 1 )); then
    formatter="report_json_from_jsonl"
  else
    formatter="report_markdown_from_jsonl"
  fi

  if [[ -n "$outfile" ]]; then
    if "$formatter" "$jsonl" > "$outfile"; then
      printf 'Relatório gravado: %s\n' "$outfile"
      printf '  Fonte: %s\n' "$jsonl"
      return 0
    fi
    printf 'full-upgrade: falha ao gravar relatório em %s\n' "$outfile" >&2
    return 1
  fi

  "$formatter" "$jsonl"
}

# J2 — Converte um JSONL de run em um objeto JSON estruturado (metadata +
# summary + steps[]). Reaproveita os mesmos extratores do Markdown, mas emite
# JSON válido (com re-escape de strings via json_escape_out). Pura: só lê $1.
report_json_from_jsonl() {
  local jsonl="$1"
  [[ -r "$jsonl" ]] || return 1
  awk '
    function json_str(line, key,   p, c, out, esc, kk) {
      kk = "\"" key "\":\""
      p = index(line, kk)
      if (p == 0) return ""
      p += length(kk)
      out = ""; esc = 0
      while (p <= length(line)) {
        c = substr(line, p, 1)
        if (esc) {
          if (c == "n" || c == "t" || c == "r") out = out " "
          else out = out c
          esc = 0
        } else if (c == "\\") { esc = 1 }
        else if (c == "\"") { break }
        else { out = out c }
        p++
      }
      return out
    }
    function json_num(line, key,   p, c, out, kk) {
      kk = "\"" key "\":"
      p = index(line, kk)
      if (p == 0) return ""
      p += length(kk)
      out = ""
      while (p <= length(line)) {
        c = substr(line, p, 1)
        if (c ~ /[0-9]/ || c == "." || c == "-") out = out c
        else break
        p++
      }
      return out
    }
    # Re-escape para saída JSON: aspas, barra invertida e controles whitespace.
    function je(s,   r, i, c) {
      r = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") r = r "\\\""
        else if (c == "\\") r = r "\\\\"
        else if (c == "\n") r = r "\\n"
        else if (c == "\r") r = r "\\r"
        else if (c == "\t") r = r "\\t"
        else r = r c
      }
      return r
    }

    /"event":"run_start"/ {
      version  = json_str($0, "script_version")
      run_id   = json_str($0, "run_id")
      start_ts = json_str($0, "timestamp")
      next
    }
    /"event":"run_end"/   { end_ts = json_str($0, "timestamp"); next }
    /"event":"step"/ {
      n++
      st_name[n]   = json_str($0, "step")
      st_status[n] = json_str($0, "status")
      st_dur[n]    = json_num($0, "duration_seconds")
      st_reason[n] = json_str($0, "reason")
      next
    }
    /"event":"summary"/ {
      s_ok = json_num($0, "ok"); s_warn = json_num($0, "warn")
      s_todo = json_num($0, "todo"); s_fail = json_num($0, "fail")
      s_skip = json_num($0, "skip"); s_dur = json_num($0, "duration_seconds")
      has_summary = 1
      next
    }
    END {
      c_ok = c_warn = c_todo = c_fail = c_skip = 0
      for (i = 1; i <= n; i++) {
        s = st_status[i]
        if (s == "ok") c_ok++
        else if (s == "warn") c_warn++
        else if (s == "todo") c_todo++
        else if (s == "fail") c_fail++
        else if (s == "skip") c_skip++
      }
      if (!has_summary) {
        s_ok = c_ok; s_warn = c_warn; s_todo = c_todo; s_fail = c_fail; s_skip = c_skip
      }

      printf "{\"run_id\":\"%s\"", je(run_id)
      printf ",\"script_version\":\"%s\"", je(version)
      if (start_ts != "") printf ",\"start\":\"%s\"", je(start_ts)
      if (end_ts != "")   printf ",\"end\":\"%s\"", je(end_ts)
      if (has_summary)    printf ",\"duration_seconds\":%d", s_dur + 0
      printf ",\"summary\":{\"ok\":%d,\"warn\":%d,\"todo\":%d,\"fail\":%d,\"skip\":%d}", \
        s_ok + 0, s_warn + 0, s_todo + 0, s_fail + 0, s_skip + 0
      printf ",\"steps\":["
      for (i = 1; i <= n; i++) {
        if (i > 1) printf ","
        printf "{\"step\":\"%s\",\"status\":\"%s\",\"duration_seconds\":%d,\"reason\":\"%s\"}", \
          je(st_name[i]), je(st_status[i]), st_dur[i] + 0, je(st_reason[i])
      }
      printf "]}\n"
    }
  ' "$jsonl"
}

# G3 — grava automaticamente o relatório Markdown do run recém-concluído quando
# REPORT_ON_FINISH=1. Usa o JSONL do run corrente ($JSONL_FILE) diretamente, sem
# resolução. Chamada de finalize(), depois do evento run_end. Nunca derruba o run:
# falhas só logam. Emite (stdout) o caminho do .md em sucesso.
generate_report_on_finish() {
  (( ${REPORT_ON_FINISH:-0} == 1 )) || return 0
  local jsonl="${JSONL_FILE:-}" outfile
  if [[ -z "$jsonl" || ! -r "$jsonl" ]]; then
    log "  REPORT_ON_FINISH: JSONL do run indisponível; relatório não gerado."
    return 0
  fi
  outfile="${LOG_DIR}/full-upgrade-${RUN_ID}.md"
  if report_markdown_from_jsonl "$jsonl" > "$outfile" 2>/dev/null; then
    log "  Relatório do run gravado: ${outfile}"
  else
    log "  REPORT_ON_FINISH: falha ao gerar o relatório do run."
    rm -f "$outfile" 2>/dev/null || true
  fi
  return 0
}
