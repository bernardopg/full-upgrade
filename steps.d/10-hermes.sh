#!/usr/bin/env bash
# steps.d/hermes — integração Hermes Agent. Roda por presença (só se `hermes`
# estiver no PATH); inofensivo em máquinas sem a ferramenta.
# shellcheck shell=bash

# Verdadeiro (rc 0) se a saída de `hermes update --check` indica que já está
# atualizado. Puro/testável. Qualquer outra coisa => há update (não pula).
hermes_is_current() {
  grep -qiE 'already up.to.date|up to date|no updates? available|nenhuma atualiza' <<<"$1"
}

# O GitHub às vezes demora 14–50s para responder qualquer requisição smart-HTTP
# do repo NousResearch/hermes-agent (outros repos respondem em 0,3s, na mesma
# rede). O git espera calado, o fetch interno do Hermes tem teto próprio de 300s
# e o step estourava o catálogo. Com o limite de baixa velocidade do curl (via
# env, herdado pelo git que o Hermes chama) a requisição parada aborta em
# HERMES_GIT_STALL_S e a próxima tentativa costuma sair em segundos. A lentidão
# vem em rajadas e também atinge o POST que gera o pack (`RPC failed; curl 28`):
# um limite fixo de 20s falhou 3 vezes seguidas em 1 minuto. Por isso cada nova
# tentativa espera 10s e dobra a paciência (20s, 40s, 60s).
HERMES_GIT_STALL_S="${HERMES_GIT_STALL_S:-20}"
HERMES_UPDATE_ATTEMPTS="${HERMES_UPDATE_ATTEMPTS:-3}"

# Diagnósticos genéricos de fetch do Hermes. Ele já separa auth/SSH/429/outage
# em frases próprias; o que sobra no genérico é transporte (pack interrompido,
# lazy fetch de clone parcial, teto de 300s do próprio Hermes). Sem isto, uma
# requisição lenta do GitHub cujo stderr não casava NETWORK_TRANSIENT_RE virava
# fail sem nova tentativa (runs de 2026-09-30 a 2026-10-05).
HERMES_FETCH_FAILURE_RE='failed to fetch updates from origin|git fetch timed out after'

# Hermes upstream imprime só a primeira linha do stderr do fetch. Este wrapper
# local conserva o stderr real sem modificar a instalação nem registrar argv.
hermes_prepare_git_capture() {
  local real_git
  real_git="$(type -P git)" || return 1
  HERMES_GIT_WRAPPER="$(mktemp -d "${LOG_DIR}/hermes-git.XXXXXX")" || return 1
  export HERMES_REAL_GIT="$real_git"
  export HERMES_GIT_STDERR="${LOG_DIR}/hermes-git-${RUN_ID}.log"
  : > "$HERMES_GIT_STDERR"
  cat > "${HERMES_GIT_WRAPPER}/git" <<'GITWRAPPER'
#!/usr/bin/env bash
# tee conserva o diagnóstico que a CLI Hermes trunca ao capturar stderr.
"$HERMES_REAL_GIT" "$@" 2> >(tee -a "$HERMES_GIT_STDERR" >&2)
rc=$?
wait
exit "$rc"
GITWRAPPER
  chmod 700 "${HERMES_GIT_WRAPPER}/git"
}

