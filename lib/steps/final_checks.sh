#!/usr/bin/env bash
# lib/steps/final_checks.sh — verificações de pós-condição e autofix de pendências finais.
# Extraído de lib/steps/cleanup.sh (Série T3): são conferências de estado, não limpeza.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)



# K2 — clusters de rebuild upstream que o pacman SEGURA (evita partial upgrade)
# até o cluster inteiro ser publicado nos mirrors. Reaparecem como pendência
# "oficial" em todo run sem serem acionáveis: rodar `pacman -Syu` de novo não os
# sobe enquanto o rebuild não fecha. Hoje: toolchain Haskell/GHC (rebuild
# periódico em massa, o caso recorrente nos runs reais).
pending_is_held_cluster() {
  local name="$1"
  [[ "$name" =~ ^(haskell-|ghc(-|$)|cabal-install$|stack$|hlint$|stylish-haskell$|happy$|alex$) ]]
}


# Pacotes que o PRÓPRIO usuário segurou via `IgnorePkg` no pacman.conf.
#
# Diferente do cluster Haskell (que o pacman segura sozinho até o rebuild
# publicar), aqui a pendência é intencional e local: ela reaparece em todo run
# como "oficial pendente", o autofix reexecuta `pacman -Syu` para nada (o pacote
# nunca sobe) e o run fecha em `todo` para sempre, sem nada acionável.
#
# Caso real (2026-09-17): `python-aiostream` 0.8.1 no [extra] contra o pin
# `aiostream<0.8.0` do `vdirsyncer` 0.21.0 — o upstream do vdirsyncer ainda não
# destravou (constraint confirmada no main do repositório), então o hold é a
# única forma de manter `pip check` limpo sem quebrar o vdirsyncer. O pacman
# segue listando a pendência, anotada como `[ignorado]`/`[ignored]`.
#
# Lê a lista efetiva via `pacman-conf IgnorePkg` (respeita include/Include e é
# independente de locale); sem `pacman-conf`, faz o parsing do pacman.conf. Uma
# nome por linha no stdout.
pacman_ignored_packages() {
  local out=""
  local conf_rc=0
  # `pacman-conf` distingue rc=0+stdout vazio ("chave válida, sem valores" —
  # é o que ele responde para IgnorePkg sem hold) de rc=1 ("chave desconhecida").
  # Tratar o primeiro como falha e cair no parse manual era um bug: o fallback
  # leria o /etc/pacman.conf REAL da máquina, vazando o estado dela para quem
  # só queria a lista efetiva (ex.: testes unitários sem stub). Só fazemos o
  # fallback quando o binário não existe ou falha de verdade.
  if has pacman-conf; then
    out="$(pacman-conf IgnorePkg 2>/dev/null)" || conf_rc=1
  fi
  if (( conf_rc != 0 )); then
    out="$(sed -nE 's/^[[:space:]]*IgnorePkg[[:space:]]*=[[:space:]]*(.*)$/\1/p' \
      "${PACMAN_CONF_FILE:-/etc/pacman.conf}" 2>/dev/null || true)"
  fi
  [[ -n "${out//[[:space:]]/}" ]] || return 0
  # `pacman-conf` devolve a lista separada por espaço; o pacman.conf aceita
  # vírgula e espaço. Normaliza os dois separadores para uma nome por linha.
  printf '%s\n' "${out//,/ }" | tr -s '[:space:]' '\n' | grep -E '[^[:space:]]' || true
}


# Puro/testável: `$1` está na lista de pacotes segurados (uma por linha em $2)?
pending_is_ignored_pkg() {
  local name="${1:-}" list="${2:-}"
  [[ -n "${name//[[:space:]]/}" ]] || return 1
  [[ -n "${list//[[:space:]]/}" ]] || return 1
  grep -qxF -- "$name" <<<"$list"
}



final_pending_reason() {
  local official="$1" aur="$2"
  if (( official > 0 )); then
    printf '%s pacote(s) oficial(is) pendente(s) após sincronização da base; rode sudo pacman -Syu' "$official"
  elif (( aur > 0 )); then
    printf '%s pacote(s) AUR pendente(s); rode paru -Syu' "$aur"
  else
    printf 'nenhuma atualização pendente'
  fi
}



