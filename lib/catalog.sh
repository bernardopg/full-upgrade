#!/usr/bin/env bash
# lib/catalog.sh — registry de steps + parser + filtros
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

step_catalog() {
  # formato: nome|categoria|tags|efeito|timeout|cmd_deps|func_name|descrição
  # timeout: segundos (0 = sem limite); cmd_deps: binários separados por vírgula (vazio = nenhum)
  # func_name: nome exato da função Bash que implementa o step (vazio = sem função direta)
  cat <<'EOF'
Adquirir lock de execução|core|lock,preflight|read|15||acquire_run_lock|Impede instâncias concorrentes do full-upgrade via flock.
Validar sudo|core|sudo,preflight|read|30||start_sudo_keepalive|Valida sudo e mantém a credencial ativa durante a execução.
Pré-flight: disco e keyring|core|disk,keyring,sudo,preflight|mutating|120|pacman|preflight_disk_and_keyring|Verifica espaço livre mínimo e atualiza archlinux-keyring.
Backup de configs críticas|core|backup,config,sudo,preflight|mutating|300|tar|backup_critical_configs|Arquiva configs essenciais de /etc em tar.zst com rotação antes das mutações.
Snapshot pré-upgrade|pacman|snapshot,btrfs,sudo|mutating|300||preupgrade_snapshot|Cria snapshot btrfs (snapper/timeshift) antes do upgrade.
Atualizar mirrors|pacman|mirror,network,sudo|mutating|120||refresh_mirrors|Atualiza mirrorlist via reflector/rate-mirrors com backup.
Limpar lock stale do pacman|repair|pacman,mutating|mutating|30||ensure_pacman_lock_is_clean|Remove lock obsoleto do pacman quando nenhum gerenciador está rodando.
Reparar ambiente GnuPG/AUR|repair|aur,gnupg,mutating|mutating|60||repair_gnupg_runtime|Corrige permissões de GnuPG e reinicia dirmngr para evitar falhas no AUR.
Atualizar pacotes do sistema e AUR|pacman|update,network,slow,system,aur|mutating|600|paru|update_system_aur|Atualiza pacotes oficiais e AUR com paru/yay/pacman.
Garantir Burp Suite e Wireshark|repair|security,aur,network,mutating|mutating|300|paru|ensure_security_tools|Garante ferramentas de segurança e usa fallback oficial para Burp quando necessário.
Reparar comandos locais conflitantes|repair|shadowing,mutating|mutating|30||repair_known_command_shadowing|Move binários manuais em /usr/local/bin que sombreiam pacotes gerenciados.
Reparar permissoes de captura do Wireshark|repair|security,wireshark,mutating|mutating|30|wireshark|repair_wireshark_capture_permissions|Ajusta grupo, modo e capabilities do dumpcap.
Reparar atalhos antigos do Burp|repair|desktop,mutating|mutating|30||repair_broken_burpsuite_desktop_entries|Move atalhos locais do Burp que apontam para executáveis inexistentes.
Atualizar Flatpak|flatpak|update,network,slow|mutating|600|flatpak|update_flatpak|Atualiza metadados e aplicações Flatpak.
Atualizar imagens Docker|docker|update,network,slow|mutating|600|docker|update_docker_images|Puxa imagens remotas locais e alerta containers usando imagem antiga.
Atualizar Arduino (cores/libs)|lang|arduino,update,network|mutating|300|arduino-cli|update_arduino|Atualiza índices, cores e bibliotecas do arduino-cli.
Atualizar firmware (fwupd)|firmware|update,network,slow,sudo|mutating|300|fwupdmgr|update_fwupd|Atualiza metadados e firmware via fwupd.
Atualizar systemd-boot (bootctl)|firmware|boot,sudo,mutating|mutating|60|bootctl|update_bootctl|Atualiza systemd-boot quando instalado no ESP.
Atualizar npm (self)|lang|javascript,npm,update,network|mutating|120|npm|update_npm_self|Atualiza o próprio npm global.
Atualizar npm global|lang|javascript,npm,update,network,slow|mutating|300|npm|update_npm_globals|Atualiza pacotes npm globais com tratamento de links e deps locais.
Atualizar corepack|lang|javascript,corepack,update,network|mutating|120|npm|update_corepack|Atualiza corepack via npm.
Atualizar pnpm (self)|lang|javascript,pnpm,update,network|mutating|120|pnpm|update_pnpm_self|Atualiza o próprio pnpm.
Atualizar pnpm global|lang|javascript,pnpm,update,network|mutating|300|pnpm|update_pnpm_globals|Atualiza pacotes pnpm globais e remove deps locais quebradas.
Atualizar pacotes pip --user|lang|python,pip,update,network|mutating|300|pip|update_pip_user|Atualiza pacotes Python instalados no usuário.
Atualizar pacotes pipx|lang|python,pipx,update,network|mutating|300|pipx|update_pipx|Atualiza aplicações gerenciadas pelo pipx.
Atualizar uv (self)|lang|python,uv,update,network|mutating|120|uv|update_uv_self|Atualiza o binário uv.
Atualizar Python gerenciado pelo uv|lang|python,uv,update,network,slow|mutating|300|uv|update_uv_python|Atualiza versões Python gerenciadas pelo uv.
Atualizar ferramentas uv|lang|python,uv,update,network|mutating|300|uv|update_uv_tools|Atualiza ferramentas instaladas pelo uv.
Atualizar Poetry|lang|python,poetry,update,network|mutating|120|pip|update_poetry|Atualiza Poetry instalado via pip --user.
Atualizar Rust (rustup)|lang|rust,rustup,update,network,slow|mutating|600|rustup|update_rustup|Atualiza toolchains Rust quando rustup reporta update disponível.
Atualizar bins do cargo|lang|rust,cargo,update,network,slow|mutating|600|cargo-install-update|update_cargo_bins|Atualiza binários Cargo usando cargo-install-update.
Auditar binários cargo (CVEs)|doctor|rust,cargo,security,read,network|read|120|cargo-audit|audit_cargo_bins|Audita binários Cargo contra advisories conhecidos.
Atualizar ferramentas Go|lang|go,update,network|mutating|300|go|update_go_tools|Atualiza ferramentas Go instaladas em GOPATH/bin.
Atualizar ferramentas .NET|lang|dotnet,update,network|mutating|300|dotnet|update_dotnet_tools|Atualiza ferramentas .NET globais.
Atualizar Google Cloud SDK|lang|gcloud,update,network,slow|mutating|600|gcloud|update_gcloud|Atualiza componentes do Google Cloud SDK.
Atualizar gems de usuário|lang|ruby,gem,update,network|mutating|300|gem|update_gem_user|Atualiza gems instaladas no usuário.
Atualizar ghcup|lang|haskell,ghcup,update,network|mutating|300|ghcup|update_ghcup|Atualiza ghcup.
Atualizar Hermes|ai|hermes,update,network|mutating|120|hermes|update_hermes|Atualiza Hermes CLI quando disponível.
Atualizar AdGuard VPN CLI|network|adguard,update,network|mutating|120||update_adguardvpn|Atualiza AdGuard VPN CLI instalado em /usr/local/bin.
Atualizar OpenClaw|ai|openclaw,update,network|mutating|120|openclaw|update_openclaw|Atualiza OpenClaw quando disponível.
Atualizar Claude Code CLI|ai|claude,update,network|mutating|120|claude|update_claude_code|Atualiza Claude Code CLI.
Atualizar GitHub Copilot CLI|ai|copilot,update,network|mutating|120||update_copilot_cli|Atualiza GitHub Copilot CLI local.
Atualizar Oh My Zsh|shell|zsh,update,network|mutating|120||update_omz|Atualiza Oh My Zsh.
Atualizar plugins customizados do Zsh|shell|zsh,git,update,network|mutating|120|git|update_omz_custom_plugins|Atualiza plugins customizados do Oh My Zsh.
Atualizar plugins DankMaterialShell|shell|dms,git,update,network|mutating|120|git|update_dms_plugins|Atualiza plugins do DankMaterialShell.
Atualizar plugins Neovim (Lazy)|editor|nvim,lazy,update,network,slow|mutating|300|nvim|update_nvim_lazy|Sincroniza plugins Lazy.nvim.
Atualizar LSPs Neovim (Mason)|editor|nvim,mason,update,network|mutating|300|nvim|update_nvim_mason|Atualiza registros e ferramentas Mason.nvim.
Atualizar plugins Hyprland (hyprpm)|hyprland|hyprpm,update,network|mutating|120|hyprpm|update_hyprpm|Atualiza plugins Hyprland via hyprpm.
Limpar cache do pacman|cleanup|pacman,sudo,mutating|mutating|60||cleanup_paccache|Remove versões antigas do cache pacman mantendo duas.
Remover pacotes orfãos|cleanup|pacman,sudo,mutating|mutating|120||cleanup_orphans|Remove pacotes órfãos somente com confirmação ou --yes.
Verificar arquivos .pacnew/.pacsave|final|pacman,config,read,sudo|read|30||check_pacnew_files|Lista arquivos .pacnew/.pacsave que precisam de merge manual.
Limpar symlinks quebrados (~/.local/bin)|cleanup|local-bin,mutating|mutating|30||cleanup_broken_symlinks_local_bin|Remove symlinks quebrados em ~/.local/bin.
Limpar journal do sistema|cleanup|journal,sudo,mutating|mutating|60||cleanup_journal|Executa vacuum do journal mantendo limites de tempo e tamanho.
Verificação final de pendências|final|pacman,aur,read,network|read|60||final_check_pending|Confere se ainda há updates pendentes em pacman/AUR.
Checar atualização do full-upgrade|final|self-update,read,network|read|30|curl|self_update_notice|Avisa se há uma versão mais nova do próprio full-upgrade no GitHub.
Doctor: reboot pendente|doctor|kernel,read|read|15||doctor_reboot_pending|Compara kernel em execução com pacote linux instalado.
Doctor: units systemd falhadas|doctor|systemd,read|read|15||doctor_failed_systemd_units|Lista units systemd falhadas no sistema e usuário.
Doctor: configuração paru Devel|doctor|paru,aur,read|read|10|paru|doctor_paru_devel_mode|Detecta configuração global Devel no paru.
Doctor: journal erros críticos|doctor|journal,systemd,read|read|30||doctor_journal_errors|Mostra erros críticos do boot atual com limite de linhas.
Doctor: fwupd security|doctor|fwupd,firmware,security,read|read|60|fwupdmgr|doctor_fwupd_security|Executa auditoria de segurança de firmware via fwupdmgr.
Doctor: Flatpak repair dry-run|doctor|flatpak,read|read|60|flatpak|doctor_flatpak_repair_dry_run|Executa flatpak repair --user --dry-run para detectar inconsistências.
Doctor: saúde de disco|doctor|disk,read|read|15||doctor_disk_health|Verifica uso de espaço e inodes em mounts essenciais.
Doctor: saúde de boot|doctor|boot,systemd,read,sudo|read|30|bootctl|doctor_boot_health|Verifica systemd-boot, kernel/initrd no ESP e espaço livre.
Doctor: saúde de rede|doctor|network,read|read|30||doctor_network_health|Verifica DNS e conectividade HTTPS para mirrors Arch.
Doctor: serviços com libs antigas|doctor|systemd,read,sudo|read|60||doctor_stale_services|Detecta serviços usando bibliotecas atualizadas sem restart (needrestart/checkservices).
Doctor: saúde do pacman|doctor|pacman,read|read|120||doctor_pacman_health|Verifica pacotes com arquivos faltando via pacman -Qkq.
Doctor: hooks ALPM com falha|doctor|pacman,journal,read|read|15||doctor_pacman_hooks|Detecta hooks ALPM com erro no journal do boot atual.
Doctor: SMART e NVMe|doctor|disk,smart,read,sudo|read|60||doctor_smart_health|Verifica saúde de discos via smartctl e nvme smart-log.
Doctor: saúde da sessão desktop|doctor|desktop,read|read|15||doctor_desktop_health|Verifica xdg-desktop-portal, PipeWire e WirePlumber.
Doctor: AI CLIs|doctor|ai,read|read|15||doctor_ai_clis|Verifica versão instalada de claude, copilot e hermes.
Doctor: ambiente Python|doctor|python,pipx,uv,read|read|30||doctor_python_env|Detecta dependências pip quebradas, pipx venvs quebradas e uv tools com interpreter ausente.
Doctor: conflitos JavaScript global|doctor|javascript,npm,pnpm,read|read|30|npm|doctor_js_conflicts|Audita prefixo npm global e detecta pacotes duplicados entre npm e pnpm global.
Doctor: saúde do btrfs|doctor|btrfs,disk,read,sudo|read|60|btrfs|doctor_btrfs_health|Verifica erros de device acumulados e idade do último scrub em raiz btrfs.
Doctor: tempo de boot|doctor|boot,systemd,read|read|30||doctor_boot_time|Reporta tempo total de boot (systemd-analyze) e as piores units.
EOF
}

