#!/usr/bin/env bash
# lib/notify.sh — notificação desktop ao fim do run (I4).
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Conta os status acumulados em STEP_RESULTS e emite (stdout)
# "ok warn todo fail skip". Helper puro (lê o array global), testável.
_notify_counts() {
  local ok=0 warn=0 todo=0 fail=0 skip=0 r
  for r in "${STEP_RESULTS[@]}"; do
    case "$r" in
      ok)   ((ok++))   ;;
      warn) ((warn++)) ;;
      todo) ((todo++)) ;;
      fail) ((fail++)) ;;
      skip) ((skip++)) ;;
    esac
  done
  printf '%d %d %d %d %d\n' "$ok" "$warn" "$todo" "$fail" "$skip"
}

# Monta o corpo da notificação a partir das contagens. Pura.
# Uso: notify_body <ok> <warn> <todo> <fail> <skip>
notify_body() {
  printf '%s ok · %s warn · %s todo · %s fail · %s skip' "$1" "$2" "$3" "$4" "$5"
}

# I4 — envia uma notificação desktop com o resumo do run quando
# NOTIFY_ON_FINISH=1 e `notify-send` está disponível. Urgência:
# critical se houve fail, normal se houve todo, senão low. Nunca derruba o run.
notify_on_finish() {
  (( ${NOTIFY_ON_FINISH:-0} == 1 )) || return 0
  has notify-send || return 0

  local counts ok warn todo fail skip body urgency title
  counts="$(_notify_counts)"
  read -r ok warn todo fail skip <<< "$counts"
  body="$(notify_body "$ok" "$warn" "$todo" "$fail" "$skip")"

  if (( fail > 0 )); then
    urgency=critical; title="full-upgrade: concluído com falhas"
  elif (( todo > 0 )); then
    urgency=normal;   title="full-upgrade: concluído (ação manual pendente)"
  else
    urgency=low;      title="full-upgrade: concluído"
  fi

  notify-send -a full-upgrade -u "$urgency" "$title" "$body" 2>/dev/null || true
  return 0
}