final_check_pending() {
  local pending=0
  local out
  local filtered
  local official_count=0 aur_count=0

  local -a held_official=() actionable_official=() held_ignored=()
  local ignored_list=""
  ignored_list="$(pacman_ignored_packages)"
  if has checkupdates; then
    out="$(checkupdates 2>/dev/null || true)"
    if [[ -n "${out//[[:space:]]/}" ]]; then
      local _ln _nm
      while IFS= read -r _ln; do
        [[ -n "${_ln//[[:space:]]/}" ]] || continue
        _nm="${_ln%%[[:space:]]*}"
        if pending_is_held_cluster "$_nm"; then
          held_official+=("$_ln")
        elif pending_is_ignored_pkg "$_nm" "$ignored_list"; then
          held_ignored+=("$_ln")
        else
          actionable_official+=("$_ln")
        fi
      done <<< "$out"

      if (( ${#held_official[@]} > 0 )); then
        log "  ${#held_official[@]} pacote(s) oficiais segurados por rebuild upstream (cluster Haskell/GHC); o pacman evita o partial upgrade até o cluster publicar — não acionável agora:"
        printf '%s\n' "${held_official[@]}" | log_stream
      fi

      if (( ${#held_ignored[@]} > 0 )); then
        log "  ${#held_ignored[@]} pacote(s) segurado(s) por IgnorePkg no pacman.conf — pendência intencional do usuário; 'pacman -Syu' não sobe enquanto o hold existir:"
        printf '%s\n' "${held_ignored[@]}" | log_stream
        log "  Para liberar: remova de IgnorePkg em /etc/pacman.conf (só depois de a dependência upstream destravar)."
      fi

      if (( ${#actionable_official[@]} > 0 )); then
        pending=1
        official_count="${#actionable_official[@]}"
        log "  Pendencias acionáveis em repositorios oficiais:"
        printf '%s\n' "${actionable_official[@]}" | log_stream
        remediation "sudo pacman -Syu"
      fi
    fi
  fi

  if has yay; then
    out="$(yay -Qua 2>/dev/null || true)"
  elif has paru; then
    out="$(paru -Qua 2>/dev/null || true)"
  fi

  if [[ -n "${out//[[:space:]]/}" ]]; then
    # `paru -Qua`/`yay -Qua` listam pacotes AUR ignorados por IgnorePkg
    # normalmente (não há o `grep -v '\[.*\]'` que o checkupdates faz no lado
    # oficial), então o hold também precisa ser saciado aqui — senão a pendência
    # reaparece em todo run mesmo sendo intencional.
    filtered="$(
      printf '%s\n' "$out" | awk -v ignored="$FULL_UPGRADE_AUR_IGNORE" -v pkg_ignore="$ignored_list" '
        BEGIN {
          split(ignored, names, /[[:space:]]+/)
          for (i in names) if (names[i] != "") skip[names[i]] = 1
          split(pkg_ignore, kept, /[[:space:]]+/)
          for (i in kept) if (kept[i] != "") held[kept[i]] = 1
        }
        {
          name = $1
          if (name in skip) next
          if (name in held) next
          print
        }
      '
    )"

    if [[ -n "${filtered//[[:space:]]/}" ]]; then
      pending=1
      aur_count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
      log "  Pendencias no AUR:"
      printf '%s\n' "$filtered" | log_stream
      if has paru; then
        remediation "paru -Syu"
      elif has yay; then
        remediation "yay -Syu"
      fi
    else
      # Nada acionável sobrou: diz POR QUE, listando cada classe de hold em vez
      # de um motivo genérico — sem isso o operador não sabe se a pendência
      # sumiu por hold local ou por ignore configurado no full-upgrade.
      local -a _aur_held_ignored=()
      if [[ -n "${ignored_list//[[:space:]]/}" ]]; then
        local _ln_aur
        while IFS= read -r _ln_aur; do
          [[ -n "${_ln_aur//[[:space:]]/}" ]] || continue
          pending_is_ignored_pkg "${_ln_aur%%[[:space:]]*}" "$ignored_list" \
            && _aur_held_ignored+=("$_ln_aur")
        done <<< "$out"
      fi
      if (( ${#_aur_held_ignored[@]} > 0 )); then
        log "  ${#_aur_held_ignored[@]} pacote(s) AUR segurado(s) por IgnorePkg no pacman.conf — pendência intencional do usuário:"
        printf '%s\n' "${_aur_held_ignored[@]}" | log_stream
      fi
      if [[ -n "${FULL_UPGRADE_AUR_IGNORE//[[:space:]]/}" ]]; then
        log "  Pendencias restantes apenas em pacotes AUR ignorados: ${FULL_UPGRADE_AUR_IGNORE}"
      fi
    fi
  fi

  local _aur_ood_file=""
  if [[ -n "${RUN_ID:-}" ]]; then
    _aur_ood_file="${LOG_DIR}/full-upgrade-${RUN_ID}.aur-out-of-date"
  fi
  if [[ -n "$_aur_ood_file" && -s "$_aur_ood_file" ]]; then
    local _aur_ood_count
    _aur_ood_count="$(grep -c '[^[:space:]]' "$_aur_ood_file" 2>/dev/null || true)"
    if (( _aur_ood_count > 0 )); then
      log "  ${_aur_ood_count} pacote(s) AUR marcados como out-of-date pelo mantenedor (informativo; não implica update aplicável):"
      sort -u "$_aur_ood_file" | log_stream
    fi
  fi

  if (( pending == 0 )); then
    if (( ${#held_official[@]} > 0 )) || (( ${#held_ignored[@]} > 0 )); then
      log "  Sem pendências acionáveis: só restam pacotes segurados (rebuild upstream / IgnorePkg)."
    else
      log "  Nenhuma atualização pendente em pacman/AUR."
    fi
    return 0
  fi

  if (( official_count > 0 )); then
    log "  Motivo provável: a base de pacotes foi sincronizada depois do upgrade principal."
  fi
  STEP_REASON="$(final_pending_reason "$official_count" "$aur_count")"
  return "$RC_TODO"
}



# Conta linhas não vazias. Evita `wc -l` sobre string vazia contar 1.
_count_lines() {
  local text="$1"
  [[ -n "${text//[[:space:]]/}" ]] || { printf '0'; return 0; }
  grep -c '[^[:space:]]' <<< "$text"
}



# Espelho de final_check_pending para os gerenciadores de linguagem: pacman/AUR
# já tinham conferência final, os demais não — um update que falhou no meio do
# run terminava silencioso. Só entram gerenciadores com consulta de "outdated"
# barata e read-only; pipx, uv tool e go não expõem nenhuma (não há --dry-run),
# então ficam de fora em vez de virar ruído ou consulta cara.
final_check_managers() {
  local -a pending=()
  local out count

  if has npm && npm_global_writable; then
    out="$(npm outdated -g --depth=0 --parseable 2>/dev/null || true)"
    count="$(_count_lines "$out")"
    if (( count > 0 )); then
      pending+=("npm global (${count})")
      log "  npm global ainda com ${count} pacote(s) desatualizado(s):"
      log_stream <<< "$out"
      remediation "npm update -g"
    fi
  fi

  # Prefixo secundário (~/.npm-global): o step 'Atualizar npm global
  # secundário' cuida do update, mas sem esta checagem o relatório final daria
  # ok falso se aquele prefixo ainda tivesse pendências. Espelha os guards do
  # step: só verifica se existir, ser gravável e difere do prefixo ativo.
  if has npm; then
    local sec="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}" primary
    primary="$(npm_global_prefix)"
    if [[ -d "${sec}/lib/node_modules" && -w "${sec}/lib/node_modules" && "$sec" != "$primary" ]]; then
      out="$(npm outdated -g --prefix "$sec" --depth=0 --parseable 2>/dev/null || true)"
      count="$(_count_lines "$out")"
      if (( count > 0 )); then
        pending+=("npm global secundário (${count})")
        log "  npm global [${sec}] ainda com ${count} pacote(s) desatualizado(s):"
        log_stream <<< "$out"
        remediation "npm install -g --prefix ${sec} <pacote>@latest"
      fi
    fi
  fi

  if has pnpm; then
    out="$(pnpm -g outdated --format list 2>/dev/null || true)"
    # pnpm v10 emite ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND no stdout (exit 0)
    # quando o global não tem package.json — ou seja, "sem pacotes globais",
    # não "desatualizado". update_pnpm_globals já trata esse caso (vira ok);
    # a checagem final precisa casar para não gerar um falso positivo de todo.
    out="$(grep -vE 'ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND|No global packages found|No package\.json' <<<"$out" || true)"
    count="$(_count_lines "$out")"
    if (( count > 0 )); then
      pending+=("pnpm global")
      log "  pnpm global ainda com pacote(s) desatualizado(s):"
      log_stream <<< "$out"
      remediation "pnpm -g update"
    fi
  fi

  if has cargo-install-update; then
    out="$(cargo install-update -l 2>/dev/null | awk '$NF == "Yes" { print $1 }' || true)"
    count="$(_count_lines "$out")"
    if (( count > 0 )); then
      pending+=("cargo (${count})")
      log "  Binários cargo ainda desatualizados: $(tr '\n' ' ' <<< "$out")"
      remediation "cargo install-update -a"
    fi
  fi

  if has gem; then
    local gem_outdated gem_arch
    gem_outdated="$(mktemp)"
    gem_arch="$(mktemp)"
    gem outdated 2>/dev/null > "$gem_outdated" || true
    gem list 2>/dev/null > "$gem_arch" || true
    out="$(gem_user_updatable "$gem_outdated" "$gem_arch")"
    rm -f "$gem_outdated" "$gem_arch"
    count="$(_count_lines "$out")"
    if (( count > 0 )); then
      pending+=("gem (${count})")
      log "  Gems de usuário ainda desatualizadas: $(tr '\n' ' ' <<< "$out")"
      remediation "gem update --user-install"
    fi
  fi

  if has flatpak; then
    out="$(flatpak remote-ls --updates --columns=application 2>/dev/null || true)"
    count="$(_count_lines "$out")"
    if (( count > 0 )); then
      pending+=("flatpak (${count})")
      log "  Flatpak ainda com ${count} atualização(ões) pendente(s):"
      log_stream <<< "$out"
      remediation "flatpak update"
    fi
  fi

  if (( ${#pending[@]} == 0 )); then
    log "  Nenhuma pendência nos gerenciadores de linguagem verificados (npm, npm secundário, pnpm, cargo, gem, flatpak)."
    return 0
  fi

  STEP_REASON="pendências após update: ${pending[*]}"
  return "$RC_TODO"
}



# Auto-remediação das pendências detectadas por final_check_pending: aplica
# `pacman -Syu` para pendências oficiais acionáveis (e um retry de `paru -Syu`
# para AUR, se houver). Step separado com efeito=mutating para preservar a
# garantia read-only do --mode doctor — final_check_pending continua read.
autofix_final_pending() {
  if (( ${AUTO_FIX_FINAL_PENDING:-0} == 0 )); then
    log "  AUTO_FIX_FINAL_PENDING desligado; nada a remediar."
    return 0
  fi

  local out
  local -a actionable=()
  # Pacotes segurados por IgnorePkg são pendência intencional: `pacman -Syu`
  # nunca os sobe enquanto o hold existir, então reexecutar aqui seria um ciclo
  # de remediação que não remedia nada (mesmo tratamento do cluster Haskell).
  local ignored_list=""
  ignored_list="$(pacman_ignored_packages)"
  if has checkupdates; then
    out="$(checkupdates 2>/dev/null || true)"
    local _ln _nm
    while IFS= read -r _ln; do
      [[ -n "${_ln//[[:space:]]/}" ]] || continue
      _nm="${_ln%%[[:space:]]*}"
      if pending_is_held_cluster "$_nm" || pending_is_ignored_pkg "$_nm" "$ignored_list"; then
        continue
      fi
      actionable+=("$_ln")
    done <<< "$out"
  fi

  local aur_pending=""
  if has paru; then
    aur_pending="$(paru -Qua 2>/dev/null || true)"
  elif has yay; then
    aur_pending="$(yay -Qua 2>/dev/null || true)"
  fi

  if (( ${#actionable[@]} == 0 )) && [[ -z "${aur_pending//[[:space:]]/}" ]]; then
    log "  Nenhuma pendência acionável para remediar."
    return 0
  fi

  if (( ${#actionable[@]} > 0 )); then
    log "  Remediando ${#actionable[@]} pendência(s) oficial(is): $(printf '%s\n' "${actionable[@]}" | awk '{print $1}' | paste -sd' ' -)"
    if ! run_logged sudo pacman -Syu --noconfirm; then
      STEP_REASON="pacman -Syu de remediação falhou"
      return 1
    fi
  fi

  # Pacote que já falhou em build() neste run não cura com retry: erro de
  # compilação é determinístico. Sem este filtro, um único PKGBUILD quebrado
  # upstream fazia o step recompilar o pacote inteiro do zero (1m43s medidos com
  # pcsx2 vs ffmpeg 8) para falhar exatamente igual. O step de pacman grava a
  # lista em $(aur_build_failed_file).
  local -a _known_failed=()
  local _abf_file
  _abf_file="$(aur_build_failed_file)"
  if [[ -n "${aur_pending//[[:space:]]/}" && -s "$_abf_file" ]]; then
    mapfile -t _known_failed < <(grep -E '[^[:space:]]' "$_abf_file" 2>/dev/null | sort -u)
    if (( ${#_known_failed[@]} > 0 )); then
      local _remaining=""
      _remaining="$(
        printf '%s\n' "$aur_pending" | grep -E '[^[:space:]]' | awk -v list="${_known_failed[*]}" '
          BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) failed[a[i]] = 1 }
          !($1 in failed)
        ' || true
      )"
      if [[ -z "${_remaining//[[:space:]]/}" ]]; then
        log "  Pendência AUR restrita a pacote(s) que já falharam build neste run: ${_known_failed[*]}"
        log "  Falha de compilação é determinística — retry pulado (economiza rebuild garantido a falhar)."
        remediation "paru -S ${_known_failed[*]}  # ou aguarde o mantenedor corrigir o PKGBUILD"
        STEP_REASON="retry AUR pulado: ${#_known_failed[@]} pacote(s) com falha de build determinística"
        return "$RC_TODO"
      fi
      log "  Ignorando no retry ${#_known_failed[@]} pacote(s) com falha de build determinística: ${_known_failed[*]}"
      aur_pending="$_remaining"
    fi
  fi

  if [[ -n "${aur_pending//[[:space:]]/}" ]]; then
    local -a ignore_args=() aur_cmd=()
    mapfile -t ignore_args < <(aur_ignore_args)
    local _kf
    for _kf in "${_known_failed[@]}"; do
      ignore_args+=("--ignore=${_kf}")
    done
    case "${AUR_HELPER:-}" in
      paru) has paru && aur_cmd=(paru -Sua --skipreview --noconfirm) ;;
      yay)  has yay  && aur_cmd=(yay -Sua --noconfirm --answerclean None --answerdiff None --answeredit None --answerupgrade None) ;;
    esac
    if (( ${#aur_cmd[@]} > 0 )); then
      log "  Retry de pendências AUR via ${aur_cmd[0]}..."
      if ! run_logged "${aur_cmd[@]}" "${ignore_args[@]}"; then
        log "  Retry AUR falhou; fica para o próximo run."
        STEP_REASON="pendências AUR persistem após retry"
        return "$RC_WARN"
      fi
    fi
  fi

  log "  Pendências remediadas."
  return 0
}
