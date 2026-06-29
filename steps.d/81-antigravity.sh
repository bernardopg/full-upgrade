#!/usr/bin/env bash
# steps.d/antigravity — integra Google Antigravity no Arch Linux.
# Atualiza instalações existentes por AUR; instalação nova só acontece com
# ENABLE_CUSTOM_TOOLS=1 para não adicionar IDEs pesadas por padrão.
# shellcheck shell=bash
# shellcheck disable=SC2034

ANTIGRAVITY_PACKAGE="antigravity"
ANTIGRAVITY_IDE_PACKAGE="antigravity-ide"
ANTIGRAVITY_RELEASES_URL="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases"
ANTIGRAVITY_IDE_RELEASES_URL="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases"
ANTIGRAVITY_DESKTOP_ID="antigravity.desktop"
ANTIGRAVITY_IDE_DESKTOP_ID="antigravity-ide.desktop"
ANTIGRAVITY_IDE_URL_DESKTOP_ID="antigravity-ide-url-handler.desktop"

antigravity_bin() {
    local candidate
    for candidate in \
        "${ANTIGRAVITY_BIN:-}" \
        "$(command -v antigravity 2>/dev/null || true)" \
        /usr/bin/antigravity \
        /opt/antigravity/antigravity; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

antigravity_ide_bin() {
    local candidate
    for candidate in \
        "${ANTIGRAVITY_IDE_BIN:-}" \
        "$(command -v antigravity-ide 2>/dev/null || true)" \
        /usr/bin/antigravity-ide \
        /opt/antigravity-ide/bin/antigravity-ide; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

antigravity_package_installed() {
    has pacman || return 1
    pacman -Q "$1" >/dev/null 2>&1
}

antigravity_hub_installed() {
    antigravity_package_installed "$ANTIGRAVITY_PACKAGE" && return 0
    antigravity_bin >/dev/null 2>&1 && return 0
    [[ -x /opt/antigravity/antigravity ]] && return 0
    return 1
}

antigravity_ide_installed() {
    antigravity_package_installed "$ANTIGRAVITY_IDE_PACKAGE" && return 0
    antigravity_ide_bin >/dev/null 2>&1 && return 0
    [[ -x /opt/antigravity-ide/bin/antigravity-ide ]] && return 0
    return 1
}

antigravity_installed() {
    antigravity_hub_installed || antigravity_ide_installed
}

antigravity_parse_latest_release() {
    grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' |
        head -1 |
        sed -E 's/.*"([^"]+)"$/\1/'
}

antigravity_latest_version() {
    local url="$1" payload rc
    has curl || return "$RC_WARN"
    payload="$(run_network_cmd curl -fsSL "$url")"
    rc=$?
    ((rc == 0)) || return "$rc"
    printf '%s\n' "$payload" | antigravity_parse_latest_release
}

antigravity_package_version() {
    local pkg="$1" version
    antigravity_package_installed "$pkg" || return 1
    version="$(pacman -Q "$pkg" 2>/dev/null | awk 'NR==1{print $2}')"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

install_antigravity_aur() {
    local helper="${AUR_HELPER:-}"
    local -a cmd=()

    if [[ -z "$helper" ]] || ! has "$helper"; then
        log " Nenhum helper AUR disponível para instalar/atualizar Antigravity."
        STEP_REASON="instale paru/yay/pikaur ou configure AUR_HELPER"
        return "$RC_TODO"
    fi

    cmd=("$helper" -S --needed --noconfirm)
    [[ "$helper" == "paru" ]] && cmd+=(--skipreview)
    cmd+=("$@")

    log " Instalando/atualizando via AUR: $*"
    if ! run_logged "${cmd[@]}"; then
        log " Falha no helper AUR ao processar Antigravity."
        STEP_REASON="falha no AUR helper para Antigravity"
        return "$RC_TODO"
    fi
}

write_antigravity_desktop() {
    local exec_path="$1" desktop_dir desktop_file
    desktop_dir="${HOME}/.local/share/applications"
    desktop_file="${desktop_dir}/${ANTIGRAVITY_DESKTOP_ID}"
    mkdir -p "$desktop_dir"

    cat >"$desktop_file" <<EOF
[Desktop Entry]
Name=Antigravity
Comment=Experience liftoff
GenericName=Agentic Platform
Exec=${exec_path} %U
Icon=antigravity
Type=Application
StartupNotify=false
StartupWMClass=Antigravity
Categories=Development;Utility;
EOF

    if has desktop-file-validate; then
        desktop-file-validate "$desktop_file" >>"$LOG_FILE" 2>&1 || return 1
    fi
    printf '%s\n' "$desktop_file"
}

write_antigravity_ide_desktop() {
    local exec_path="$1" desktop_dir desktop_file
    desktop_dir="${HOME}/.local/share/applications"
    desktop_file="${desktop_dir}/${ANTIGRAVITY_IDE_DESKTOP_ID}"
    mkdir -p "$desktop_dir"

    cat >"$desktop_file" <<EOF
[Desktop Entry]
Name=Antigravity IDE
Comment=Experience liftoff
GenericName=Text Editor
Exec=${exec_path} %F
Icon=antigravity-ide
Type=Application
StartupNotify=false
StartupWMClass=antigravity-ide
Categories=TextEditor;Development;IDE;
MimeType=application/x-antigravity-ide-workspace;
Actions=new-empty-window;
Keywords=vscode;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=${exec_path} --new-window %F
Icon=antigravity-ide
EOF

    if has desktop-file-validate; then
        desktop-file-validate "$desktop_file" >>"$LOG_FILE" 2>&1 || return 1
    fi
    printf '%s\n' "$desktop_file"
}

write_antigravity_ide_url_desktop() {
    local exec_path="$1" desktop_dir desktop_file
    desktop_dir="${HOME}/.local/share/applications"
    desktop_file="${desktop_dir}/${ANTIGRAVITY_IDE_URL_DESKTOP_ID}"
    mkdir -p "$desktop_dir"

    cat >"$desktop_file" <<EOF
[Desktop Entry]
Name=Antigravity IDE - URL Handler
Comment=Experience liftoff
GenericName=Text Editor
Exec=${exec_path} --open-url %U
Icon=antigravity-ide
Type=Application
NoDisplay=true
StartupNotify=true
Categories=Utility;TextEditor;Development;IDE;
MimeType=x-scheme-handler/antigravity-ide;
Keywords=vscode;
EOF

    if has desktop-file-validate; then
        desktop-file-validate "$desktop_file" >>"$LOG_FILE" 2>&1 || return 1
    fi
    printf '%s\n' "$desktop_file"
}

antigravity_desktop_present() {
    local desktop_id="$1"
    [[ -f "${HOME}/.local/share/applications/${desktop_id}" ]] && return 0
    [[ -f "/usr/share/applications/${desktop_id}" ]] && return 0
    return 1
}

antigravity_desktop_exec_is_broken() {
    local desktop_id="$1" desktop_file exec_line exec_cmd
    desktop_file="${HOME}/.local/share/applications/${desktop_id}"
    [[ -f "$desktop_file" ]] || return 1

    exec_line="$(awk -F= '/^Exec=/{print $2; exit}' "$desktop_file" 2>/dev/null || true)"
    [[ -n "$exec_line" ]] || return 0
    exec_cmd="${exec_line%% *}"

    if [[ "$exec_cmd" == /* ]]; then
        [[ -x "$exec_cmd" ]] || return 0
    else
        has "$exec_cmd" || return 0
    fi
    return 1
}

antigravity_desktop_exec_differs() {
    local desktop_id="$1" expected_exec="$2" desktop_file exec_line exec_cmd
    desktop_file="${HOME}/.local/share/applications/${desktop_id}"
    [[ -f "$desktop_file" ]] || return 1

    exec_line="$(awk -F= '/^Exec=/{print $2; exit}' "$desktop_file" 2>/dev/null || true)"
    [[ -n "$exec_line" ]] || return 0
    exec_cmd="${exec_line%% *}"
    [[ "$exec_cmd" != "$expected_exec" ]]
}

repair_antigravity_desktops() {
    local hub_bin ide_bin desktop_file status=0

    hub_bin="$(antigravity_bin || true)"
    if [[ -n "$hub_bin" ]]; then
        if ! antigravity_desktop_present "$ANTIGRAVITY_DESKTOP_ID" ||
            antigravity_desktop_exec_differs "$ANTIGRAVITY_DESKTOP_ID" "$hub_bin" ||
            antigravity_desktop_exec_is_broken "$ANTIGRAVITY_DESKTOP_ID"; then
            desktop_file="$(write_antigravity_desktop "$hub_bin")" || status=$?
            ((status == 0)) && log " Antigravity desktop: ${desktop_file}"
        fi
    fi

    ide_bin="$(antigravity_ide_bin || true)"
    if [[ -n "$ide_bin" ]]; then
        if ! antigravity_desktop_present "$ANTIGRAVITY_IDE_DESKTOP_ID" ||
            antigravity_desktop_exec_differs "$ANTIGRAVITY_IDE_DESKTOP_ID" "$ide_bin" ||
            antigravity_desktop_exec_is_broken "$ANTIGRAVITY_IDE_DESKTOP_ID"; then
            desktop_file="$(write_antigravity_ide_desktop "$ide_bin")" || status=$?
            ((status == 0)) && log " Antigravity IDE desktop: ${desktop_file}"
        fi
        if ! antigravity_desktop_present "$ANTIGRAVITY_IDE_URL_DESKTOP_ID" ||
            antigravity_desktop_exec_differs "$ANTIGRAVITY_IDE_URL_DESKTOP_ID" "$ide_bin" ||
            antigravity_desktop_exec_is_broken "$ANTIGRAVITY_IDE_URL_DESKTOP_ID"; then
            desktop_file="$(write_antigravity_ide_url_desktop "$ide_bin")" || status=$?
            ((status == 0)) && log " Antigravity IDE URL handler: ${desktop_file}"
        fi
    fi

    if has update-desktop-database; then
        update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true
    fi
    return "$status"
}

repair_antigravity_command_shadowing() {
    local name local_bin system_bin backup pfx
    local status=0
    for name in antigravity antigravity-ide; do
        local_bin="/usr/local/bin/${name}"
        system_bin="/usr/bin/${name}"
        [[ -e "$local_bin" && -x "$system_bin" ]] || continue
        pacman -Qo "$local_bin" >/dev/null 2>&1 && continue

        backup="${local_bin}.manual-backup-$(date +%Y%m%d%H%M%S)"
        pfx=""
        if [[ ! -w "$local_bin" || ! -w "$(dirname "$local_bin")" ]]; then
            if has sudo && sudo -n true 2>/dev/null; then
                pfx="sudo"
            else
                log " ${local_bin} sombreia ${system_bin}, mas requer sudo para mover."
                STEP_REASON="remova ${local_bin} ou rode com sudo pronto"
                status="$RC_TODO"
                continue
            fi
        fi

        if ${pfx:+$pfx} mv -f -- "$local_bin" "$backup" 2>>"$LOG_FILE"; then
            log " Shadowing removido: ${local_bin} -> ${backup}"
        else
            log " Falha ao mover ${local_bin}; ele continua sombreando ${system_bin}."
            STEP_REASON="falha ao remover shadowing de ${local_bin}"
            status="$RC_TODO"
        fi
    done
    return "$status"
}

repair_antigravity_legacy_opt_dir() {
    local legacy_dir="/opt/antigravity"
    local packaged_bin="/opt/Antigravity/antigravity"
    local backup_dir pfx link target

    [[ -d "$legacy_dir" && -x "$packaged_bin" ]] || return 0
    pacman -Qo "$legacy_dir" >/dev/null 2>&1 && return 0

    backup_dir="${legacy_dir}.manual-backup-$(date +%Y%m%d%H%M%S)"
    pfx=""
    if [[ ! -w "$legacy_dir" || ! -w "$(dirname "$legacy_dir")" ]]; then
        if has sudo && sudo -n true 2>/dev/null; then
            pfx="sudo"
        else
            log " ${legacy_dir} é legado manual sem dono, mas requer sudo para mover."
            STEP_REASON="mova ${legacy_dir} com sudo ou rode com sudo pronto"
            return "$RC_TODO"
        fi
    fi

    if ! ${pfx:+$pfx} mv -f -- "$legacy_dir" "$backup_dir" 2>>"$LOG_FILE"; then
        log " Falha ao mover ${legacy_dir}; diretório manual legado permanece."
        STEP_REASON="falha ao mover ${legacy_dir}"
        return "$RC_TODO"
    fi

    for link in /usr/local/bin/antigravity.manual-backup-*; do
        [[ -L "$link" ]] || continue
        target="$(readlink "$link" 2>/dev/null || true)"
        [[ "$target" == "${legacy_dir}/antigravity" ]] || continue
        ${pfx:+$pfx} ln -sfn "${backup_dir}/antigravity" "$link" 2>>"$LOG_FILE" || true
    done

    log " Diretório legado movido: ${legacy_dir} -> ${backup_dir}"
}

check_antigravity_release_status() {
    local label="$1" pkg="$2" releases_url="$3"
    local current latest rc

    current="$(antigravity_package_version "$pkg" || true)"
    [[ -n "$current" ]] || return 0

    latest="$(antigravity_latest_version "$releases_url")"
    rc=$?
    if ((rc != 0)) || [[ -z "$latest" ]]; then
        log " ${label}: não foi possível consultar o manifest oficial."
        STEP_REASON="manifest oficial do Antigravity indisponível"
        return "$RC_WARN"
    fi

    log " ${label}: pacote ${current}; upstream ${latest}."
    if version_is_outdated "$current" "$latest"; then
        STEP_REASON="${pkg} ${current} está atrás do upstream ${latest}"
        remediation "${AUR_HELPER:-paru} -S ${pkg} # ou aguarde o PKGBUILD do AUR atualizar"
        return "$RC_TODO"
    fi
}

ensure_antigravity() {
    local -a packages=()
    local rc status=0

    if ! has pacman; then
        STEP_REASON="Antigravity no Arch requer pacman/AUR"
        log " pacman não encontrado; este step é específico para Arch Linux."
        return "$RC_TODO"
    fi

    if antigravity_hub_installed || ((${ENABLE_CUSTOM_TOOLS:-0} == 1)); then
        packages+=("$ANTIGRAVITY_PACKAGE")
    fi
    if antigravity_ide_installed || ((${ENABLE_CUSTOM_TOOLS:-0} == 1)); then
        packages+=("$ANTIGRAVITY_IDE_PACKAGE")
    fi

    if ((${#packages[@]} == 0)); then
        STEP_REASON="antigravity não instalado; habilite ENABLE_CUSTOM_TOOLS=1 para instalar"
        log " Antigravity não encontrado; instalação automática desligada."
        return "$RC_TODO"
    fi

    install_antigravity_aur "${packages[@]}"
    rc=$?
    ((rc == 0)) || return "$rc"

    repair_antigravity_command_shadowing || status=$?
    repair_antigravity_legacy_opt_dir || status=$?

    ANTIGRAVITY_BIN="$(antigravity_bin || true)"
    ANTIGRAVITY_IDE_BIN="$(antigravity_ide_bin || true)"

    repair_antigravity_desktops || status=$?

    check_antigravity_release_status "Antigravity" "$ANTIGRAVITY_PACKAGE" "$ANTIGRAVITY_RELEASES_URL"
    rc=$?
    ((rc == 0 || status != 0)) || status=$rc

    check_antigravity_release_status "Antigravity IDE" "$ANTIGRAVITY_IDE_PACKAGE" "$ANTIGRAVITY_IDE_RELEASES_URL"
    rc=$?
    ((rc == 0 || status != 0)) || status=$rc

    if [[ -n "${ANTIGRAVITY_BIN:-}" ]]; then
        log " Antigravity binário: ${ANTIGRAVITY_BIN}"
    fi
    if [[ -n "${ANTIGRAVITY_IDE_BIN:-}" ]]; then
        log " Antigravity IDE binário: ${ANTIGRAVITY_IDE_BIN}"
    fi

    return "$status"
}
