#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2034

setup() {
    load "${BATS_TEST_DIRNAME}/test_helper"
    load_libs
    # shellcheck source=/dev/null
    source "${FU_ROOT}/steps.d/81-antigravity.sh"
    TMP_HOME="$(mktemp -d)"
    export HOME="$TMP_HOME"
    LOG_FILE="/dev/null"
}

teardown() {
    rm -rf "$TMP_HOME"
}

@test "antigravity: parseia primeiro release do manifest oficial" {
    latest="$(printf '%s\n' '[{"version":"2.2.1","execution_id":"1"},{"version":"2.1.4","execution_id":"2"}]' | antigravity_parse_latest_release)"
    [ "$latest" = "2.2.1" ]
}

@test "antigravity: resolve binários por override" {
    mkdir -p "$HOME/bin"
    touch "$HOME/bin/antigravity" "$HOME/bin/antigravity-ide"
    chmod +x "$HOME/bin/antigravity" "$HOME/bin/antigravity-ide"

    ANTIGRAVITY_BIN="$HOME/bin/antigravity"
    ANTIGRAVITY_IDE_BIN="$HOME/bin/antigravity-ide"

    [ "$(antigravity_bin)" = "$HOME/bin/antigravity" ]
    [ "$(antigravity_ide_bin)" = "$HOME/bin/antigravity-ide" ]
}

@test "antigravity: escreve desktop entries corretos" {
    mkdir -p "$HOME/bin"
    touch "$HOME/bin/antigravity" "$HOME/bin/antigravity-ide"
    chmod +x "$HOME/bin/antigravity" "$HOME/bin/antigravity-ide"

    hub_desktop="$(write_antigravity_desktop "$HOME/bin/antigravity")"
    ide_desktop="$(write_antigravity_ide_desktop "$HOME/bin/antigravity-ide")"
    url_desktop="$(write_antigravity_ide_url_desktop "$HOME/bin/antigravity-ide")"

    [ -f "$hub_desktop" ]
    [ -f "$ide_desktop" ]
    [ -f "$url_desktop" ]
    grep -qxF "Exec=${HOME}/bin/antigravity %U" "$hub_desktop"
    grep -qxF "Icon=antigravity" "$hub_desktop"
    grep -qxF "Exec=${HOME}/bin/antigravity-ide %F" "$ide_desktop"
    grep -qxF "Exec=${HOME}/bin/antigravity-ide --open-url %U" "$url_desktop"
}

@test "antigravity: detecta desktop local divergente" {
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/antigravity.desktop" <<EOF
[Desktop Entry]
Name=Antigravity
Exec=/opt/antigravity/antigravity %U
Type=Application
EOF

    run antigravity_desktop_exec_differs "$ANTIGRAVITY_DESKTOP_ID" "/usr/bin/antigravity"
    [ "$status" -eq 0 ]

    run antigravity_desktop_exec_differs "$ANTIGRAVITY_DESKTOP_ID" "/opt/antigravity/antigravity"
    [ "$status" -eq 1 ]
}
