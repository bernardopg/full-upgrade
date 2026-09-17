#!/usr/bin/env bash
# lib/steps/ide.sh — atualização de extensões de IDEs da família VSCode (H3).
# Sourced por full-upgrade.sh (glob de steps). Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module

# Helper puro: conta quantas extensões foram atualizadas a partir da saída de
# `<cli> --update-extensions`. Lê stdin, emite (stdout) o número. A linha de
# sucesso do VSCode é "Extension '...' vX was successfully updated.".
count_ext_updates() {
  grep -ciE 'successfully updated' || true
}

# Lista os CLIs de IDE a tratar: IDE_EXT_CLIS (separado por espaço) ou, sem ele,
# o conjunto conhecido (code, cursor, codium, code-insiders, vscodium).
_ide_ext_clis() {
  if [[ -n "${IDE_EXT_CLIS:-}" ]]; then
    local -a configured=()
    read -r -a configured <<< "$IDE_EXT_CLIS"
    printf '%s\n' "${configured[@]}"
  else
    printf '%s\n' code cursor codium code-insiders vscodium
  fi
}

# Helper puro: a saída é um 5xx do marketplace (transitório por definição)?
# O Code-OSS imprime apenas `Server returned 503` quando o endpoint de batch
# (`POST /vscode/gallery/extensionquery`) do open-vsx responde 5xx.
_marketplace_5xx_output() {
  grep -qiE 'server returned 50[0234]|http 50[0234]|status code 50[0234]|service unavailable|bad gateway|gateway time-?out' <<<"${1:-}"
}

# H3 — atualiza as extensões instaladas de cada IDE da família VSCode presente.
# Usa `<cli> --update-extensions` (VSCode 1.86+, suportado também por cursor/
# codium). Read/rede: falha de rede vira RC_WARN; nenhum CLI presente → 0 (o
# main.sh já pula via has). Best-effort: erro num CLI não impede os demais, mas
# o step termina em RC_WARN se algum falhar.
#
# 5xx do marketplace ganha retry limitado (IDE_EXT_MAX_ATTEMPTS): é o caso
# medido em 2026-09-17 contra o open-vsx, que alterna 200/503 no mesmo endpoint
# sem relação com a rede local. Só quando todas as tentativas falham o step vira
# `warn`, com motivo próprio em vez do genérico "falha de rede".
update_ide_extensions() {
  local -a clis=()
  mapfile -t clis < <(_ide_ext_clis)

  local max_attempts="${IDE_EXT_MAX_ATTEMPTS:-3}"
  local retry_delay="${IDE_EXT_RETRY_DELAY_S:-5}"
  local cli found=0 status=0 out rc updated total=0 net_fail=0 srv_fail=0 attempt

  for cli in "${clis[@]}"; do
    has "$cli" || continue
    found=1
    log "  Atualizando extensões de ${cli}..."
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
      out="$(run_node_network_cmd "$cli" --update-extensions)"
      rc=$?
      # Só o 5xx do marketplace vale retry: qualquer outro rc tem outro motivo
      # (rede local, layout de CLI, erro de extensão) e repetir não muda nada.
      if (( rc == 0 )) || ! _marketplace_5xx_output "$out"; then
        break
      fi
      if (( attempt < max_attempts )); then
        log "  ${cli}: marketplace indisponível (HTTP 5xx); nova tentativa ${attempt}/${max_attempts} em ${retry_delay}s..."
        sleep "$retry_delay"
      fi
    done

    if (( rc == RC_WARN )); then
      if _marketplace_5xx_output "$out"; then
        # `attempt` sai do for em max_attempts+1 (incremento pós-loop), então
        # reportar literalmente contaria uma tentativa que não houve.
        log "  ${cli}: marketplace indisponível ao atualizar extensões (transitório após ${max_attempts} tentativa(s))."
        srv_fail=1
      else
        log "  ${cli}: falha de rede ao atualizar extensões."
        net_fail=1
      fi
      (( status == 0 )) && status="$RC_WARN"
      continue
    fi
    if (( rc != 0 )); then
      if _marketplace_5xx_output "$out"; then
        log "  ${cli}: marketplace indisponível ao atualizar extensões (transitório após ${attempt} tentativa(s), rc=${rc})."
        srv_fail=1
      else
        log "  ${cli}: erro ao atualizar extensões (rc=${rc})."
        net_fail=1
      fi
      (( status == 0 )) && status="$RC_WARN"
      continue
    fi
    updated="$(printf '%s\n' "$out" | count_ext_updates)"
    total=$(( total + updated ))
    log "  ${cli}: ${updated} extensão(ões) atualizada(s)."
  done

  if (( found == 0 )); then
    log "  Nenhum IDE da família VSCode encontrado."
    return 0
  fi
  log "  Total de extensões atualizadas: ${total}."
  if (( net_fail )); then
    STEP_REASON="falha de rede ao atualizar extensões de IDE"
  elif (( srv_fail )); then
    STEP_REASON="marketplace indisponível ao atualizar extensões de IDE (ex.: HTTP 503, tentar de novo mais tarde)"
  fi
  return "$status"
}