catalog_match_token() {
  local category="$1"
  local tags="$2"
  local token="$3"
  [[ ",${category},${tags}," == *",${token},"* ]]
}

# Conta steps do catálogo que NÃO estão na lista de skip (FULL_UPGRADE_SKIP).
# Após apply_mode_and_early_exits, FULL_UPGRADE_SKIP já reflete --mode/--only/--skip-category,
# então isto é uma estimativa fiel do total de steps planejados (p/ a barra de progresso).
count_effective_steps() {
  local name category tags effect timeout cmd_deps func_name desc
  local total=0
  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    _step_skip_requested "$name" && continue
    ((total++))
  done < <(step_catalog)
  printf '%d' "$total"
}

catalog_has_token() {
  local token="$1"
  local name category tags effect timeout cmd_deps func_name desc
  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    if catalog_match_token "$category" "$tags" "$token"; then
      return 0
    fi
  done < <(step_catalog)
  return 1
}

add_skip_category() {
  local token="$1"
  local name category tags effect timeout cmd_deps func_name desc
  local matched=0

  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    if catalog_match_token "$category" "$tags" "$token"; then
      add_skip_step "$name"
      matched=1
    fi
  done < <(step_catalog)

  (( matched == 1 ))
}

apply_only_category() {
  local token="$1"
  local name category tags effect timeout cmd_deps func_name desc

  catalog_has_token "$token" || return 1

  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    [[ "$category" == "core" || "$category" == "final" ]] && continue
    if ! catalog_match_token "$category" "$tags" "$token"; then
      add_skip_step "$name"
    fi
  done < <(step_catalog)
}

