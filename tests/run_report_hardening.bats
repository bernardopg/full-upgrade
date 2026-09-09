#!/usr/bin/env bats
# tests/run_report_hardening.bats — melhorias derivadas do relatório de run de
# 2026-09-08: dump de journal agrupado, segmento loader do boot, dica de GRUB
# no update_bootctl, remediação de TOML inválido no Codex, entradas órfãs de
# FULL_UPGRADE_SKIP, dica de remoção de backups de apps manuais e aviso de
# processos substituídos pelo update.

load test_helper

setup() {
    load_libs
    # Padrão dominante: helpers vivem no módulo do step; o teste faz source
    # direto do módulo (só definições de função, sem efeito colateral).
    # shellcheck source=/dev/null
    source "${FU_LIB}/steps/doctor.sh"
    # shellcheck source=/dev/null
    source "${FU_LIB}/steps/firmware.sh"
    # shellcheck source=/dev/null
    source "${FU_LIB}/steps/mcp.sh"
    # shellcheck source=/dev/null
    source "${FU_LIB}/steps/manual_apps.sh"
    # shellcheck source=/dev/null
    source "${FU_LIB}/steps/pacman.sh"
}

# ── journal_dump_dedupe (lib/steps/doctor.sh) ────────────────────────────────

@test "journal_dump_dedupe: colapsa crash loop com PIDs distintos em uma assinatura" {
    local input=$'Process 889655 (ffmpeg) of user 1000 terminated abnormally\nProcess 901234 (ffmpeg) of user 1000 terminated abnormally\nProcess 912777 (ffmpeg) of user 1000 terminated abnormally\nwlan0: nl80211: kernel reports: multicast RX registrations are not supported'
    run journal_dump_dedupe < <(printf '%s\n' "$input")
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
    printf '%s\n' "$output" | grep -q '^\[ 3 \]x Process N (ffmpeg) of user N terminated abnormally$'
    printf '%s\n' "$output" | grep -q '^\[ 1 \]x wlan0: nl80211'
}

@test "journal_dump_dedupe: preserva ordem da primeira ocorrência" {
    local input=$'b-line\na-line\nb-line'
    run journal_dump_dedupe < <(printf '%s\n' "$input")
    [ "${lines[0]}" = "[ 1 ]x b-line" ]
    [ "${lines[1]}" = "[ 2 ]x a-line" ]
}

