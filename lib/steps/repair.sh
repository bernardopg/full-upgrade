#!/usr/bin/env bash
# steps/repair.sh — reparos genéricos (command shadowing)
# Burp/Wireshark (custom) movidos p/ steps.d/50-wireshark.sh e steps.d/51-burp-suite.sh
# shellcheck shell=bash
# shellcheck disable=SC2034 # STEP_REASON é consumido pelo framework em core.sh

repair_command_shadowing() {
    local name="$1"
    local managed_path="$2"
    local local_path="/usr/local/bin/${name}"

    if [[ ! -e "$local_path" ]]; then
        log "  Sem sombra local para ${name}."
        return 0
    fi

    if [[ ! -e "$managed_path" ]]; then
        log "  Binario gerenciado não encontrado para ${name}: ${managed_path}"
        return 1
    fi

    if pacman -Qo "$local_path" >/dev/null 2>&1; then
        log "  ${local_path} e gerenciado por pacote; nada a reparar."
        return 0
    fi

    if ! pacman -Qo "$managed_path" >/dev/null 2>&1; then
        log "  ${managed_path} não e gerenciado pelo pacman; não vou alterar ${local_path}."
        return 1
    fi

    local backup
    backup="${local_path}.manual.$(date +%Y%m%d-%H%M%S)"
    log "  Movendo binario local que sombreia o pacote: ${local_path} -> ${backup}"
    run_logged sudo mv -- "$local_path" "$backup"
}

repair_known_command_shadowing() {
    repair_command_shadowing wireshark /usr/bin/wireshark
    repair_command_shadowing dumpcap /usr/bin/dumpcap
}

# Units app-*.scope são scopes transitórios criados pelo desktop para apps. Se
# o app é morto por OOM/crash, o registro pode permanecer em "failed" por dias
# e contaminar `systemctl --user --failed`, embora não exista serviço para
# reiniciar. O journal/coredump preserva a causa; reset-failed limpa somente o
# estado administrativo obsoleto.
repair_stale_user_app_scopes() {
    has systemctl || { log "  systemctl ausente; nada a reparar."; return 0; }
    [[ "$(systemd_user_scope_status 2>/dev/null || true)" == "available" ]] || {
        log "  Sessão systemd --user indisponível; limpeza de scopes pulada."
        return 0
    }

    local failed unit line
    failed="$(systemctl --user --failed --plain --no-legend 2>/dev/null || true)"
    local -a scopes=()
    while IFS= read -r line; do
        unit="${line%%[[:space:]]*}"
        [[ "$unit" == app-*.scope ]] && scopes+=("$unit")
    done <<< "$failed"

    if (( ${#scopes[@]} == 0 )); then
        log "  Nenhum scope transitório de app em estado failed."
        return 0
    fi

    log "  Limpando ${#scopes[@]} scope(s) transitório(s) de app já encerrado(s): ${scopes[*]}"
    if ! systemctl --user reset-failed "${scopes[@]}" 2>>"$LOG_FILE"; then
        STEP_REASON="não foi possível limpar scopes transitórios de app"
        return "$RC_WARN"
    fi
    return 0
}

# MaxAge= e Keep= nunca foram opções válidas de coredump.conf nas versões
# atuais do systemd. Como são ignoradas, removê-las não muda a política efetiva;
# apenas elimina warnings repetidos. O backup torna o reparo reversível.
repair_coredump_obsolete_keys() {
    local paths="${COREDUMP_CONFIG_PATHS:-/etc/systemd/coredump.conf /etc/systemd/coredump.conf.d/*.conf}"
    local file tmp backup mode changed=0
    # shellcheck disable=SC2086 # globs/espaços de paths são intencionais aqui
    for file in $paths; do
        [[ -f "$file" && -r "$file" ]] || continue
        if ! awk '
          /^\[/ { in_coredump = ($0 == "[Coredump]") }
          in_coredump && /^[[:space:]]*(MaxAge|Keep)[[:space:]]*=/ { found=1 }
          END { exit found ? 0 : 1 }
        ' "$file"; then
            continue
        fi

        tmp="$(mktemp 2>/dev/null || true)"
        [[ -n "$tmp" ]] || { STEP_REASON="mktemp falhou ao reparar coredump.conf"; return "$RC_WARN"; }
        awk '
          /^\[/ { in_coredump = ($0 == "[Coredump]") }
          !(in_coredump && /^[[:space:]]*(MaxAge|Keep)[[:space:]]*=/)
        ' "$file" > "$tmp"

        backup="${file}.full-upgrade.bak.$(date +%Y%m%d-%H%M%S)"
        mode="$(stat -c '%a' "$file" 2>/dev/null || printf '644')"
        if ! sudo -n cp -a -- "$file" "$backup" 2>>"$LOG_FILE" ||
           ! sudo -n install -m "$mode" -- "$tmp" "$file" 2>>"$LOG_FILE"; then
            rm -f "$tmp"
            STEP_REASON="falha ao reparar ${file}; backup: ${backup}"
            return "$RC_WARN"
        fi
        rm -f "$tmp"
        changed=$((changed + 1))
        log "  Removidas diretivas inválidas MaxAge/Keep de ${file}; backup: ${backup}"
    done

    (( changed == 0 )) && log "  Nenhuma diretiva inválida MaxAge/Keep em coredump.conf."
    return 0
}
