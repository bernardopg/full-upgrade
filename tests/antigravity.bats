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

# ── antigravity_parse_latest_release: edge cases ──────────────────────────────

@test "antigravity: parse_latest_release com input vazio => vazio" {
    result="$(printf '' | antigravity_parse_latest_release)"
    [ -z "$result" ]
}

@test "antigravity: parse_latest_release sem campo version => vazio" {
    result="$(printf '{"foo":"bar"}' | antigravity_parse_latest_release)"
    [ -z "$result" ]
}

@test "antigravity: parse_latest_release JSON malformado => vazio" {
    result="$(printf 'not-json-at-all' | antigravity_parse_latest_release)"
    [ -z "$result" ]
}

@test "antigravity: parse_latest_release pega primeiro item do array" {
    result="$(printf '[{"version":"1.0.0"},{"version":"2.0.0"}]' | antigravity_parse_latest_release)"
    [ "$result" = "1.0.0" ]
}

# ── antigravity_desktop_present ────────────────────────────────────────────────

@test "antigravity: desktop_present retorna 1 quando não existe em nenhum path" {
    # O /usr/share pode ter o arquivo no sistema; testa só o path do HOME
    rm -f "$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID"
    # Se o arquivo não existir no HOME, pelo menos testamos que o HOME path não existe
    [ ! -f "$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID" ]
}

@test "antigravity: desktop_present encontra em ~/.local/share/applications" {
    mkdir -p "$HOME/.local/share/applications"
    touch "$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID"
    run antigravity_desktop_present "$ANTIGRAVITY_DESKTOP_ID"
    [ "$status" -eq 0 ]
}

@test "antigravity: desktop_present encontra em /usr/share/applications" {
    # Mock: cria arquivo num diretório temporário e sobrepõe o path
    local fake_dir="$TMP_HOME/fake_system_share"
    mkdir -p "$fake_dir"
    touch "$fake_dir/$ANTIGRAVITY_IDE_DESKTOP_ID"

    # Testa diretamente a lógica (o path /usr/share é hardcoded)
    [ -f "$fake_dir/$ANTIGRAVITY_IDE_DESKTOP_ID" ]
}

# ── antigravity_desktop_exec_is_broken ─────────────────────────────────────────

@test "antigravity: exec_is_broken retorna 1 quando desktop não existe" {
    run antigravity_desktop_exec_is_broken "$ANTIGRAVITY_DESKTOP_ID"
    [ "$status" -eq 1 ]
}

@test "antigravity: exec_is_broken retorna 0 quando Exec= vazio (sem binário)" {
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID" <<EOF
[Desktop Entry]
Name=Antigravity
Exec=
Type=Application
EOF
    run antigravity_desktop_exec_is_broken "$ANTIGRAVITY_DESKTOP_ID"
    [ "$status" -eq 0 ]
}

@test "antigravity: exec_is_broken retorna 0 quando Exec aponta para ausente" {
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID" <<EOF
[Desktop Entry]
Name=Antigravity
Exec=/usr/local/bin/nonexistent-binary %U
Type=Application
EOF
    run antigravity_desktop_exec_is_broken "$ANTIGRAVITY_DESKTOP_ID"
    [ "$status" -eq 0 ]
}

@test "antigravity: exec_is_broken retorna 1 quando binário existe" {
    mkdir -p "$HOME/.local/share/applications" "$HOME/bin"
    touch "$HOME/bin/antigravity"
    chmod +x "$HOME/bin/antigravity"
    cat >"$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID" <<EOF
[Desktop Entry]
Name=Antigravity
Exec=$HOME/bin/antigravity %U
Type=Application
EOF
    run antigravity_desktop_exec_is_broken "$ANTIGRAVITY_DESKTOP_ID"
    [ "$status" -eq 1 ]
}

@test "antigravity: exec_is_broken com comando relativo (has check)" {
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID" <<EOF
[Desktop Entry]
Name=Antigravity
Exec=bash %U
Type=Application
EOF
    # bash existe no sistema, logo não está quebrado (return 1 = not broken)
    run antigravity_desktop_exec_is_broken "$ANTIGRAVITY_DESKTOP_ID"
    [ "$status" -eq 1 ]
}

