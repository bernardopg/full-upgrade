#!/usr/bin/env bash
# lib/json.sh — logging JSONL + rotação de logs
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

setup_logging() {
  mkdir -p "${LOG_DIR}"
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
  LOG_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.log"
  JSONL_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.jsonl"
  SUDO_KEEPALIVE_PID_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.sudo-keepalive.pid"
  rotate_logs
  touch "$LOG_FILE" "$JSONL_FILE"
  update_latest_links
  write_run_event_json "run_start"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  # JSON (RFC 8259 §7) exige escape de TODOS os control chars < 0x20.
  # Os demais (ex.: ESC 0x1b de cor ANSI vinda de ferramenta externa)
  # invalidariam a linha do JSONL — removemos em vez de escapar, já que
  # não carregam informação útil num log.
  if [[ "$s" == *[$'\001'-$'\010\013\014\016'-$'\037']* ]]; then
    s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  fi
  printf '"%s"' "$s"
}

write_jsonl() {
  printf '%s\n' "$*" >> "$JSONL_FILE"
}

write_run_event_json() {
  local event="$1"
  write_jsonl "$(
    printf '{"event":%s,"run_id":%s,"timestamp":%s,"script_version":%s,"script_path":%s,"script_sha256":%s,"log_file":%s,"jsonl_file":%s,"pid":%s}\n' \
      "$(json_escape "$event")" \
      "$(json_escape "$RUN_ID")" \
      "$(json_escape "$(date -Is)")" \
      "$(json_escape "$SCRIPT_VERSION")" \
      "$(json_escape "$SCRIPT_PATH")" \
      "$(json_escape "$SCRIPT_SHA256")" \
      "$(json_escape "$LOG_FILE")" \
      "$(json_escape "$JSONL_FILE")" \
      "$$"
  )"
}

write_step_event_json() {
  local name="$1"
  local status="$2"
  local duration="$3"
  local rc="$4"
  local reason="$5"
  local command="${6:-}"
  local category tags effect timeout cmd_deps func_name desc

  IFS='|' read -r category tags effect timeout cmd_deps func_name desc < <(catalog_info_for_step "$name")
  [[ -z "$command" ]] && command="$func_name"

  write_jsonl "$(
    printf '{"event":"step","run_id":%s,"timestamp":%s,"step":%s,"status":%s,"duration_seconds":%s,"exit_code":%s,"reason":%s,"category":%s,"tags":%s,"effect":%s,"timeout":%s,"cmd_deps":%s,"func_name":%s,"command":%s,"description":%s,"started_at":%s}\n' \
      "$(json_escape "$RUN_ID")" \
      "$(json_escape "$(date -Is)")" \
      "$(json_escape "$name")" \
      "$(json_escape "$status")" \
      "$duration" \
      "$rc" \
      "$(json_escape "$reason")" \
      "$(json_escape "$category")" \
      "$(json_escape "$tags")" \
      "$(json_escape "$effect")" \
      "${timeout:-0}" \
      "$(json_escape "$cmd_deps")" \
      "$(json_escape "$func_name")" \
      "$(json_escape "$command")" \
      "$(json_escape "$desc")" \
      "$(json_escape "$STEP_START_ISO")"
  )"
}

summary_json_line() {
  local ok="$1"
  local warn="$2"
  local todo="$3"
  local fail="$4"
  local skip="$5"
  local duration="$6"

  printf '{"event":"summary","run_id":%s,"timestamp":%s,"ok":%s,"warn":%s,"todo":%s,"fail":%s,"skip":%s,"duration_seconds":%s,"has_fail":%s,"log_file":%s,"jsonl_file":%s}' \
    "$(json_escape "$RUN_ID")" \
    "$(json_escape "$(date -Is)")" \
    "$ok" "$warn" "$todo" "$fail" "$skip" "$duration" "$HAS_FAIL" \
    "$(json_escape "$LOG_FILE")" \
    "$(json_escape "$JSONL_FILE")"
}

write_summary_event_json() {
  write_jsonl "$(summary_json_line "$@")"
}

update_latest_links() {
  ln -sfn -- "$LOG_FILE" "$LATEST_LOG_LINK"
  ln -sfn -- "$JSONL_FILE" "$LATEST_JSONL_LINK"
}

rotate_logs() {
  # find + sort por mtime no lugar de ls -1t: parsing de ls é frágil e o glob
  # sem match ecoava erro suprimido. Mantém os MAX_LOGS mais novos de cada tipo.
  local ext old
  for ext in log jsonl; do
    while IFS= read -r old; do
      [[ -n "$old" ]] && rm -f -- "$old"
    done < <(
      find "$LOG_DIR" -maxdepth 1 -name "full-upgrade-*.${ext}" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2- | tail -n +"$(( MAX_LOGS + 1 ))"
    )
  done
}
