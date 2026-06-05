#!/usr/bin/env bash
# lib/main.sh — dispatch dos steps + finalização. (Banner está em ui.sh.)
# shellcheck shell=bash

run_all_steps() {
    # ── Lock de execução ────────────────────────────────────────────────────────────
    
    run_step "Adquirir lock de execução" acquire_run_lock
    
    # ── Sudo ──────────────────────────────────────────────────────────────────────
    
    if has sudo; then
        run_step "Validar sudo" start_sudo_keepalive
        if [[ "${STEP_RESULTS[-1]}" == "ok" || ( "${STEP_RESULTS[-1]}" == "skip" && "$DRY_RUN" -eq 1 ) ]]; then
            SUDO_READY=1
        fi
    else
        step_skip "Validar sudo" "sudo não instalado"
    fi
    
    # ── Pré-flight: disco + keyring ─────────────────────────────────────────────────
    
    if has pacman; then
        run_step "Pré-flight: disco e keyring" preflight_disk_and_keyring
    fi
    
    # ── Pacman / AUR ──────────────────────────────────────────────────────────────
    
    if has pacman || has yay || has paru; then
        if (( SUDO_READY )); then
            if (( NO_REPAIR )); then
                step_skip "Limpar lock stale do pacman"                 "--no-repair"
                step_skip "Reparar ambiente GnuPG/AUR"                  "--no-repair"
            else
                run_step "Limpar lock stale do pacman"                  ensure_pacman_lock_is_clean
                run_step "Reparar ambiente GnuPG/AUR"                   repair_gnupg_runtime
            fi
            
            run_step "Snapshot pré-upgrade" preupgrade_snapshot
            run_step "Atualizar mirrors" refresh_mirrors
            run_step "Atualizar pacotes do sistema e AUR" update_system_aur
            
            if (( NO_REPAIR )); then
                step_skip "Garantir Burp Suite e Wireshark"             "--no-repair"
                step_skip "Reparar comandos locais conflitantes"        "--no-repair"
                step_skip "Reparar permissoes de captura do Wireshark"  "--no-repair"
                step_skip "Reparar atalhos antigos do Burp"             "--no-repair"
            else
                # Burp/Wireshark são tools custom do autor (gated).
                custom_step_or_skip "Garantir Burp Suite e Wireshark"   ensure_security_tools
                # Shadowing é reparo genérico, útil p/ todos.
                run_step "Reparar comandos locais conflitantes"         repair_known_command_shadowing
                custom_step_or_skip "Reparar permissoes de captura do Wireshark" repair_wireshark_capture_permissions
                custom_step_or_skip "Reparar atalhos antigos do Burp"   repair_broken_burpsuite_desktop_entries
            fi
        else
            for _s in \
            "Limpar lock stale do pacman" \
            "Reparar ambiente GnuPG/AUR" \
            "Atualizar pacotes do sistema e AUR" \
            "Garantir Burp Suite e Wireshark" \
            "Reparar comandos locais conflitantes" \
            "Reparar permissoes de captura do Wireshark" \
            "Reparar atalhos antigos do Burp"; do
                step_skip "$_s" "sudo indisponível"
            done
        fi
    else
        for _s in \
        "Atualizar pacotes do sistema e AUR" \
        "Garantir Burp Suite e Wireshark" \
        "Reparar comandos locais conflitantes" \
        "Reparar permissoes de captura do Wireshark" \
        "Reparar atalhos antigos do Burp"; do
            step_skip "$_s" "gerenciador Arch não encontrado"
        done
    fi
    
    # ── Flatpak ───────────────────────────────────────────────────────────────────
    
    if has flatpak; then
        run_step "Atualizar Flatpak" update_flatpak
    else
        step_skip "Atualizar Flatpak" "flatpak não instalado"
    fi
    
    if has snap; then
        run_step "Atualizar pacotes Snap" update_snap
    else
        step_skip "Atualizar pacotes Snap" "snap não instalado"
    fi
    
    # ── Docker ────────────────────────────────────────────────────────────────────
    
    if has docker; then
        run_step "Atualizar imagens Docker" update_docker_images
    else
        step_skip "Atualizar imagens Docker" "docker não instalado"
    fi
    
    if has arduino-cli; then
        run_step "Atualizar Arduino (cores/libs)" update_arduino
    else
        step_skip "Atualizar Arduino (cores/libs)" "arduino-cli não instalado"
    fi
    
    # ── Firmware ──────────────────────────────────────────────────────────────────
    
    if has fwupdmgr; then
        if (( SUDO_READY )); then
            run_step "Atualizar firmware (fwupd)" update_fwupd
        else
            step_skip "Atualizar firmware (fwupd)" "sudo indisponível"
        fi
    else
        step_skip "Atualizar firmware (fwupd)" "fwupdmgr não instalado"
    fi
    
    if has bootctl; then
        if (( SUDO_READY )); then
            run_step "Atualizar systemd-boot (bootctl)" update_bootctl
        else
            step_skip "Atualizar systemd-boot (bootctl)" "sudo indisponível"
        fi
    else
        step_skip "Atualizar systemd-boot (bootctl)" "bootctl não instalado"
    fi
    
    # ── JavaScript ────────────────────────────────────────────────────────────────
    
    if has npm; then
        run_step "Atualizar npm (self)" update_npm_self
        run_step "Atualizar npm global" update_npm_globals
    else
        step_skip "Atualizar npm (self)" "npm não instalado"
        step_skip "Atualizar npm global" "npm não instalado"
    fi
    
    if has corepack; then
        run_step "Atualizar corepack" update_corepack
    else
        step_skip "Atualizar corepack" "corepack não instalado"
    fi
    
    if has pnpm; then
        run_step "Atualizar pnpm (self)" update_pnpm_self
        run_step "Atualizar pnpm global" update_pnpm_globals
    else
        step_skip "Atualizar pnpm (self)" "pnpm não instalado"
        step_skip "Atualizar pnpm global" "pnpm não instalado"
    fi
    
    # ── Python ────────────────────────────────────────────────────────────────────
    
    if has python && python -m pip --version >/dev/null 2>&1; then
        run_step "Atualizar pacotes pip --user" update_pip_user
    else
        step_skip "Atualizar pacotes pip --user" "python/pip não disponível"
    fi
    
    if has pipx; then
        run_step "Atualizar pacotes pipx" update_pipx
    else
        step_skip "Atualizar pacotes pipx" "pipx não instalado"
    fi
    
    if has uv; then
        run_step "Atualizar uv (self)" update_uv_self
        run_step "Atualizar Python gerenciado pelo uv" update_uv_python
        run_step "Atualizar ferramentas uv" update_uv_tools
    else
        step_skip "Atualizar uv (self)" "uv não instalado"
        step_skip "Atualizar Python gerenciado pelo uv" "uv não instalado"
        step_skip "Atualizar ferramentas uv" "uv não instalado"
    fi
    
    if has poetry; then
        run_step "Atualizar Poetry" update_poetry
    else
        step_skip "Atualizar Poetry" "poetry não instalado"
    fi
    
    # ── Rust ──────────────────────────────────────────────────────────────────────
    
    if has rustup; then
        run_step "Atualizar Rust (rustup)" update_rustup
    else
        step_skip "Atualizar Rust (rustup)" "rustup não instalado"
    fi
    
    if has cargo-install-update; then
        run_step "Atualizar bins do cargo" update_cargo_bins
        elif has cargo; then
        step_skip "Atualizar bins do cargo" "instale cargo-update para habilitar"
    else
        step_skip "Atualizar bins do cargo" "cargo não instalado"
    fi
    
    if has cargo-audit && has cargo; then
        run_step "Auditar binários cargo (CVEs)" audit_cargo_bins
        elif has cargo; then
        step_skip "Auditar binários cargo (CVEs)" "instale cargo-audit para habilitar"
    fi
    
    # ── Go ────────────────────────────────────────────────────────────────────────
    
    if has go; then
        run_step "Atualizar ferramentas Go" update_go_tools
    else
        step_skip "Atualizar ferramentas Go" "go não instalado"
    fi
    
    # ── .NET ──────────────────────────────────────────────────────────────────────
    
    if has dotnet; then
        run_step "Atualizar ferramentas .NET" update_dotnet_tools
    else
        step_skip "Atualizar ferramentas .NET" "dotnet não instalado"
    fi
    
    # ── Google Cloud SDK ──────────────────────────────────────────────────────────
    
    if [[ -n "${GCLOUD_BIN:-}" && -x "${GCLOUD_BIN}" ]]; then
        run_step "Atualizar Google Cloud SDK" update_gcloud
    else
        step_skip "Atualizar Google Cloud SDK" "gcloud não encontrado"
    fi
    
    # ── Ruby ──────────────────────────────────────────────────────────────────────
    
    if has gem; then
        run_step "Atualizar gems de usuário" update_gem_user
    else
        step_skip "Atualizar gems de usuário" "gem não instalado"
    fi
    
    # ── Haskell ───────────────────────────────────────────────────────────────────
    
    if has ghcup; then
        run_step "Atualizar ghcup" update_ghcup
    else
        step_skip "Atualizar ghcup" "ghcup não instalado"
    fi
    
    # ── Hermes ───────────────────────────────────────────────────────────────────
    
    custom_step_or_skip "Atualizar Hermes" update_hermes
    custom_step_or_skip "Atualizar AdGuard VPN CLI" update_adguardvpn
    custom_step_or_skip "Atualizar OpenClaw" update_openclaw
    
    # ── AI CLIs ──────────────────────────────────────────────────────────────────
    
    if has claude; then
        run_step "Atualizar Claude Code CLI" update_claude_code
    else
        step_skip "Atualizar Claude Code CLI" "claude não instalado"
    fi
    
    custom_step_or_skip "Atualizar GitHub Copilot CLI" update_copilot_cli
    
    # ── Shell ─────────────────────────────────────────────────────────────────────
    
    if [[ -f "${ZSH:-$HOME/.oh-my-zsh}/tools/upgrade.sh" ]]; then
        run_step "Atualizar Oh My Zsh" update_omz
        run_step "Atualizar plugins customizados do Zsh" update_omz_custom_plugins
    else
        step_skip "Atualizar Oh My Zsh" "oh-my-zsh não encontrado"
        step_skip "Atualizar plugins customizados do Zsh" "oh-my-zsh não encontrado"
    fi
    
    custom_step_or_skip "Atualizar plugins DankMaterialShell" update_dms_plugins
    
    # ── Editor ────────────────────────────────────────────────────────────────────
    
    if has nvim; then
        if [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy" ]]; then
            run_step "Atualizar plugins Neovim (Lazy)" update_nvim_lazy
        else
            step_skip "Atualizar plugins Neovim (Lazy)" "lazy.nvim não instalado"
        fi
        
        if [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/mason" ]]; then
            run_step "Atualizar LSPs Neovim (Mason)" update_nvim_mason
        else
            step_skip "Atualizar LSPs Neovim (Mason)" "mason.nvim não instalado"
        fi
    else
        step_skip "Atualizar plugins Neovim (Lazy)" "nvim não instalado"
        step_skip "Atualizar LSPs Neovim (Mason)" "nvim não instalado"
    fi
    
    # ── Hyprland plugins ─────────────────────────────────────────────────────────
    
    if has hyprpm; then
        run_step "Atualizar plugins Hyprland (hyprpm)" update_hyprpm
    else
        step_skip "Atualizar plugins Hyprland (hyprpm)" "hyprpm não instalado"
    fi
    
    # ── Limpeza ───────────────────────────────────────────────────────────────────
    
    if (( NO_CLEANUP )); then
        step_skip "Limpar cache do pacman" "--no-cleanup"
        elif has paccache; then
        if (( SUDO_READY )); then
            run_step "Limpar cache do pacman" cleanup_paccache
        else
            step_skip "Limpar cache do pacman" "sudo indisponível"
        fi
    else
        step_skip "Limpar cache do pacman" "paccache não instalado"
    fi
    
    if (( NO_CLEANUP )); then
        step_skip "Remover pacotes orfãos" "--no-cleanup"
        elif has pacman; then
        if (( SUDO_READY )); then
            run_step "Remover pacotes orfãos" cleanup_orphans
        else
            step_skip "Remover pacotes orfãos" "sudo indisponível"
        fi
    else
        step_skip "Remover pacotes orfãos" "pacman não instalado"
    fi
    
    if has pacdiff; then
        if (( SUDO_READY )); then
            run_step "Verificar arquivos .pacnew/.pacsave" check_pacnew_files
        else
            step_skip "Verificar arquivos .pacnew/.pacsave" "sudo indisponível"
        fi
    else
        step_skip "Verificar arquivos .pacnew/.pacsave" "pacdiff não instalado (pacman-contrib)"
    fi
    
    if (( NO_CLEANUP )); then
        step_skip "Limpar symlinks quebrados (~/.local/bin)" "--no-cleanup"
    else
        run_step "Limpar symlinks quebrados (~/.local/bin)" cleanup_broken_symlinks_local_bin
    fi
    
    if (( NO_CLEANUP )); then
        step_skip "Limpar journal do sistema" "--no-cleanup"
        elif has journalctl; then
        if (( SUDO_READY )); then
            run_step "Limpar journal do sistema" cleanup_journal
        else
            step_skip "Limpar journal do sistema" "sudo indisponível"
        fi
    else
        step_skip "Limpar journal do sistema" "journalctl não disponível"
    fi
    
    # ── Verificação final ─────────────────────────────────────────────────────────
    
    run_step "Verificação final de pendências" final_check_pending
    run_step "Doctor: reboot pendente" doctor_reboot_pending
    run_step "Doctor: units systemd falhadas" doctor_failed_systemd_units
    run_step "Doctor: configuração paru Devel" doctor_paru_devel_mode
    run_step "Doctor: journal erros críticos" doctor_journal_errors
    run_step "Doctor: fwupd security" doctor_fwupd_security
    run_step "Doctor: Flatpak repair dry-run" doctor_flatpak_repair_dry_run
    run_step "Doctor: saúde de disco" doctor_disk_health
    run_step "Doctor: saúde de boot" doctor_boot_health
    run_step "Doctor: saúde de rede" doctor_network_health
    run_step "Doctor: serviços com libs antigas" doctor_stale_services
    run_step "Doctor: saúde do pacman" doctor_pacman_health
    run_step "Doctor: hooks ALPM com falha" doctor_pacman_hooks
    run_step "Doctor: SMART e NVMe" doctor_smart_health
    run_step "Doctor: saúde da sessão desktop" doctor_desktop_health
    run_step "Doctor: AI CLIs" doctor_ai_clis
    run_step "Doctor: ambiente Python" doctor_python_env
    run_step "Doctor: conflitos JavaScript global" doctor_js_conflicts
}

finalize() {
    
    print_summary
    write_run_event_json "run_end"
    
    if (( HAS_FAIL )); then
        exit 2
    fi
    
    exit 0
}