print_step_catalog() {
  local name category tags effect timeout cmd_deps func_name desc
  printf '%-48s  %-10s  %-32s  %-8s  %-7s  %-20s  %-30s  %s\n' "STEP" "CATEGORIA" "TAGS" "EFEITO" "TIMEOUT" "CMD_DEPS" "FUNÇÃO" "DESCRIÇÃO"
  printf '%-48s  %-10s  %-32s  %-8s  %-7s  %-20s  %-30s  %s\n' "----" "---------" "----" "------" "-------" "--------" "------" "---------"
  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    local to_disp="${timeout}s"
    [[ "$timeout" == "0" || -z "$timeout" ]] && to_disp="∞"
    printf '%-48s  %-10s  %-32s  %-8s  %-7s  %-20s  %-30s  %s\n' "$name" "$category" "$tags" "$effect" "$to_disp" "${cmd_deps:--}" "${func_name:--}" "$desc"
  done < <(step_catalog)
}

explain_step() {
  local wanted="$1"
  local name category tags effect timeout cmd_deps func_name desc
  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ "$name" == "$wanted" ]] || continue
    local to_disp="${timeout}s"
    [[ "$timeout" == "0" || -z "$timeout" ]] && to_disp="sem limite"
    printf 'Step: %s\n' "$name"
    printf 'Categoria: %s\n' "$category"
    printf 'Tags: %s\n' "$tags"
    printf 'Efeito: %s\n' "$effect"
    printf 'Timeout: %s\n' "$to_disp"
    printf 'Deps: %s\n' "${cmd_deps:-(nenhuma)}"
    printf 'Função: %s\n' "${func_name:-(sem função direta)}"
    printf 'Descrição: %s\n' "$desc"
    return 0
  done < <(step_catalog)

  printf 'Step não encontrado no catálogo: %s\n' "$wanted" >&2
  return 1
}

catalog_info_for_step() {
  local wanted="$1"
  local name category tags effect timeout cmd_deps func_name desc

  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ "$name" == "$wanted" ]] || continue
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$category" "$tags" "$effect" "$timeout" "$cmd_deps" "$func_name" "$desc"
    return 0
  done < <(step_catalog)

  printf 'unknown||||||\n'
}
