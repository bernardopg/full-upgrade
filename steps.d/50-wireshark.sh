#!/usr/bin/env bash
# steps.d/wireshark — Wireshark Qt e permissões de captura.
# OPT-IN (ENABLE_CUSTOM_TOOLS=1): instala wireshark-qt se ausente.
# shellcheck shell=bash
# shellcheck disable=SC2034

wireshark_install_arch_package() {
    local pkg="$1"
    local installed_ver available_ver

    installed_ver="$(pacman -Q "$pkg" 2>/dev/null | awk '{print $2}' || true)"
    if [[ -n "$installed_ver" ]]; then
        # LC_ALL=C: em pt_BR o campo é "Versão" e o awk nunca casava — a versão
        # disponível vinha sempre vazia e todo run caía no `pacman -S --needed`.
        available_ver="$(LC_ALL=C pacman -Si "$pkg" 2>/dev/null | awk '/^Version/{print $3; exit}' || true)"
        if [[ -n "$available_ver" && "$installed_ver" == "$available_ver" ]]; then
            log "  ${pkg} ${installed_ver} já na versão mais recente."
            return 0
        fi
        if [[ -z "$available_ver" ]]; then
            # Instalado, mas a base de sync não respondeu (assinatura PGP
            # inválida de um repo de terceiros no meio da publicação, base
            # corrompida...). Caso real (2026-11-25): `pacman -S --needed`
            # tropeçou na mesma base e o step virou fail com o pacote já
            # instalado. O upgrade principal sobe o pacote quando a base voltar.
            log "  ${pkg} ${installed_ver} instalado; versão do repositório ilegível (base de sync indisponível) — sem reinstalar."
            STEP_REASON="base de sync ilegível; ${pkg} ${installed_ver} mantido"
            return "$RC_WARN"
        fi
        log "  ${pkg}: ${installed_ver} → ${available_ver}"
    fi

    run_logged sudo pacman -S --needed --noconfirm "$pkg"
}

# Garante/atualiza apenas o Wireshark (pacote oficial wireshark-qt).
ensure_wireshark() {
    local rc=0
    wireshark_install_arch_package wireshark-qt || rc=$?
    (( rc == 0 || rc == RC_WARN )) && return "$rc"
    log "  Falha ao garantir wireshark-qt."
    return 1
}

repair_wireshark_capture_permissions() {
    local dumpcap="${WIRESHARK_DUMPCAP:-/usr/bin/dumpcap}"
    if declare -F repair_command_shadowing >/dev/null 2>&1; then
        repair_command_shadowing dumpcap "$dumpcap" || return $?
    fi

    if [[ ! -e "$dumpcap" ]]; then
        log "  dumpcap não encontrado."
        return 1
    fi
    if ! getent group wireshark >/dev/null 2>&1; then
        log "  Grupo wireshark não encontrado."
        return 1
    fi

    run_logged sudo chgrp wireshark "$dumpcap"
    run_logged sudo chmod 750 "$dumpcap"
    if has setcap; then
        run_logged sudo setcap cap_net_raw,cap_net_admin,cap_dac_override+eip "$dumpcap"
    else
        log "  setcap não instalado; não foi possivel configurar capabilities."
        return 1
    fi
}