update_hermes() {
  local hermes_bin
  hermes_bin="$(command -v hermes || true)"

  if [[ -z "$hermes_bin" ]]; then
    log "  Hermes não encontrado no PATH."
    return 0
  fi

  log "  Hermes em: ${hermes_bin}"

  # Otimização: o `hermes update --check` (só fetch + comparação) decide se o
  # update completo é necessário. O smart-HTTP do GitHub pode ficar pendurado
  # transitoriamente; o probe tem limite próprio para ainda sobrar tempo para a
  # segunda tentativa feita pelo update real. O update completo pode drenar o
  # gateway por até 75s e levou 113s em medição real, portanto o timeout total do
  # catálogo é deliberadamente maior.
  local check_out check_rc
  local -x GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME="$HERMES_GIT_STALL_S"
  if check_out="$(timeout 30 env CI=1 NO_COLOR=1 TERM=dumb hermes update --check 2>&1)"; then
    check_rc=0
  else
    check_rc=$?
  fi
  check_out="$(printf '%s\n' "$check_out" | sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g')"

  if (( check_rc == 0 )) && hermes_is_current "$check_out"; then
    log "  Hermes já está na versão mais recente (check); pulando update."
    return 0
  fi
  if (( check_rc == 124 )); then
    log "  Check do Hermes excedeu 30s; tentando o update completo como segunda tentativa."
  elif (( check_rc != 0 )); then
    log "  Check do Hermes falhou (rc=${check_rc}); tentando o update completo."
  fi

  local output_file rc attempt
  local HERMES_GIT_WRAPPER="" capture_path="$PATH"
  if hermes_prepare_git_capture; then
    capture_path="${HERMES_GIT_WRAPPER}:$PATH"
  else
    log "  Não foi possível preparar captura do stderr Git; diagnóstico limitado pela CLI Hermes."
  fi
  output_file="${LOG_DIR}/hermes-update-${RUN_ID}.log"

  # Hermes can emit TTY animations from nested Node postinstall/demo tooling.
  # Keep the full output in its own log and show only actionable lines here.
  # Só falha de rede é repetida: o Hermes sai no fetch, antes de tocar no
  # checkout, então a nova tentativa parte do mesmo estado.
  for (( attempt = 1; attempt <= HERMES_UPDATE_ATTEMPTS; attempt++ )); do
    GIT_HTTP_LOW_SPEED_TIME=$(( HERMES_GIT_STALL_S * attempt ))
    [[ -n "$HERMES_GIT_WRAPPER" ]] && : > "$HERMES_GIT_STDERR"
    PATH="$capture_path" CI=1 NO_COLOR=1 TERM=dumb HERMES_ACCEPT_HOOKS=1 hermes update --yes >"$output_file" 2>&1
    rc=$?
    if [[ -n "$HERMES_GIT_WRAPPER" && -s "$HERMES_GIT_STDERR" ]]; then
      printf '\n--- Git stderr completo ---\n' >> "$output_file"
      cat "$HERMES_GIT_STDERR" >> "$output_file"
    fi
    {
      printf '\n===== hermes update %d/%d (%s) =====\n' "$attempt" "$HERMES_UPDATE_ATTEMPTS" "$(date -Is)"
      sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' "$output_file"
    } >> "$LOG_FILE"
    (( rc != 0 && attempt < HERMES_UPDATE_ATTEMPTS )) && grep -qiE "${NETWORK_TRANSIENT_RE}|${HERMES_FETCH_FAILURE_RE}" "$output_file" || break
    log "  Tentativa ${attempt}/${HERMES_UPDATE_ATTEMPTS} do hermes update falhou por rede; repetindo em 10s."
    sleep 10
  done

  [[ -n "$HERMES_GIT_WRAPPER" ]] && rm -rf -- "$HERMES_GIT_WRAPPER"

  grep -E '^(✓|⚠|✗|→|  ✓|  ⚠|  →|Tip:|Up to date|Already|No update|error:|Error:|warning:|Warning:|fatal:|Traceback)' "$output_file" \
    | sed -r 's/\x1B\[[0-9;?]*[ -/]*[@-~]//g' \
    | tail -40 | log_out || true
  log "  Log Hermes: ${output_file}"
  if (( rc != 0 )); then
    if grep -qiE "${NETWORK_TRANSIENT_RE}|${HERMES_FETCH_FAILURE_RE}" "$output_file"; then
      STEP_REASON="rede indisponível durante hermes update (detalhes: ${output_file})"
      return "$RC_WARN"
    fi
    # shellcheck disable=SC2034  # global cross-module lida por core.sh
    STEP_REASON="hermes update falhou com rc=${rc} (detalhes: ${output_file})"
  fi
  return "$rc"
}