@test "journal_dump_dedupe: entrada vazia devolve vazio" {
    run journal_dump_dedupe < <(printf '')
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ── systemd_time_segment_seconds (lib/steps/doctor.sh) ───────────────────────

@test "systemd_time_segment_seconds: extrai loader da linha do systemd-analyze" {
    local line="Startup finished in 9.055s (firmware) + 16.287s (loader) + 2.698s (kernel) + 5.277s (userspace) = 33.319s"
    run systemd_time_segment_seconds "$line" loader
    [ "$output" = "16.287" ]
}

@test "systemd_time_segment_seconds: extrai firmware e userspace" {
    local line="Startup finished in 9.055s (firmware) + 16.287s (loader) + 2.698s (kernel) + 5.277s (userspace) = 33.319s"
    run systemd_time_segment_seconds "$line" firmware
    [ "$output" = "9.055" ]
    run systemd_time_segment_seconds "$line" userspace
    [ "$output" = "5.277" ]
}

@test "systemd_time_segment_seconds: segmento ausente devolve vazio" {
    local line="graphical.target reached 5.277s in userspace."
    run systemd_time_segment_seconds "$line" loader
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "systemd_time_segment_seconds: valor inteiro sem ponto decimal" {
    local line="Startup finished in 3s (loader) = 3s"
    run systemd_time_segment_seconds "$line" loader
    [ "$output" = "3" ]
}

# ── bootloader_skip_hint (lib/steps/firmware.sh) ─────────────────────────────

@test "bootloader_skip_hint: com grub.cfg detectado, mensagem de GRUB" {
    run bootloader_skip_hint 1
    [[ "$output" == *"bootloader GRUB detectado"* ]]
    [[ "$output" == *"não aplicável"* ]]
}

@test "bootloader_skip_hint: sem GRUB, mensagem genérica de ESP" {
    run bootloader_skip_hint 0
    [ "$output" = "systemd-boot não instalado no ESP; pulando" ]
}

# ── codex_toml_remediation_hints (lib/steps/mcp.sh) ──────────────────────

@test "codex_toml_remediation_hints: com headroom e backup, sugere restauração" {
    run codex_toml_remediation_hints 1 1
    [[ "$output" == *"headroom-backup"* ]]
    [[ "$output" == *"headroom init codex"* ]]
    [[ "$output" == *"tabelas duplicadas"* ]]
}

@test "codex_toml_remediation_hints: com headroom sem backup, sugere unwrap" {
    run codex_toml_remediation_hints 0 1
    [[ "$output" == *"headroom unwrap codex"* ]]
}

@test "codex_toml_remediation_hints: sem headroom, dica genérica de backup" {
    run codex_toml_remediation_hints 0 0
    [[ "$output" == *"backup anterior"* ]]
}

# ── skip_list_unknown_entries (lib/core.sh) ───────────────────────────────

@test "skip_list_unknown_entries: aponta entrada que não existe no catálogo" {
    FULL_UPGRADE_SKIP="Atualizar mirrors,Step que não existe mais" \
        run skip_list_unknown_entries < <(printf 'Atualizar mirrors\nDoctor: saúde de rede\n')
    [ "$output" = "Step que não existe mais" ]
}

@test "skip_list_unknown_entries: normaliza espaços e ignora vazias" {
    FULL_UPGRADE_SKIP="  Atualizar mirrors , ,, Fantasma  " \
        run skip_list_unknown_entries < <(printf 'Atualizar mirrors\n')
    [ "$output" = "Fantasma" ]
}

@test "skip_list_unknown_entries: lista vazia devolve vazio" {
    FULL_UPGRADE_SKIP="" run skip_list_unknown_entries < <(printf 'X\n')
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "skip_list_unknown_entries: nenhum falso positivo com todos os steps" {
    local all_names
    all_names="$(step_catalog | awk -F'|' '/^[^#]/ && NF > 1 { print $1 }')"
    [ -n "$all_names" ]
    FULL_UPGRADE_SKIP="$all_names" \
        run skip_list_unknown_entries < <(printf '%s\n' "$all_names")
    [ -z "$output" ]
}

# ── backup_removal_hint (lib/steps/manual_apps.sh) ───────────────────────

@test "backup_removal_hint: monta rm com caminho completo a partir de 'nome  (dir)'" {
    run backup_removal_hint "nomacs-original  (/home/u/.local/bin)"
    [ "$output" = "se obsoleto: rm '/home/u/.local/bin/nomacs-original' (confira antes com 'file')" ]
}

@test "backup_removal_hint: normaliza barra final do diretório" {
    run backup_removal_hint "meuapp  (/opt)"
    [ "$output" = "se obsoleto: rm '/opt/meuapp' (confira antes com 'file')" ]
}

# ── pkg_process_names / warn_running_binaries_for_packages (pacman.sh) ────

@test "pkg_process_names: base sem sufixo e nome completo, dedup, ordenado" {
    run pkg_process_names "ioruba-desktop-bin"
    [ "${lines[0]}" = "ioruba-desktop" ]
    [ "${lines[1]}" = "ioruba-desktop-bin" ]
}

@test "pkg_process_names: casca sufixo simples -git até a base" {
    run pkg_process_names "zapzap-git"
    [ "${lines[0]}" = "zapzap" ]
    [ "${lines[1]}" = "zapzap-git" ]
}

@test "warn_running_binaries_for_packages: avisa processo homônimo em execução" {
    local tmp_bin old_path
    tmp_bin="$(mktemp -d)"
    cat > "$tmp_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "-x" && "$2" == "ioruba-desktop" ]] && { echo 1234; exit 0; }
exit 1
STUB
    chmod +x "$tmp_bin/pgrep"
    old_path="$PATH"
    PATH="$tmp_bin:$PATH"
    run warn_running_binaries_for_packages linux ioruba-desktop-bin
    PATH="$old_path"
    [[ "$output" == *"1 processo(s) em execução"* ]]
    [[ "$output" == *"ioruba-desktop (pkg ioruba-desktop-bin)"* ]]
    rm -rf "$tmp_bin"
}

@test "warn_running_binaries_for_packages: nada rodando, silencioso" {
    local tmp_bin old_path
    tmp_bin="$(mktemp -d)"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp_bin/pgrep"
    chmod +x "$tmp_bin/pgrep"
    old_path="$PATH"
    PATH="$tmp_bin:$PATH"
    run warn_running_binaries_for_packages linux ioruba-desktop-bin
    PATH="$old_path"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -rf "$tmp_bin"
}

@test "warn_running_binaries_for_packages: sem pacotes pendentes, silencioso" {
    run warn_running_binaries_for_packages
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
