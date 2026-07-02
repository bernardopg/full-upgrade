#!/usr/bin/env bash
# lib/main.sh — dispatch dos steps + finalização. (Banner está em ui.sh.)
# shellcheck shell=bash

run_all_steps() {
    # ── Lock de execução ────────────────────────────────────────────────────────────
    
    run_step "Adquirir lock de execução" acquire_run_lock
    if [[ "${STEP_RESULTS[-1]}" == "todo" ]]; then
        # Outra instância segura o lock: prosseguir arriscaria dois pacman/paru
        # concorrentes no mesmo DB. Aborta com resumo e exit 2.
        log_always "${C_RED}Outra instância do full-upgrade está em execução — abortando.${C_RESET}"
        HAS_FAIL=1
        finalize
    fi

    # ── Sudo ──────────────────────────────────────────────────────────────────────
    
    if has "${PRIV_CMD:-sudo}"; then
        run_step "Validar sudo" start_sudo_keepalive
        if [[ "${STEP_RESULTS[-1]}" == "ok" || ( "${STEP_RESULTS[-1]}" == "skip" && "$DRY_RUN" -eq 1 ) ]]; then
            SUDO_READY=1
        fi
    else
        step_skip "Validar sudo" "${PRIV_CMD:-sudo} não instalado"
    fi
    
    # ── Pré-flight: disco + keyring ─────────────────────────────────────────────────
    run_step "Pré-flight: espaço em disco" preflight_disk_space
    if has pacman; then
        run_step "Atualizar archlinux-keyring" update_archlinux_keyring
    else
        step_skip "Atualizar archlinux-keyring" "pacman não instalado"
    fi

    # ── Pacman / AUR ──────────────────────────────────────────────────────────────
    
    if has pacman || has yay || has paru || has pikaur; then
        if (( SUDO_READY )); then
            if (( NO_REPAIR )); then
                step_skip "Limpar lock stale do pacman"                 "--no-repair"
                step_skip "Reparar ambiente GnuPG/AUR"                  "--no-repair"
            else
                run_step "Limpar lock stale do pacman"                  ensure_pacman_lock_is_clean
                run_step "Reparar ambiente GnuPG/AUR"                   repair_gnupg_runtime
            fi

            if (( NO_REPAIR )); then
                step_skip "Reparar comandos locais conflitantes"        "--no-repair"
                step_skip "Garantir Wireshark"                         "--no-repair"
                step_skip "Garantir Burp Suite"                        "--no-repair"
                step_skip "Reparar permissoes de captura do Wireshark"  "--no-repair"
                step_skip "Reparar atalhos antigos do Burp"             "--no-repair"
            else
                # Shadowing é reparo genérico, útil p/ todos e deve acontecer
                # antes do update principal.
                run_step "Reparar comandos locais conflitantes"         repair_known_command_shadowing
                # Wireshark/Burp ficam atrás de ENABLE_CUSTOM_TOOLS: instalam pacotes
                # se ausentes, então não devem rodar por padrão. Opt-in explícito.
                custom_step_or_skip "Garantir Wireshark"                ensure_wireshark
                custom_step_or_skip "Garantir Burp Suite"               ensure_burpsuite
                custom_step_or_skip "Reparar permissoes de captura do Wireshark" repair_wireshark_capture_permissions
                custom_step_or_skip "Reparar atalhos antigos do Burp"   repair_broken_burpsuite_desktop_entries
            fi
            
            run_step "Backup de configs críticas" backup_critical_configs
            run_step "Snapshot pré-upgrade" preupgrade_snapshot
            run_step "Atualizar mirrors" refresh_mirrors
            capture_installed_pkgs "$PKG_SNAP_BEFORE"   # L3: estado pré-upgrade
            run_step "Atualizar pacotes do sistema e AUR" update_system_aur
        else
            for _s in \
            "Limpar lock stale do pacman" \
            "Reparar ambiente GnuPG/AUR" \
            "Backup de configs críticas" \
            "Atualizar pacotes do sistema e AUR" \
            "Garantir Wireshark" \
            "Garantir Burp Suite" \
            "Reparar comandos locais conflitantes" \
            "Reparar permissoes de captura do Wireshark" \
            "Reparar atalhos antigos do Burp"; do
                step_skip "$_s" "sudo indisponível"
            done
        fi
    else
        for _s in \
        "Backup de configs críticas" \
        "Atualizar pacotes do sistema e AUR" \
        "Garantir Wireshark" \
        "Garantir Burp Suite" \
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

    if has bun; then
        run_step "Atualizar Bun" update_bun
    else
        step_skip "Atualizar Bun" "bun não instalado"
    fi

    if has deno; then
        run_step "Atualizar Deno" update_deno
    else
        step_skip "Atualizar Deno" "deno não instalado"
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
    else
        step_skip "Auditar binários cargo (CVEs)" "cargo não instalado"
    fi

    # Auto-remediação opcional (F7): só sob AUTO_FIX_RUST_CVES=1, e nunca sob
    # --no-repair (efeito mutating; --mode doctor/--dry-run já a pulam).
    if (( ${AUTO_FIX_RUST_CVES:-0} == 0 )); then
        step_skip "Auto-remediar CVEs de toolchain Rust" "AUTO_FIX_RUST_CVES=0"
    elif (( NO_REPAIR )); then
        step_skip "Auto-remediar CVEs de toolchain Rust" "--no-repair"
    elif has cargo-audit && has cargo; then
        run_step "Auto-remediar CVEs de toolchain Rust" autofix_rust_cves
    else
        step_skip "Auto-remediar CVEs de toolchain Rust" "cargo-audit não instalado"
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
    
    # ── Firmware / Boot ───────────────────────────────────────────────────────────

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
    
    # ── Integrações de ferramentas (rodam por presença, como os steps core) ──────

    if has hermes; then
        run_step "Atualizar Hermes" update_hermes
    else
        step_skip "Atualizar Hermes" "hermes não instalado"
    fi

    if has rtk || [[ -x "${RTK_BIN:-}" ]]; then
        run_step "Atualizar RTK" update_rtk
    else
        step_skip "Atualizar RTK" "rtk não instalado"
    fi

    if has openclaw || [[ -x "${OPENCLAW_BIN:-}" ]]; then
        run_step "Atualizar OpenClaw" update_openclaw
    else
        step_skip "Atualizar OpenClaw" "openclaw não instalado"
    fi

    # ── AI CLIs ──────────────────────────────────────────────────────────────────

    if has claude; then
        run_step "Atualizar Claude Code CLI" update_claude_code
    else
        step_skip "Atualizar Claude Code CLI" "claude não instalado"
    fi

    if has copilot || [[ -x "${COPILOT_BIN:-}" ]]; then
        run_step "Atualizar GitHub Copilot CLI" update_copilot_cli
    else
        step_skip "Atualizar GitHub Copilot CLI" "copilot não instalado"
    fi

    if has opencode; then
        run_step "Atualizar opencode" update_opencode
    else
        step_skip "Atualizar opencode" "opencode não instalado"
    fi

    if has ollama; then
        run_step "Atualizar Ollama" update_ollama
    else
        step_skip "Atualizar Ollama" "ollama não instalado"
    fi

    if has npx && [[ -d "${HOME}/.agents/skills" ]]; then
        run_step "Atualizar agent skills (skills CLI)" update_agent_skills
    else
        step_skip "Atualizar agent skills (skills CLI)" "npx ou ~/.agents/skills ausente"
    fi

    if (( ${MCP_AUTO_UPDATE:-0} == 1 )) \
       && { [[ -r "${HOME}/.claude.json" ]] || [[ -r "${HOME}/.codex/config.toml" ]]; }; then
        run_step "Atualizar servidores MCP" mcp_update_servers
    else
        step_skip "Atualizar servidores MCP" "MCP_AUTO_UPDATE!=1 ou sem fonte MCP"
    fi

    if declare -F orca_ide_installed >/dev/null 2>&1 && orca_ide_installed; then
        run_step "Garantir Orca IDE" ensure_orca_ide
    elif (( ${ENABLE_CUSTOM_TOOLS:-0} == 1 )); then
        run_step "Garantir Orca IDE" ensure_orca_ide
    else
        step_skip "Garantir Orca IDE" "orca não instalado e ENABLE_CUSTOM_TOOLS=0"
    fi

    if declare -F antigravity_installed >/dev/null 2>&1 && antigravity_installed; then
        run_step "Garantir Antigravity" ensure_antigravity
    elif (( ${ENABLE_CUSTOM_TOOLS:-0} == 1 )); then
        run_step "Garantir Antigravity" ensure_antigravity
    else
        step_skip "Garantir Antigravity" "antigravity não instalado e ENABLE_CUSTOM_TOOLS=0"
    fi

    if has kimi; then
        run_step "Atualizar Kimi CLI" update_kimi
    else
        step_skip "Atualizar Kimi CLI" "kimi não instalado"
    fi

    # ── Apps manuais (fora de qualquer gerenciador de pacotes) ───────────────────
    # Cada programa instalado por instalador próprio/binário avulso tem seu step
    # dedicado; rodam por presença e usam o self-update nativo de cada um.

    if has droid; then
        run_step "Atualizar Factory droid" update_droid
    else
        step_skip "Atualizar Factory droid" "droid não instalado"
    fi

    if has obs || pacman -Q obs-studio >/dev/null 2>&1; then
        run_step "Atualizar OBS (plugins e extensões)" update_obs_plugins
    else
        step_skip "Atualizar OBS (plugins e extensões)" "OBS Studio não instalado"
    fi

    if has coderabbit; then
        run_step "Atualizar CodeRabbit CLI" update_coderabbit
    else
        step_skip "Atualizar CodeRabbit CLI" "coderabbit não instalado"
    fi

    if has kiro-cli; then
        run_step "Atualizar Kiro CLI (Amazon)" update_kiro_cli
    else
        step_skip "Atualizar Kiro CLI (Amazon)" "kiro-cli não instalado"
    fi

    if has snyk; then
        run_step "Atualizar Snyk CLI" update_snyk
    else
        step_skip "Atualizar Snyk CLI" "snyk não instalado"
    fi

    if has zap || has zap.sh; then
        run_step "Atualizar add-ons do OWASP ZAP" update_zap
    else
        step_skip "Atualizar add-ons do OWASP ZAP" "zap não instalado"
    fi

    if has gk; then
        run_step "Atualizar GitKraken CLI (gk)" update_gk
    else
        step_skip "Atualizar GitKraken CLI (gk)" "gk não instalado"
    fi

    # ── Rede ─────────────────────────────────────────────────────────────────────

    if has adguardvpn-cli || [[ -x "${ADGUARD_BIN:-}" ]]; then
        run_step "Atualizar AdGuard VPN CLI" update_adguardvpn
    else
        step_skip "Atualizar AdGuard VPN CLI" "adguardvpn-cli não instalado"
    fi

    # ── Shell ─────────────────────────────────────────────────────────────────────
    
    if [[ -f "${ZSH:-$HOME/.oh-my-zsh}/tools/upgrade.sh" ]]; then
        run_step "Atualizar Oh My Zsh" update_omz
        run_step "Atualizar plugins customizados do Zsh" update_omz_custom_plugins
    else
        step_skip "Atualizar Oh My Zsh" "oh-my-zsh não encontrado"
        step_skip "Atualizar plugins customizados do Zsh" "oh-my-zsh não encontrado"
    fi
    
    if [[ -d "${DMS_PLUGINS_DIR:-$HOME/.config/DankMaterialShell/plugins}" ]]; then
        run_step "Atualizar plugins DankMaterialShell" update_dms_plugins
    else
        step_skip "Atualizar plugins DankMaterialShell" "DankMaterialShell não encontrado"
    fi

    if has ya && has yazi; then
        run_step "Atualizar plugins Yazi" update_yazi_plugins
    else
        step_skip "Atualizar plugins Yazi" "ya/yazi não instalado"
    fi

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

    # ── Extensões de IDE (família VSCode) ─────────────────────────────────────────

    if has code || has cursor || has codium || has code-insiders || has vscodium; then
        run_step "Atualizar extensões de IDE (VSCode/Cursor)" update_ide_extensions
    else
        step_skip "Atualizar extensões de IDE (VSCode/Cursor)" "nenhum IDE VSCode encontrado"
    fi

    # ── Hyprland plugins ─────────────────────────────────────────────────────────
    
    if has hyprpm; then
        # hyprpm pode pedir autenticação (polkit/sudo) para instalar headers;
        # sem credencial validada, o prompt travaria até o timeout do step.
        if (( SUDO_READY )); then
            run_step "Atualizar plugins Hyprland (hyprpm)" update_hyprpm
        else
            step_skip "Atualizar plugins Hyprland (hyprpm)" "sudo indisponível"
        fi
    else
        step_skip "Atualizar plugins Hyprland (hyprpm)" "hyprpm não instalado"
    fi
    
    # ── Limpeza ───────────────────────────────────────────────────────────────────
    
    if (( NO_CLEANUP )); then
        step_skip "Limpar cache do pacman" "--no-cleanup"
        step_skip "Limpar snapshots full-upgrade antigos" "--no-cleanup"
    elif has paccache; then
        if (( SUDO_READY )); then
            run_step "Limpar cache do pacman" cleanup_paccache
            run_step "Limpar snapshots full-upgrade antigos" cleanup_old_snapshots
        else
            step_skip "Limpar cache do pacman" "sudo indisponível"
            step_skip "Limpar snapshots full-upgrade antigos" "sudo indisponível"
        fi
    else
        step_skip "Limpar cache do pacman" "paccache não instalado"
        if (( SUDO_READY )); then
            run_step "Limpar snapshots full-upgrade antigos" cleanup_old_snapshots
        else
            step_skip "Limpar snapshots full-upgrade antigos" "sudo indisponível"
        fi
    fi

    if (( NO_CLEANUP )); then
        step_skip "Limpar cache de build do AUR" "--no-cleanup"
    elif has paru || has yay || has pikaur; then
        run_step "Limpar cache de build do AUR" cleanup_aur_cache
    else
        step_skip "Limpar cache de build do AUR" "sem helper AUR (paru/yay/pikaur)"
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

    if has pacdiff; then
        if (( SUDO_READY )); then
            run_step "Verificar arquivos .pacnew/.pacsave" check_pacnew_files
        else
            step_skip "Verificar arquivos .pacnew/.pacsave" "sudo indisponível"
        fi
    else
        step_skip "Verificar arquivos .pacnew/.pacsave" "pacdiff não instalado (pacman-contrib)"
    fi
    
    run_step "Verificação final de pendências" final_check_pending

    # Auto-remediação opcional: só sob AUTO_FIX_FINAL_PENDING=1, nunca sob
    # --no-repair (efeito mutating; --mode doctor/--dry-run já a pulam).
    if (( ${AUTO_FIX_FINAL_PENDING:-0} == 0 )); then
        step_skip "Auto-remediar pendências finais" "AUTO_FIX_FINAL_PENDING=0"
    elif (( NO_REPAIR )); then
        step_skip "Auto-remediar pendências finais" "--no-repair"
    elif ! (( SUDO_READY )); then
        step_skip "Auto-remediar pendências finais" "sudo indisponível"
    else
        run_step "Auto-remediar pendências finais" autofix_final_pending
    fi

    run_step "Checar atualização do full-upgrade" self_update_notice
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
    if (( NO_REPAIR )); then
        step_skip "Reiniciar serviços com libs antigas" "--no-repair"
    elif (( RESTART_SERVICES )) && ! has checkservices; then
        step_skip "Reiniciar serviços com libs antigas" "checkservices não instalado"
    elif (( RESTART_SERVICES )) && (( ! SUDO_READY )); then
        step_skip "Reiniciar serviços com libs antigas" "sudo indisponível"
    elif (( RESTART_SERVICES )); then
        run_step "Reiniciar serviços com libs antigas" restart_stale_services
    else
        step_skip "Reiniciar serviços com libs antigas" "--restart-services ausente"
    fi
    run_step "Doctor: saúde do pacman" doctor_pacman_health
    run_step "Doctor: CVEs de pacotes oficiais (arch-audit)" doctor_arch_audit_cves
    run_step "Doctor: arquivos .pacnew/.pacsave" doctor_pacfiles
    run_step "Doctor: hooks ALPM com falha" doctor_pacman_hooks
    run_step "Doctor: SMART e NVMe" doctor_smart_health
    run_step "Doctor: saúde da sessão desktop" doctor_desktop_health
    run_step "Doctor: apps manuais (fora de pacote)" doctor_manual_apps

    if has obs || pacman -Q obs-studio >/dev/null 2>&1; then
        run_step "Doctor: módulos OBS" doctor_obs_modules
    else
        step_skip "Doctor: módulos OBS" "OBS Studio não instalado"
    fi
    run_step "Doctor: AI CLIs" doctor_ai_clis
    if [[ -r "${HOME}/.claude.json" ]] || [[ -r "${HOME}/.codex/config.toml" ]] \
       || has claude || has codex || has opencode; then
        run_step "Doctor: servidores MCP" doctor_mcp_servers
    else
        step_skip "Doctor: servidores MCP" "nenhuma fonte MCP (claude.json/codex)"
    fi
    run_step "Doctor: ambiente Python" doctor_python_env
    run_step "Doctor: conflitos JavaScript global" doctor_js_conflicts
    if has gem; then
        run_step "Doctor: gems do usuário sombreando o sistema" doctor_gem_shadow
    else
        step_skip "Doctor: gems do usuário sombreando o sistema" "gem não instalado"
    fi
    run_step "Doctor: saúde do btrfs" doctor_btrfs_health

    # Auto-remediação opcional (G1): só sob AUTO_BTRFS_SCRUB=1, e nunca sob
    # --no-repair (efeito mutating; --mode doctor/--dry-run já a pulam).
    if (( ${AUTO_BTRFS_SCRUB:-0} == 0 )); then
        step_skip "Auto-remediar scrub btrfs" "AUTO_BTRFS_SCRUB=0"
    elif (( NO_REPAIR )); then
        step_skip "Auto-remediar scrub btrfs" "--no-repair"
    elif has btrfs; then
        run_step "Auto-remediar scrub btrfs" autofix_btrfs_scrub
    else
        step_skip "Auto-remediar scrub btrfs" "btrfs não instalado"
    fi

    run_step "Doctor: tempo de boot" doctor_boot_time
}

finalize() {

    print_summary
    # L3: "o que mudou" — captura o estado pós-run e mostra o diff de pacotes.
    capture_installed_pkgs "$PKG_SNAP_AFTER"
    print_pkg_changes "$PKG_SNAP_BEFORE" "$PKG_SNAP_AFTER"
    write_pkg_changes_json "$PKG_SNAP_BEFORE" "$PKG_SNAP_AFTER"
    rm -f "$PKG_SNAP_BEFORE" "$PKG_SNAP_AFTER" 2>/dev/null || true
    write_run_event_json "run_end"
    generate_report_on_finish
    notify_on_finish

    if (( HAS_FAIL )); then
        exit 2
    fi
    
    exit 0
}