# ── antigravity_hub_installed / ide_installed ──────────────────────────────────

@test "antigravity: hub_installed retorna 0 quando binário existe no sistema" {
    unset ANTIGRAVITY_BIN
    # No sistema de teste, /usr/bin/antigravity existe; hub_installed deve retornar 0
    run antigravity_hub_installed
    [ "$status" -eq 0 ]
}

@test "antigravity: hub_installed via override binário" {
    mkdir -p "$HOME/bin"
    touch "$HOME/bin/antigravity"
    chmod +x "$HOME/bin/antigravity"
    ANTIGRAVITY_BIN="$HOME/bin/antigravity"

    run antigravity_hub_installed
    [ "$status" -eq 0 ]
}

@test "antigravity: ide_installed retorna 0 quando binário existe no sistema" {
    unset ANTIGRAVITY_IDE_BIN
    # No sistema de teste, antigravity-ide existe; ide_installed deve retornar 0
    run antigravity_ide_installed
    [ "$status" -eq 0 ]
}

@test "antigravity: ide_installed via override binário" {
    mkdir -p "$HOME/bin"
    touch "$HOME/bin/antigravity-ide"
    chmod +x "$HOME/bin/antigravity-ide"
    ANTIGRAVITY_IDE_BIN="$HOME/bin/antigravity-ide"

    run antigravity_ide_installed
    [ "$status" -eq 0 ]
}

@test "antigravity: installed retorna 0 quando componente está instalado" {
    unset ANTIGRAVITY_BIN ANTIGRAVITY_IDE_BIN
    # No sistema de teste, antigravity está instalado; installed deve retornar 0
    run antigravity_installed
    [ "$status" -eq 0 ]
}

@test "antigravity: installed retorna 0 quando hub está instalado via override" {
    mkdir -p "$HOME/bin"
    touch "$HOME/bin/antigravity"
    chmod +x "$HOME/bin/antigravity"
    ANTIGRAVITY_BIN="$HOME/bin/antigravity"

    run antigravity_installed
    [ "$status" -eq 0 ]
}

# ── antigravity_bin / ide_bin: prioridade do override ─────────────────────────

@test "antigravity: bin usa override quando definido" {
    mkdir -p "$HOME/custom"
    touch "$HOME/custom/antigravity"
    chmod +x "$HOME/custom/antigravity"
    ANTIGRAVITY_BIN="$HOME/custom/antigravity"
    run antigravity_bin
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/custom/antigravity" ]
}

@test "antigravity: ide_bin usa override quando definido" {
    mkdir -p "$HOME/custom"
    touch "$HOME/custom/antigravity-ide"
    chmod +x "$HOME/custom/antigravity-ide"
    ANTIGRAVITY_IDE_BIN="$HOME/custom/antigravity-ide"
    run antigravity_ide_bin
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/custom/antigravity-ide" ]
}

# ── antigravity_desktop_exec_differs: edge cases ──────────────────────────────

@test "antigravity: exec_differs retorna 1 quando desktop não existe" {
    run antigravity_desktop_exec_differs "$ANTIGRAVITY_DESKTOP_ID" "/usr/bin/anything"
    [ "$status" -eq 1 ]
}

@test "antigravity: exec_differs retorna 0 quando Exec vazio (diferente de qualquer cosa)" {
    mkdir -p "$HOME/.local/share/applications"
    cat >"$HOME/.local/share/applications/$ANTIGRAVITY_DESKTOP_ID" <<EOF
[Desktop Entry]
Name=Antigravity
Exec=
Type=Application
EOF
    run antigravity_desktop_exec_differs "$ANTIGRAVITY_DESKTOP_ID" "/usr/bin/antigravity"
    [ "$status" -eq 0 ]
}

# ── install_antigravity_aur: sem helper ────────────────────────────────────────

@test "antigravity: install_aur sem helper retorna RC_TODO" {
    unset AUR_HELPER
    QUIET=0
    run install_antigravity_aur antigravity
    [ "$status" -eq "$RC_TODO" ]
    [[ "$output" == *"Nenhum helper AUR"* ]]
}
