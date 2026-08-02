#!/usr/bin/env bash
# lib/json.sh — logging JSONL + rotação de logs
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

setup_logging() {
  mkdir -p "${LOG_DIR}"
  RUN_START_ISO="$(date -Is)"
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
  LOG_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.log"
  JSONL_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.jsonl"
  SUDO_KEEPALIVE_PID_FILE="${LOG_DIR}/full-upgrade-${RUN_ID}.sudo-keepalive.pid"
  PKG_SNAP_BEFORE="${LOG_DIR}/full-upgrade-${RUN_ID}.pkgs-before"  # L3: snapshot pré-upgrade
  PKG_SNAP_AFTER="${LOG_DIR}/full-upgrade-${RUN_ID}.pkgs-after"    # L3: snapshot pós-run
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
    printf '{"event":%s,"run_id":%s,"timestamp":%s,"script_version":%s,"script_path":%s,"script_sha256":%s,"log_file":%s,"jsonl_file":%s,"dry_run":%s,"pid":%s}\n' \
      "$(json_escape "$event")" \
      "$(json_escape "$RUN_ID")" \
      "$(json_escape "$(date -Is)")" \
      "$(json_escape "$SCRIPT_VERSION")" \
      "$(json_escape "$SCRIPT_PATH")" \
      "$(json_escape "$SCRIPT_SHA256")" \
      "$(json_escape "$LOG_FILE")" \
      "$(json_escape "$JSONL_FILE")" \
      "$( (( DRY_RUN )) && printf 'true' || printf 'false' )" \
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

  printf '{"event":"summary","run_id":%s,"timestamp":%s,"ok":%s,"warn":%s,"todo":%s,"fail":%s,"skip":%s,"duration_seconds":%s,"has_fail":%s,"category_totals":%s,"slowest_steps":%s,"reboot_recommendation":%s,"log_file":%s,"jsonl_file":%s}' \
    "$(json_escape "$RUN_ID")" \
    "$(json_escape "$(date -Is)")" \
    "$ok" "$warn" "$todo" "$fail" "$skip" "$duration" "$HAS_FAIL" \
    "$(summary_category_totals_json)" \
    "$(summary_slowest_steps_json)" \
    "$(json_escape "${REBOOT_RECOMMENDATION:-}")" \
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

# Verdadeiro (rc 0) se o JSONL $1 é de um `--dry-run`. Um dry-run grava um JSONL
# com a mesma forma de um run real (todo step vira skip), então quem consome o
# histórico precisa distinguir os dois — senão um dry-run de 5s entra na tabela
# do --history, distorce a tendência de duração e vira o alvo do `--report` sem
# --from. Predicado único: o tray já filtrava assim por conta própria, history e
# report não filtravam de jeito nenhum.
jsonl_is_dry_run() {
  [[ -r "${1:-}" ]] || return 1
  grep -q '"dry_run":true' <<<"$(grep -m1 '"event":"run_start"' "$1" 2>/dev/null)"
}

# Extrai o RUN_ID (AAAAMMDD-HHMMSS-PID) embutido no nome de um artefato por-run.
# Todo artefato de um run carrega o RUN_ID no nome — inclusive os escritos por
# plugins de steps.d/ (ex.: hermes-update-<RUN_ID>.log). Emite vazio para nomes
# que não são artefatos de run (arch-news-last, webkit-rebuild.log…), que é o
# que impede a rotação de tocar em arquivo que não é dela.
run_id_from_artifact() {
  local base="${1##*/}"
  [[ "$base" =~ ([0-9]{8}-[0-9]{6}-[0-9]+) ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# Mantém em LOG_DIR os artefatos dos MAX_LOGS runs mais recentes e apaga os dos
# runs mais antigos.
#
# Antes isto era uma lista fixa de extensões (`log jsonl md pkgs-before …`) com
# glob `full-upgrade-*`, e vazava por duas frestas ao mesmo tempo: extensão nova
# esquecida na lista (114 `.aur-out-of-date` e 8 `.pacfiles-todo` acumulados) e
# artefato com outro prefixo (213 `hermes-update-*.log` de um plugin de
# steps.d/). Agrupar por RUN_ID cobre os dois casos e qualquer artefato futuro
# sem precisar lembrar de registrar nada.
rotate_logs() {
  [[ -d "${LOG_DIR:-}" ]] || return 0

  local -a all_runs=()
  mapfile -t all_runs < <(
    find "$LOG_DIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
      | grep -oE '[0-9]{8}-[0-9]{6}-[0-9]+' | sort -ru
  )
  (( ${#all_runs[@]} > MAX_LOGS )) || return 0

  # RUN_IDs a apagar = todos menos os MAX_LOGS mais recentes. O run atual é o
  # mais novo e portanto fica; ainda assim é protegido explicitamente, para uma
  # borda de relógio/ordenação jamais apagar o log que está sendo escrito.
  local rid f
  for rid in "${all_runs[@]:$MAX_LOGS}"; do
    [[ "$rid" == "${RUN_ID:-}" ]] && continue
    while IFS= read -r f; do
      [[ -n "$f" ]] && rm -f -- "$f"
    done < <(find "$LOG_DIR" -maxdepth 1 -type f -name "*${rid}*" 2>/dev/null)
  done
}

# L3 — evento jsonl com as contagens do diff de pacotes (atualizados/instalados/
# removidos) entre os snapshots $1 (antes) e $2 (depois). No-op se faltar snapshot.
write_pkg_changes_json() {
  local before="$1" after="$2"
  [[ -r "$before" && -r "$after" ]] || return 0
  local diff up ins rem
  diff="$(pkg_diff "$before" "$after" 2>/dev/null)" || return 0
  up="$(grep -c '^U ' <<< "$diff" || true)"
  ins="$(grep -c '^I ' <<< "$diff" || true)"
  rem="$(grep -c '^R ' <<< "$diff" || true)"
  (( up + ins + rem == 0 )) && return 0
  # Guarda também a LISTA, não só as contagens. "o que mudou na minha máquina
  # no run X" é a pergunta forense central de um upgrader, o diff já está
  # calculado aqui, e os snapshots .pkgs-before são rotacionados — sem isto o
  # JSONL vira o único registro durável e ele só dizia "4 atualizados".
  write_jsonl "$(
    printf '{"event":"pkg_changes","run_id":%s,"upgraded":%d,"installed":%d,"removed":%d,"packages":%s}\n' \
      "$(json_escape "$RUN_ID")" "$up" "$ins" "$rem" "$(pkg_diff_json "$diff")"
  )"
}

# Converte a saída do pkg_diff ("U nome antes depois" / "I nome ver" /
# "R nome ver") num array JSON de objetos. Pura: lê do $1, não toca disco.
pkg_diff_json() {
  local diff="$1" tag a b c first=1
  printf '['
  while read -r tag a b c; do
    [[ -n "$tag" ]] || continue
    (( first )) || printf ','
    first=0
    case "$tag" in
      U) printf '{"action":"upgraded","name":%s,"from":%s,"to":%s}' \
        "$(json_escape "$a")" "$(json_escape "$b")" "$(json_escape "$c")" ;;
      I) printf '{"action":"installed","name":%s,"version":%s}' \
        "$(json_escape "$a")" "$(json_escape "$b")" ;;
      R) printf '{"action":"removed","name":%s,"version":%s}' \
        "$(json_escape "$a")" "$(json_escape "$b")" ;;
      *) first=1 ;;
    esac
  done <<< "$diff"
  printf ']'
}

# L2 — jsonl mais recente de um run REAL (dry_run:false). Ignora dry-runs (que
# não devem ser alvo do --resume) e runs sem o campo (formato antigo). rc 1 se
# nenhum for achado.
resume_latest_real_jsonl() {
  local f
  while IFS= read -r f; do
    [[ -r "$f" ]] || continue
    if grep -q '"dry_run":false' <<<"$(grep -m1 '"event":"run_start"' "$f" 2>/dev/null)"; then
      printf '%s\n' "$f"
      return 0
    fi
  done < <(
    find "$LOG_DIR" -maxdepth 1 -name 'full-upgrade-*.jsonl' -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | cut -d' ' -f2-
  )
  return 1
}

# L2 — nomes de steps do último run REAL (ou do jsonl em $1) que NÃO fecharam ok:
# status ∈ {warn, todo, fail}. Um por linha, na ordem do run, sem duplicar.
# Read-only; usado por --resume. Sem jsonl legível => rc 1.
resume_pending_steps() {
  local jsonl="${1:-}"
  if [[ -z "$jsonl" ]]; then
    jsonl="$(resume_latest_real_jsonl)" || return 1
  fi
  [[ -r "$jsonl" ]] || return 1
  python3 - "$jsonl" <<'PY'
import json, sys
seen = set()
out = []
try:
    fh = open(sys.argv[1])
except OSError:
    sys.exit(1)
for line in fh:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if o.get("event") != "step":
        continue
    name, status = o.get("step"), o.get("status")
    if name and status in ("warn", "todo", "fail") and name not in seen:
        seen.add(name)
        out.append(name)
for n in out:
    print(n)
PY
}
