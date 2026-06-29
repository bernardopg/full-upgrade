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
        available_ver="$(pacman -Si "$pkg" 2>/dev/null | awk '/^Version/{print $3; exit}' || true)"
        if [[ -n "$available_ver" && "$installed_ver" == "$available_ver" ]]; then
            log " ${pkg} ${installed_ver} já na versão mais recente."
            return 0
        fi
        [[ -n "$available_ver" ]] && log " ${pkg}: ${installed_ver} → ${available_ver}"
    fi

    run_logged sudo pacman -S --needed --noconfirm "$pkg"
}

# Garante/atualiza apenas o Wireshark (pacote oficial wireshark-qt).
ensure_wireshark() {
    if ! wireshark_install_arch_package wireshark-qt; then
        log " Falha ao garantir wireshark-qt."
        return 1
    fi
    return 0
}

repair_wireshark_capture_permissions() {
    if declare -F repair_command_shadowing >/dev/null 2>&1; then
        repair_command_shadowing dumpcap /usr/bin/dumpcap || return $?
    fi

    if [[ ! -e /usr/bin/dumpcap ]]; then
        log " dumpcap não encontrado."
        return 1
    fi
    if ! getent group wireshark >/dev/null 2>&1; then
        log " Grupo wireshark não encontrado."
        return 1
    fi

    run_logged sudo chgrp wireshark /usr/bin/dumpcap
    run_logged sudo chmod 750 /usr/bin/dumpcap
    if has setcap; then
        run_logged sudo setcap cap_net_raw,cap_net_admin,cap_dac_override+eip /usr/bin/dumpcap
    else
        log " setcap não instalado; não foi possivel configurar capabilities."
        return 1
    fi
}
