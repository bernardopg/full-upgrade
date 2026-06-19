#!/usr/bin/env bash
# steps/doctor.sh — auditorias read-only
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

# Doctors são despachados sem gate de SUDO_READY em main.sh; os que precisam
# de privilégio checam aqui se há credencial SEM prompt. Sem isto, um run
# não-interativo sem sudo cacheado dispararia um prompt de senha que ninguém
# responde e cada step travaria até o timeout (#16).
_doctor_sudo_ok() {
  has sudo && sudo -n true >/dev/null 2>&1
}

doctor_reboot_pending() {
  if ! has pacman || ! pacman -Q linux >/dev/null 2>&1; then
    log "  Pacote linux não encontrado; pulando checagem de reboot do kernel."
    return 0
  fi

  local running installed expected
  running="$(uname -r)"
  installed="$(pacman -Q linux 2>/dev/null | awk '{print $2}' || true)"
  expected="${installed/.arch/-arch}"

  if [[ -z "$installed" || -z "$expected" ]]; then
    log "  Não foi possível determinar versão instalada do kernel."
    return "$RC_WARN"
  fi

  local status=0
  local -a reboot_reasons=()

  if [[ "$running" == "$expected" ]]; then
    log "  Kernel em execução corresponde ao pacote instalado: ${running}."
  else
    log "  Reboot pendente: kernel em execução=${running}; pacote linux instalado=${expected}."
    remediation "systemctl reboot"
    reboot_reasons+=("kernel ${running} → ${expected}")
    status="$RC_TODO"
  fi

  # systemd: versão em uso vs instalado
  if has systemctl; then
    local sd_running sd_installed
    sd_running="$(systemctl --version 2>/dev/null | awk 'NR==1{print $2}' || true)"
    sd_installed="$(pacman -Q systemd 2>/dev/null | awk '{print $2}' | cut -d. -f1 || true)"
    if [[ -n "$sd_running" && -n "$sd_installed" ]]; then
      if [[ "$sd_running" == "$sd_installed" ]]; then
        log "  systemd em execução ok: ${sd_running}."
      else
        log "  systemd em execução=${sd_running}, instalado=${sd_installed} — reboot recomendado."
        remediation "systemctl reboot"
        reboot_reasons+=("systemd ${sd_running} → ${sd_installed}")
        (( status == 0 )) && status="$RC_TODO"
      fi
    fi
  fi

  # microcode: versão aplicada vs pacote instalado
  local ucode_sys ucode_pkg ucode_pkg_name
  ucode_sys="$(cat /sys/devices/system/cpu/cpu0/microcode/version 2>/dev/null | tr -d '[:space:]' || true)"
  if pacman -Q intel-ucode >/dev/null 2>&1; then
    ucode_pkg_name="intel-ucode"
    ucode_pkg="$(pacman -Q intel-ucode 2>/dev/null | awk '{print $2}' || true)"
  elif pacman -Q amd-ucode >/dev/null 2>&1; then
    ucode_pkg_name="amd-ucode"
    ucode_pkg="$(pacman -Q amd-ucode 2>/dev/null | awk '{print $2}' || true)"
  fi
  if [[ -n "$ucode_sys" ]]; then
    if [[ -n "$ucode_pkg_name" ]]; then
      log "  Microcode aplicado: ${ucode_sys} (pacote ${ucode_pkg_name} ${ucode_pkg})."
      log "  Para confirmar se está atual, reinicie após cada update de microcode."
    else
      log "  Microcode aplicado: ${ucode_sys} (pacote não detectado)."
    fi
  fi

  if (( ${#reboot_reasons[@]} > 0 )); then
    STEP_REASON="${reboot_reasons[*]}"
  fi

  return "$status"
}


systemd_user_scope_status() {
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    printf 'available\n'
    return 0
  fi
  if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    printf 'no-runtime\n'
    return 0
  fi
  if [[ -S "${XDG_RUNTIME_DIR}/bus" || -e "${XDG_RUNTIME_DIR}/bus" ]]; then
    printf 'available\n'
    return 0
  fi
  printf 'no-bus\n'
}


doctor_failed_systemd_units() {
  if ! has systemctl; then
    log "  systemctl não encontrado."
    return 0
  fi

  local failed_system failed_user user_scope
  failed_system="$(systemctl --failed --plain --no-legend 2>/dev/null || true)"
  user_scope="$(systemd_user_scope_status)"
  if [[ "$user_scope" == "available" ]]; then
    failed_user="$(systemctl --user --failed --plain --no-legend 2>/dev/null || true)"
  else
    failed_user=""
  fi

  if [[ -z "${failed_system//[[:space:]]/}" && -z "${failed_user//[[:space:]]/}" ]]; then
    if [[ "$user_scope" == "available" ]]; then
      log "  Nenhuma unit systemd falhada (sistema/usuário)."
    else
      log "  Nenhuma unit systemd falhada (sistema)."
      case "$user_scope" in
        no-runtime) log "  Checagem systemd --user pulada (sem XDG_RUNTIME_DIR/sessão de usuário)." ;;
        no-bus) log "  Checagem systemd --user pulada (sem bus de sessão em XDG_RUNTIME_DIR)." ;;
      esac
    fi
    return 0
  fi

  if [[ -n "${failed_system//[[:space:]]/}" ]]; then
    log "  Units systemd falhadas:"
    printf '%s\n' "$failed_system" | tee >(_strip_ansi >> "$LOG_FILE")
  fi
  if [[ -n "${failed_user//[[:space:]]/}" ]]; then
    log "  Units systemd --user falhadas:"
    printf '%s\n' "$failed_user" | tee >(_strip_ansi >> "$LOG_FILE")
  elif [[ "$user_scope" != "available" ]]; then
    case "$user_scope" in
      no-runtime) log "  Checagem systemd --user pulada (sem XDG_RUNTIME_DIR/sessão de usuário)." ;;
      no-bus) log "  Checagem systemd --user pulada (sem bus de sessão em XDG_RUNTIME_DIR)." ;;
    esac
  fi

  return "$RC_TODO"
}


doctor_paru_devel_mode() {
  if ! has paru; then
    log "  paru não instalado; pulando auditoria de Devel."
    return 0
  fi

  local conf
  for conf in /etc/paru.conf "$HOME/.config/paru/paru.conf"; do
    [[ -r "$conf" ]] || continue
    if awk '$1 == "Devel" { found=1 } END { exit found ? 0 : 1 }' "$conf"; then
      log "  paru tem Devel ativo em ${conf}."
      log "  Isso faz pacotes -git/-svn atualizarem mesmo sem passar --devel ao script."
      return "$RC_WARN"
    fi
  done

  log "  paru Devel global não está ativo."
  return 0
}


doctor_journal_errors() {
  if ! has journalctl; then
    log "  journalctl não encontrado."
    return 0
  fi

  local output filtered rc line_count filtered_count grouped unique_count noise_count

  # Padrões de ruído conhecido — grep-E aplicado linha a linha antes de agrupar.
  # São erros priority<=3 (err) que são benignos/não-acionáveis na prática:
  # bugs de firmware (DSDT/ACPI), drivers pedindo report upstream, hardware
  # ausente, ou races transitórios de boot. Mantidos específicos para nunca
  # mascarar uma falha real (ex.: serviço que não subiu, I/O error de disco).
  local -a _journal_noise=(
    'bluetoothd.*HFP.*(gateway|profile|SDP|connect|disconnect)'
    'bluetoothd.*Unable to get.*(Headset|HFP|HandsFree|Hands-Free|Voice gateway)'
    'bluetoothd.*Unable to get Hands-Free'
    'bluetoothd.*Voice gateway SDP'
    'bluetoothd.*connect error'
    'bluetoothd.*Profile.*not registered'
    'bluetoothd.*Connect to.*(HFP|HFP/HF).*failed'
    'bluetoothd.*Getting .* SDP failed'
    'profile\.c.*Unable to get Hands-Free'
    'profile\.c.*Voice gateway SDP'
    'Device is already marked as connected'
    'profiles/audio/avdtp\.c.*connect.*Host is down'
    ':[[:space:]]+#[0-9]+[[:space:]]+0x[0-9a-f]+'
    'ELF object binary architecture:'
    # ── Firmware/ACPI: bugs do DSDT do fabricante, não corrigíveis por SW ──
    'ACPI BIOS Error \(bug\):'
    'ACPI Error: AE_ALREADY_EXISTS'
    'ACPI Error:.*(psobject|dswload|namespace)'
    'Failure creating named object \[\\_SB\.'
    # ── Drivers que pedem report upstream / hardware opcional ausente ──
    'thinkpad_acpi: Unknown/reserved .* mode value'
    'ftdi_sio .*: Unable to read latency timer'
    'Failed to set default system config for hci[0-9]'
    # ── gnome-keyring em sessão gráfica (sem control file / unlock) ──
    'gkr-pam: unable to locate daemon control file'
    'gkr-pam: couldn.t unlock the login keyring'
    # ── Race transitório: pacote (re)instalou .service durante o scan dbus ──
    'Original source was unlinked while parsing service file'
  )

  # Padrões adicionais de ~/.config/full-upgrade/journal-noise.txt (um regex-E por linha)
  local _journal_noise_file="${XDG_CONFIG_HOME:-${HOME}/.config}/full-upgrade/journal-noise.txt"
  if [[ -f "$_journal_noise_file" ]]; then
    local _extra_pat
    while IFS= read -r _extra_pat; do
      [[ -z "${_extra_pat//[[:space:]]/}" || "${_extra_pat:0:1}" == "#" ]] && continue
      _journal_noise+=("$_extra_pat")
    done < "$_journal_noise_file"
  fi

  output="$(journalctl -q -p 3 -b --no-pager -o short-iso 2>&1)"
  rc=$?

  if (( rc != 0 )); then
    log "  Não foi possível ler erros críticos do journal."
    return "$RC_WARN"
  fi

  if [[ -z "${output//[[:space:]]/}" ]]; then
    log "  Nenhum erro crítico no journal do boot atual."
    return 0
  fi

  line_count="$(printf '%s\n' "$output" | wc -l)"

  # Filtrar ruído antes de agrupar.
  # Uma única passada com grep -Evf (todos os padrões de uma vez) em vez de
  # N subshells encadeados — com journals grandes (dezenas de milhares de
  # linhas), o loop antigo reprocessava a string inteira a cada padrão e
  # estourava o timeout do step.
  local _noise_pat_file
  _noise_pat_file="$(mktemp 2>/dev/null || printf '')"
  if [[ -n "$_noise_pat_file" ]]; then
    printf '%s\n' "${_journal_noise[@]}" > "$_noise_pat_file"
    filtered="$(printf '%s\n' "$output" | grep -Evf "$_noise_pat_file" || true)"
    rm -f "$_noise_pat_file"
  else
    # Fallback defensivo se mktemp falhar: aplica padrões em sequência.
    filtered="$output"
    for pat in "${_journal_noise[@]}"; do
      filtered="$(printf '%s\n' "$filtered" | grep -Ev "$pat" || true)"
    done
  fi
  filtered="$(
    printf '%s\n' "$filtered" \
      | sed -E 's/^[0-9T:+.-]+[[:space:]]+[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//' \
      | grep -Ev '^[[:space:]]*$|^[[:space:]]*#[0-9]+[[:space:]]+0x|^[[:space:]]*ELF object binary architecture:|^[[:space:]]*Stack trace of thread ' \
      || true
  )"
  filtered_count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
  noise_count=$(( line_count - filtered_count ))

  if [[ -z "${filtered//[[:space:]]/}" ]]; then
    log "  Journal tem ${line_count} erro(s) crítico(s) — todos ruído conhecido filtrado (${noise_count} linha(s): firmware/ACPI, drivers, keyring, races de boot)."
    return 0
  fi

  grouped="$(
    printf '%s\n' "$filtered" \
      | sort \
      | uniq -c \
      | sort -nr \
      | head -n 20
  )"
  unique_count="$(printf '%s\n' "$grouped" | grep -c '[^[:space:]]' || true)"

  local noise_note=""
  (( noise_count > 0 )) && noise_note=", ${noise_count} de ruído filtrado"
  log "  Journal: ${filtered_count} erro(s) crítico(s) reais neste boot (${unique_count} assinatura(s)${noise_note}):"
  printf '%s\n' "$grouped" | tee >(_strip_ansi >> "$LOG_FILE")
  log "  Últimas 80 linhas brutas (pós-filtro) gravadas no log para auditoria."
  {
    printf '\n--- journalctl -p 3 -b últimas 80 linhas filtradas ---\n'
    printf '%s\n' "$filtered" | tail -n 80
  } >> "$LOG_FILE"
  STEP_REASON="${filtered_count} erro(s) crítico(s) reais (${unique_count} assinatura(s))"
  return "$RC_WARN"
}


doctor_fwupd_security() {
  if ! has fwupdmgr; then
    log "  fwupdmgr não instalado."
    return 0
  fi

  local output rc
  output="$(fwupdmgr security 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc != 0 )); then
    log "  fwupdmgr security retornou código ${rc}:"
    printf '%s\n' "$output" | grep -v '^$' || true
    return "$RC_WARN"
  fi

  printf '%s\n' "$output" | grep -v '^$' || true

  # O nível HSI agregado (0–4) é o sinal de verdade. O sufixo "!" indica apenas
  # que há medições de runtime presentes (HSI-Runtime), não insegurança. E os
  # marcadores "✘" em sub-itens são esperados mesmo em níveis altos (atributos
  # não suportados/não aplicáveis no hardware), então NÃO devem disparar aviso
  # por si só. Critério: avisar somente quando o nível agregado é baixo (< 2).
  local hsi_level
  hsi_level="$(printf '%s\n' "$output" | grep -oiE 'HSI:[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"

  if [[ -n "$hsi_level" ]]; then
    if (( hsi_level < 2 )); then
      STEP_REASON="nível HSI baixo (HSI:${hsi_level} de 4)"
      log "  fwupd security: nível HSI:${hsi_level} abaixo do recomendado (>= 2)."
      return "$RC_WARN"
    fi
    log "  fwupd security: HSI:${hsi_level} de 4 (aceitável). Marcadores ✘ em sub-itens são normais."
    return 0
  fi

  # Sem nível HSI legível (formato inesperado): cair para heurística de falha.
  if printf '%s\n' "$output" | grep -q '✘'; then
    STEP_REASON="fwupd security reportou falha(s) sem nível HSI legível"
    return "$RC_WARN"
  fi
  return 0
}


doctor_flatpak_repair_dry_run() {
  if ! has flatpak; then
    log "  flatpak não instalado."
    return 0
  fi

  local output rc
  output="$(flatpak repair --user --dry-run 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc != 0 )); then
    log "  flatpak repair --user --dry-run retornou código ${rc}:"
    printf '%s\n' "$output" | grep -v '^$' || true
    return "$RC_WARN"
  fi

  if [[ -z "${output//[[:space:]]/}" ]]; then
    log "  Flatpak repair dry-run: nenhuma inconsistência reportada."
  else
    printf '%s\n' "$output" | grep -v '^$' || true
  fi
  return 0
}


doctor_disk_health() {
  if ! has df; then
    log "  df não encontrado."
    return 0
  fi

  local -a paths=()
  local -A seen_mounts=()
  local path mount_for_path
  for path in / /home /boot /boot/efi /efi; do
    [[ -d "$path" ]] || continue
    mount_for_path="$(df -P -- "$path" 2>/dev/null | awk 'NR==2 {print $6}' || true)"
    [[ -n "$mount_for_path" ]] || continue
    if [[ -z "${seen_mounts[$mount_for_path]+x}" ]]; then
      seen_mounts[$mount_for_path]=1
      paths+=("$mount_for_path")
    fi
  done

  if (( ${#paths[@]} == 0 )); then
    log "  Nenhum mount essencial encontrado para checar."
    return 0
  fi

  local status=0
  local line mount used_pct inode_pct
  log "  Uso de espaço:"
  df -Ph -- "${paths[@]}" | tee >(_strip_ansi >> "$LOG_FILE")
  log "  Uso de inodes:"
  df -Pih -- "${paths[@]}" | tee >(_strip_ansi >> "$LOG_FILE")

  while IFS= read -r line; do
    mount="$(awk '{print $6}' <<<"$line")"
    used_pct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$line")"
    [[ "$used_pct" =~ ^[0-9]+$ ]] || continue
    if (( used_pct >= 95 )); then
      log "  Ação necessária: ${mount} está com ${used_pct}% de uso."
      status=$RC_TODO
    elif (( used_pct >= 90 && status != RC_TODO )); then
      log "  Aviso: ${mount} está com ${used_pct}% de uso."
      status=$RC_WARN
    fi
  done < <(df -P -- "${paths[@]}" | tail -n +2)

  while IFS= read -r line; do
    mount="$(awk '{print $6}' <<<"$line")"
    inode_pct="$(awk '{gsub(/%/,"",$5); print $5}' <<<"$line")"
    [[ "$inode_pct" =~ ^[0-9]+$ ]] || continue
    if (( inode_pct >= 95 )); then
      log "  Ação necessária: ${mount} está com ${inode_pct}% de inodes usados."
      status=$RC_TODO
    elif (( inode_pct >= 90 && status != RC_TODO )); then
      log "  Aviso: ${mount} está com ${inode_pct}% de inodes usados."
      status=$RC_WARN
    fi
  done < <(df -Pi -- "${paths[@]}" | tail -n +2)

  if (( status == 0 )); then
    log "  Espaço e inodes em níveis aceitáveis nos mounts checados."
  fi
  return "$status"
}


doctor_boot_health() {
  if ! has bootctl; then
    log "  bootctl não encontrado; pulando."
    return 0
  fi

  if ! _doctor_sudo_ok; then
    log "  Checagem de boot requer sudo sem prompt; pulando (valide o sudo para auditar o ESP)."
    return 0
  fi

  if ! sudo -n bootctl is-installed >/dev/null 2>&1; then
    log "  systemd-boot não instalado no ESP; pulando."
    return 0
  fi

  local output rc status=0

  # bootctl status — extrair entrada padrão e estado
  output="$(sudo -n bootctl status 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    log "  bootctl status retornou código ${rc}."
    return "$RC_WARN"
  fi

  # Entrada padrão e kernel/initrd
  local default_entry linux_path initrd_path
  default_entry="$(printf '%s\n' "$output" | awk '/Default Boot Loader Entry:/{found=1} found && /^\s+title:/{print $2" "$3" "$4; exit}')"
  linux_path="$(printf '%s\n' "$output" | awk '/^\s+linux:/{print $2; exit}')"
  initrd_path="$(printf '%s\n' "$output" | awk '/^\s+initrd:/{print $2; exit}')"

  log "  systemd-boot instalado. Entrada padrão: ${default_entry:-desconhecida}"

  # Verificar presença dos arquivos kernel e initrd no ESP
  local missing_files=()
  if [[ -n "$linux_path" ]]; then
    if ! sudo -n test -f "$linux_path" 2>/dev/null; then
      missing_files+=("kernel: ${linux_path}")
    else
      log "  kernel OK: ${linux_path}"
    fi
  fi
  if [[ -n "$initrd_path" ]]; then
    if ! sudo -n test -f "$initrd_path" 2>/dev/null; then
      missing_files+=("initrd: ${initrd_path}")
    else
      log "  initrd OK: ${initrd_path}"
    fi
  fi

  if (( ${#missing_files[@]} > 0 )); then
    log "  AVISO: arquivo(s) de boot ausente(s) no ESP:"
    for f in "${missing_files[@]}"; do
      log "    ${f}"
    done
    status="$RC_TODO"
  fi

  # Fallback initramfs
  local fallback_path
  fallback_path="$(printf '%s\n' "$output" | awk '/^\s+initrd:/{p=1; next} p && /^\s+initrd:/{print $2; exit} p && /^\s+linux:/{exit}' | head -1)"
  if [[ -z "$fallback_path" ]]; then
    # heurística: substituir initramfs-linux.img → initramfs-linux-fallback.img
    if [[ -n "$initrd_path" ]]; then
      fallback_path="${initrd_path/initramfs-linux.img/initramfs-linux-fallback.img}"
      [[ "$fallback_path" == "$initrd_path" ]] && fallback_path=""
    fi
  fi
  if [[ -n "$fallback_path" ]]; then
    if sudo -n test -f "$fallback_path" 2>/dev/null; then
      log "  fallback initramfs OK: ${fallback_path}"
    else
      log "  AVISO: fallback initramfs ausente: ${fallback_path}"
      log "  Regenere com: mkinitcpio -P"
      (( status == 0 )) && status="$RC_TODO"
    fi
  fi

  # Espaço livre no ESP
  local esp_mount esp_avail_pct esp_avail
  esp_mount="$(findmnt -n -o TARGET /boot 2>/dev/null || true)"
  if [[ -z "$esp_mount" ]]; then
    esp_mount="$(findmnt -n -o TARGET --target /boot/efi 2>/dev/null || true)"
  fi
  if [[ -n "$esp_mount" ]]; then
    esp_avail="$(df -h "$esp_mount" 2>/dev/null | awk 'NR==2{print $4}')"
    esp_avail_pct="$(df "$esp_mount" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print 100-$5}')"
    log "  ESP (${esp_mount}): ${esp_avail} livre (${esp_avail_pct}% disponível)"
    if [[ -n "$esp_avail_pct" ]] && (( esp_avail_pct < 20 )); then
      log "  AVISO: ESP com menos de 20% livre — risco de falha na atualização do boot loader."
      status="$RC_WARN"
    fi
  fi

  return "$status"
}


doctor_network_health() {
  local status=0

  # DNS resolution
  local dns_result dns_host="archlinux.org"
  if has dig; then
    dns_result="$(dig +short +time=3 +tries=1 "$dns_host" 2>/dev/null | head -1)"
  elif has nslookup; then
    dns_result="$(nslookup "$dns_host" 2>/dev/null | awk '/^Address: /{print $2; exit}')"
  elif has host; then
    dns_result="$(host -W 3 "$dns_host" 2>/dev/null | awk '/has address/{print $4; exit}')"
  fi

  if [[ -z "$dns_result" ]]; then
    log "  DNS: falha ao resolver ${dns_host} — sem conectividade ou DNS quebrado."
    return "$RC_WARN"
  fi
  log "  DNS OK: ${dns_host} → ${dns_result}"

  # HTTPS básico — archlinux.org e chaotic-aur se configurado
  local -a check_urls=("https://archlinux.org" "https://aur.archlinux.org")
  local url http_code failed_urls=()

  if ! has curl; then
    log "  curl não encontrado; pulando verificação HTTPS."
    return "$status"
  fi

  for url in "${check_urls[@]}"; do
    http_code="$(curl -sS --max-time 6 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || true)"
    if [[ "$http_code" =~ ^[23] ]]; then
      log "  HTTPS OK: ${url} (${http_code})"
    else
      log "  HTTPS FALHOU: ${url} (código ${http_code:-timeout})"
      failed_urls+=("$url")
      status="$RC_WARN"
    fi
  done

  if (( ${#failed_urls[@]} > 0 )); then
    log "  ${#failed_urls[@]} URL(s) inacessível(is); updates de rede podem falhar."
  fi

  return "$status"
}


doctor_stale_services() {
  # Detectar serviços usando bibliotecas antigas (após update sem reboot/restart)
  local status=0

  if ! _doctor_sudo_ok; then
    log "  needrestart/checkservices requerem sudo sem prompt; checagem pulada."
    return 0
  fi

  if has needrestart; then
    local output rc
    # -r l = listar apenas, sem reiniciar; -b = batch mode (não interativo)
    output="$(sudo -n needrestart -r l -b 2>&1)"
    rc=$?
    if (( rc != 0 )) && [[ -z "${output//[[:space:]]/}" ]]; then
      log "  needrestart retornou código ${rc}."
      return "$RC_WARN"
    fi
    local svc_count
    svc_count="$(printf '%s\n' "$output" | grep -c 'NEEDRESTART-SVC' || true)"
    local kstat
    kstat="$(printf '%s\n' "$output" | awk -F'=' '/NEEDRESTART-KSTA/{print $2; exit}')"
    if (( svc_count > 0 )); then
      log "  needrestart: ${svc_count} serviço(s) usando bibliotecas antigas:"
      printf '%s\n' "$output" | grep 'NEEDRESTART-SVC' | awk -F'=' '{print "    " $2}' | tee >(_strip_ansi >> "$LOG_FILE")
      status="$RC_TODO"
      STEP_REASON="${svc_count} serviço(s) com bibliotecas antigas (needrestart)"
    else
      log "  needrestart: nenhum serviço usando bibliotecas antigas."
    fi
    if [[ "$kstat" == "3" ]]; then
      log "  needrestart: kernel em execução está desatualizado (confirma reboot pendente)."
      (( status == 0 )) && status="$RC_TODO"
    fi
    return "$status"
  fi

  if has checkservices; then
    local output rc problems
    output="$(sudo -n checkservices 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      log "  checkservices retornou código ${rc}."
      return "$RC_WARN"
    fi
    # A saída do checkservices mistura sinal e ruído:
    #   ==> pacnew file found for /etc/...   (não é serviço)
    #   Found: 10                            (contador, não item)
    #   -------8<--------                    (delimitadores do bloco de comandos)
    #   systemctl restart 'foo.service'      (o sinal real)
    # O parser antigo (grep -v '^Found: 0') deixava passar "Found: 10", os
    # delimitadores "8<" e a linha "pacnew file found", inflando a contagem
    # (ex.: 14 itens reportados para 10 serviços reais). Extraímos apenas as
    # linhas de comando 'systemctl restart' — o conjunto canônico de serviços
    # que o checkservices recomenda reiniciar.
    local -a _affected_services=()
    mapfile -t _affected_services < <(printf '%s\n' "$output" | parse_checkservices_units)
    # Fallback: builds antigos do checkservices podem listar nomes de serviço
    # sem o comando 'systemctl restart'. Se nada casou acima, recai para o
    # filtro genérico (ainda excluindo contadores/delimitadores/pacnew).
    if (( ${#_affected_services[@]} == 0 )); then
      mapfile -t _affected_services < <(
        printf '%s\n' "$output" \
          | grep -vE '^::|^Found:|^[[:space:]]*-+8<-+|pacnew file found|^[[:space:]]*$|^Execute' \
          | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
          | grep -E '\.(service|socket|timer|mount|target|scope|path)$|\.service' \
          | sort -u
      )
    fi
    if (( ${#_affected_services[@]} == 0 )); then
      log "  checkservices: nenhum serviço com bibliotecas antigas."
      return 0
    fi
    problems="$(printf '%s\n' "${_affected_services[@]}")"
    local svc_count="${#_affected_services[@]}"
    log "  checkservices: ${svc_count} serviço(s) usando bibliotecas substituídas (reinício recomendado):"
    printf '%s\n' "${_affected_services[@]}" | tee >(_strip_ansi >> "$LOG_FILE")
    STEP_REASON="${svc_count} serviço(s) com libs antigas (reinício pendente)"

    if (( RESTART_SERVICES )); then
      # Reusa a lista já parseada; restringe a units systemd válidas para não
      # tentar reiniciar nomes soltos vindos do fallback genérico.
      local -a restart_cmds=()
      local _svc
      for _svc in "${_affected_services[@]}"; do
        [[ "$_svc" =~ \.(service|socket|timer|mount|target|scope|path)$ ]] && restart_cmds+=("$_svc")
      done
      if (( ${#restart_cmds[@]} == 0 )); then
        log "  --restart-services: nenhuma unit systemd reiniciável detectada na saída."
        return "$RC_TODO"
      fi
      log "  --restart-services: ${#restart_cmds[@]} serviço(s) a reiniciar: ${restart_cmds[*]}"
      if (( ASSUME_YES == 0 )); then
        if [[ -t 0 ]]; then
          printf '%b' "${C_YELLOW}  Reiniciar esses serviços agora? [s/N] ${C_RESET}"
          local answer
          read -r answer
          case "$answer" in
            [sS][iI][mM]|[sS]) ;;
            *) log "  Reinício de serviços cancelado pelo usuário."; return "$RC_TODO" ;;
          esac
        else
          log "  Execução não interativa sem --yes; pulando reinício de serviços."
          return "$RC_TODO"
        fi
      fi
      local svc all_ok=1
      for svc in "${restart_cmds[@]}"; do
        log "  Reiniciando ${svc}..."
        if run_logged sudo -n systemctl restart "$svc"; then
          log "  ${svc}: reiniciado."
        else
          log "  Aviso: falha ao reiniciar ${svc}."
          all_ok=0
        fi
      done
      (( all_ok )) && return 0
      return "$RC_WARN"
    fi

    return "$RC_TODO"
  fi

  log "  needrestart e checkservices não encontrados; instale um para monitorar serviços com libs antigas."
  return 0
}


doctor_pacman_health() {
  if ! has pacman; then
    log "  pacman não encontrado."
    return 0
  fi

  local output rc count filtered noise_count check_cmd_label
  local -a check_cmd=(pacman -Qkq)

  if has sudo && sudo -n true >/dev/null 2>&1; then
    check_cmd=(sudo pacman -Qkq)
    check_cmd_label="sudo pacman -Qkq"
  else
    check_cmd_label="pacman -Qkq"
  fi

  # Padrões de falsos positivos conhecidos:
  #   hicolor-icon-theme declara dirs 256x256@2 que apps instalam conforme necessário
  #   intel-ucode /boot/intel-ucode.img é embutido no initramfs pelo mkinitcpio
  local -a _pacman_health_noise=(
    '^hicolor-icon-theme /usr/share/icons/hicolor/256x256@2/'
    '^intel-ucode /boot/intel-ucode.img$'
    # Bytecode em __pycache__ é regenerado pelo interpretador (recompila a cada
    # bump de Python ou import); mtime/size divergem do empacotado mas o arquivo
    # é reconstruído sob demanda — não indica pacote quebrado. Filtra só .pyc/.pyo
    # dentro de __pycache__/. Arquivos .py, .orig e .pacnew seguem reportados.
    '/__pycache__/[^ ]*\.py[co]$'
  )

  output="$("${check_cmd[@]}" 2>&1)"
  rc=$?

  if (( rc != 0 )) && [[ -z "${output//[[:space:]]/}" ]]; then
    log "  ${check_cmd_label} retornou código ${rc} sem saída:"
    return "$RC_WARN"
  fi

  if [[ -z "${output//[[:space:]]/}" ]]; then
    log "  ${check_cmd_label}: nenhum pacote com arquivo faltando."
    return 0
  fi

  if [[ "$check_cmd_label" == "pacman -Qkq" ]] && grep -Eqi 'permission denied|permiss[aã]o negada' <<<"$output"; then
    log "  pacman -Qkq encontrou caminhos sem permissão; rode com sudo para uma auditoria conclusiva."
    printf '%s\n' "$output" | grep -Ei 'permission denied|permiss[aã]o negada' | tee >(_strip_ansi >> "$LOG_FILE") | head -n 20
    return "$RC_WARN"
  fi

  # Filtrar falsos positivos
  filtered="$output"
  for pat in "${_pacman_health_noise[@]}"; do
    filtered="$(printf '%s\n' "$filtered" | grep -Ev "$pat" || true)"
  done
  noise_count=$(( $(printf '%s\n' "$output" | wc -l) - $(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true) ))

  if [[ -z "${filtered//[[:space:]]/}" ]]; then
    log "  ${check_cmd_label}: apenas falsos positivos conhecidos (${noise_count} ignorados)."
    return 0
  fi

  count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
  local noise_note=""
  (( noise_count > 0 )) && noise_note=" (+ ${noise_count} falso(s) positivo(s) filtrado(s))"
  log "  ${check_cmd_label}: ${count} arquivo(s)/pacote(s) com problema${noise_note} (mostrando até 60):"
  printf '%s\n' "$filtered" | grep '[^[:space:]]' | tee >(_strip_ansi >> "$LOG_FILE") | head -n 60
  if (( count > 60 )); then
    log "  Saída completa registrada no log."
  fi
  return "$RC_TODO"
}


doctor_pacman_hooks() {
  if ! has journalctl; then
    log "  journalctl não encontrado; não é possível auditar hooks ALPM."
    return 0
  fi

  local boot_id
  boot_id="$(journalctl --list-boots --no-pager 2>/dev/null | awk 'NR==1{print $2}' || true)"
  [[ -z "$boot_id" ]] && boot_id="-b"

  local failed_hooks
  failed_hooks="$(journalctl -b "${boot_id}" -p err -g 'ALPM-scriptlet|alpm-hook' --no-pager --output=short-monotonic 2>/dev/null | grep -v '^$' || true)"

  if [[ -z "${failed_hooks//[[:space:]]/}" ]]; then
    log "  Nenhum hook ALPM com falha registrado no boot atual."
    return 0
  fi

  local count
  count="$(printf '%s\n' "$failed_hooks" | grep -c '[^[:space:]]' || true)"
  log "  ${count} mensagem(ns) de erro em hooks ALPM no boot atual (mostrando até 20):"
  printf '%s\n' "$failed_hooks" | head -n 20 | tee >(_strip_ansi >> "$LOG_FILE")
  (( count > 20 )) && log "  Saída completa registrada no log."
  return "$RC_TODO"
}


doctor_smart_health() {
  local status=0 found=0

  if ! _doctor_sudo_ok; then
    log "  smartctl/nvme requerem sudo sem prompt; checagem SMART pulada."
    return 0
  fi

  if has smartctl; then
    found=1
    local drives
    drives="$(smartctl --scan 2>/dev/null | awk '{print $1}' || true)"
    if [[ -z "${drives//[[:space:]]/}" ]]; then
      log "  smartctl --scan: nenhum disco encontrado."
    else
      local drive health
      while IFS= read -r drive; do
        [[ -z "$drive" ]] && continue
        health="$(sudo -n smartctl -H "$drive" 2>/dev/null | awk '/overall-health|SMART overall/{print $NF}' | head -1 || true)"
        local reallocated uncorrectable
        reallocated="$(sudo -n smartctl -A "$drive" 2>/dev/null | awk '/Reallocated_Sector_Ct/{print $10}' | head -1 || true)"
        uncorrectable="$(sudo -n smartctl -A "$drive" 2>/dev/null | awk '/Offline_Uncorrectable/{print $10}' | head -1 || true)"
        if [[ "$health" == "PASSED" || "$health" == "OK" ]]; then
          log "  ${drive}: saúde SMART OK (${health})"
        elif [[ -n "$health" ]]; then
          log "  ${drive}: saúde SMART ${health} — verificar imediatamente."
          status="$RC_TODO"
        fi
        if [[ -n "$reallocated" && "$reallocated" -gt 0 ]] 2>/dev/null; then
          log "  ${drive}: setores realocados = ${reallocated} — disco com defeitos físicos."
          (( status == 0 )) && status="$RC_WARN"
        fi
        if [[ -n "$uncorrectable" && "$uncorrectable" -gt 0 ]] 2>/dev/null; then
          log "  ${drive}: erros não corrigíveis = ${uncorrectable} — risco de perda de dados."
          (( status == 0 )) && status="$RC_WARN"
        fi
      done <<< "$drives"
    fi
  fi

  if has nvme; then
    found=1
    local nvme_devs
    nvme_devs="$(nvme list 2>/dev/null | awk 'NR>2 && /^\/dev/{print $1}' || true)"
    if [[ -n "${nvme_devs//[[:space:]]/}" ]]; then
      local dev nvme_out crit_warn
      while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        nvme_out="$(sudo -n nvme smart-log "$dev" 2>/dev/null || true)"
        crit_warn="$(printf '%s\n' "$nvme_out" | awk -F: '/critical_warning/{gsub(/[[:space:]]/,"",$2); print $2}' | head -1 || true)"
        local avail_spare
        avail_spare="$(printf '%s\n' "$nvme_out" | awk -F: '/avail_spare[^_]/{gsub(/[[:space:]%]/,"",$2); print $2}' | head -1 || true)"
        if [[ -n "$crit_warn" && "$crit_warn" != "0x0" && "$crit_warn" != "0" ]]; then
          log "  ${dev}: NVMe critical_warning=${crit_warn} — verificar."
          (( status == 0 )) && status="$RC_WARN"
        else
          log "  ${dev}: NVMe sem avisos críticos${avail_spare:+ (spare=${avail_spare}%)}"
        fi
      done <<< "$nvme_devs"
    fi
  fi

  if (( found == 0 )); then
    log "  smartctl e nvme não encontrados; instale smartmontools ou nvme-cli para monitorar discos."
  fi

  return "$status"
}


doctor_desktop_health() {
  local status=0

  # xdg-desktop-portal: o executável fica em /usr/lib (NÃO no PATH), então
  # `has`/`command -v` davam falso-negativo. Além disso o nome do processo é
  # truncado em 15 chars (comm="xdg-desktop-por"), então `pgrep -x` com o nome
  # completo não casava. Detecta por arquivo/pacote e checa execução por -f.
  local _xdp_installed=0 _xdp_running=0
  if [[ -x /usr/lib/xdg-desktop-portal ]] \
     || has xdg-desktop-portal \
     || pacman -Qq xdg-desktop-portal >/dev/null 2>&1; then
    _xdp_installed=1
  fi
  if pgrep -f '/usr/lib/xdg-desktop-portal( |$)' >/dev/null 2>&1 \
     || pgrep -x 'xdg-desktop-por' >/dev/null 2>&1; then
    _xdp_running=1
  fi
  if (( _xdp_installed )); then
    if (( _xdp_running )); then
      log "  xdg-desktop-portal: em execução."
    else
      log "  xdg-desktop-portal: instalado, mas não está em execução."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  xdg-desktop-portal: não instalado."
    # Sugestão de backend conforme o compositor/sessão em uso.
    local _portal_pkg="xdg-desktop-portal"
    if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || pgrep -x Hyprland >/dev/null 2>&1 || has hyprctl; then
      _portal_pkg="xdg-desktop-portal-hyprland xdg-desktop-portal"
    elif [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
      _portal_pkg="xdg-desktop-portal-gnome xdg-desktop-portal"
    elif [[ "${XDG_CURRENT_DESKTOP:-}" == *KDE* ]]; then
      _portal_pkg="xdg-desktop-portal-kde xdg-desktop-portal"
    elif [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
      _portal_pkg="xdg-desktop-portal-wlr xdg-desktop-portal"
    fi
    log "    Sugestão: instale com 'sudo pacman -S --needed ${_portal_pkg}' (necessário p/ screencast, file pickers e flatpaks)."
  fi

  # PipeWire
  if has pipewire || pgrep -x pipewire >/dev/null 2>&1; then
    if pgrep -x pipewire >/dev/null 2>&1; then
      log "  PipeWire: em execução."
    else
      log "  PipeWire: não está em execução."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  PipeWire: não encontrado."
  fi

  # WirePlumber
  if has wireplumber || pgrep -x wireplumber >/dev/null 2>&1; then
    if pgrep -x wireplumber >/dev/null 2>&1; then
      log "  WirePlumber: em execução."
    else
      log "  WirePlumber: não está em execução."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  WirePlumber: não encontrado."
  fi

  # GPU básico — apenas informativo
  if has vulkaninfo; then
    local vk_dev
    vk_dev="$(vulkaninfo --summary 2>/dev/null | awk '/deviceName/{print $3; exit}' || true)"
    [[ -n "$vk_dev" ]] && log "  GPU Vulkan: ${vk_dev}"
  elif has glxinfo; then
    local gl_renderer
    gl_renderer="$(glxinfo -B 2>/dev/null | awk '/OpenGL renderer/{print substr($0, index($0,$4)); exit}' || true)"
    [[ -n "$gl_renderer" ]] && log "  GPU OpenGL: ${gl_renderer}"
  fi

  return "$status"
}


doctor_ai_clis() {
  local status=0

  # claude
  if has claude; then
    local cv
    cv="$(claude --version 2>/dev/null | head -1 || true)"
    if [[ -n "$cv" ]]; then
      log "  claude: ${cv}"
    else
      log "  claude: encontrado mas --version falhou."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  claude: não instalado."
  fi

  # GitHub Copilot CLI
  local copilot_bin="${HOME}/.local/bin/copilot"
  if [[ -x "$copilot_bin" ]]; then
    local cpv
    cpv="$("$copilot_bin" --version 2>/dev/null | head -1 || true)"
    if [[ -n "$cpv" ]]; then
      log "  copilot: ${cpv}"
    else
      log "  copilot: encontrado mas --version falhou."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  copilot: não instalado."
  fi

  # Hermes
  if has hermes; then
    local hv
    hv="$(hermes --version 2>/dev/null | head -1 || true)"
    if [[ -n "$hv" ]]; then
      log "  hermes: ${hv}"
    else
      log "  hermes: encontrado mas --version falhou."
      (( status == 0 )) && status="$RC_WARN"
    fi
  else
    log "  hermes: não instalado."
  fi

  return "$status"
}


doctor_js_conflicts() {
  local status=0

  # Prefixo npm
  if has npm; then
    local prefix
    prefix="$(npm_global_prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
      case "$prefix" in
        /|/usr|/usr/local)
          log "  npm: prefixo global em ${prefix} — risco de conflito com pacotes do sistema (pacman)."
          log "  Configure: npm config set prefix ~/.local"
          (( status == 0 )) && status="$RC_WARN"
          ;;
        "$HOME"*|/home/*)
          log "  npm: prefixo global ok (${prefix})."
          ;;
        *)
          log "  npm: prefixo global incomum (${prefix}) — verifique se é intencional."
          (( status == 0 )) && status="$RC_WARN"
          ;;
      esac
    fi
  fi

  # Conflitos npm global × pnpm global
  if has npm && has pnpm; then
    local npm_json pnpm_json conflicts
    npm_json="$(npm list -g --depth=0 --json 2>/dev/null || true)"
    pnpm_json="$(pnpm list -g --json 2>/dev/null || true)"

    if [[ -n "${npm_json//[[:space:]]/}" && -n "${pnpm_json//[[:space:]]/}" ]]; then
      local _npm_tmp _pnpm_tmp
      _npm_tmp="$(mktemp)"
      _pnpm_tmp="$(mktemp)"
      printf '%s\n' "$npm_json"  > "$_npm_tmp"
      printf '%s\n' "$pnpm_json" > "$_pnpm_tmp"
      conflicts="$(python3 - "$_npm_tmp" "$_pnpm_tmp" 2>/dev/null <<'PYEOF' || true
import json, sys

def load_file(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

npm_data  = load_file(sys.argv[1])
pnpm_data = load_file(sys.argv[2])

npm_pkgs  = set(npm_data.get("dependencies", {}).keys())
pnpm_deps = pnpm_data if isinstance(pnpm_data, list) else [pnpm_data]
pnpm_pkgs = set()
for entry in pnpm_deps:
    pnpm_pkgs.update(entry.get("dependencies", {}).keys())

for pkg in sorted(npm_pkgs & pnpm_pkgs):
    print(pkg)
PYEOF
)"
      rm -f "$_npm_tmp" "$_pnpm_tmp"

      if [[ -n "${conflicts//[[:space:]]/}" ]]; then
        local cc
        cc="$(printf '%s\n' "$conflicts" | wc -l)"
        log "  Conflito npm/pnpm global: ${cc} pacote(s) instalado(s) em ambos:"
        printf '%s\n' "$conflicts" | tee >(_strip_ansi >> "$LOG_FILE")
        log "  Remova de um dos gestores para evitar versões divergentes."
        (( status == 0 )) && status="$RC_WARN"
      else
        log "  npm/pnpm global: sem pacotes duplicados."
      fi
    fi
  fi

  # Corepack ativo + pnpm gerenciado externamente = possível conflito
  if has corepack && has pnpm; then
    local cp_pnpm pnpm_bin
    pnpm_bin="$(command -v pnpm 2>/dev/null || true)"
    cp_pnpm="$(corepack list 2>/dev/null | grep -i '^pnpm' || true)"
    if [[ -n "$cp_pnpm" && -n "$pnpm_bin" ]]; then
      log "  Corepack gerencia pnpm (${cp_pnpm}) e pnpm externo em ${pnpm_bin} — verifique qual está ativo."
      (( status == 0 )) && status="$RC_WARN"
    fi
  fi

  if (( status == 0 )); then
    log "  JavaScript global: sem conflitos detectados."
  fi

  return "$status"
}


doctor_python_env() {
  local status=0

  if has python && python -m pip --version >/dev/null 2>&1; then
    local pip_check_out pip_check_rc
    pip_check_out="$(python -m pip check 2>&1)"
    pip_check_rc=$?
    log_raw "$pip_check_out"
    if (( pip_check_rc == 0 )); then
      log "  pip check: sem dependências Python quebradas."
    else
      log "  pip check encontrou dependências Python quebradas:"
      printf '%s\n' "$pip_check_out" | grep -v '^$' | tee >(_strip_ansi >> "$LOG_FILE")
      (( status == 0 )) && status="$RC_WARN"
    fi
  fi

  # pipx: venvs quebradas
  if has pipx; then
    local pipx_json broken_count
    pipx_json="$(pipx list --json 2>/dev/null || true)"
    if [[ -n "${pipx_json//[[:space:]]/}" ]]; then
      # venv quebrada = python interpreter não existe no venv
      broken_count="$(printf '%s\n' "$pipx_json" | python3 -c '
import json, sys, os
data = json.load(sys.stdin)
broken = []
for pkg, info in data.get("venvs", {}).items():
    py = info.get("metadata", {}).get("python_path", "")
    if py and not os.path.isfile(py):
        broken.append(f"{pkg}: {py}")
for b in broken:
    print(b)
' 2>/dev/null || true)"
      if [[ -n "${broken_count//[[:space:]]/}" ]]; then
        local bc
        bc="$(printf '%s\n' "$broken_count" | wc -l)"
        log "  pipx: ${bc} venv(s) quebrada(s) — interpreter ausente:"
        printf '%s\n' "$broken_count" | tee >(_strip_ansi >> "$LOG_FILE")
        log "  Repare com: pipx reinstall-all"
        (( status == 0 )) && status="$RC_TODO"
      else
        log "  pipx: todas as venvs com interpreter válido."
      fi
    fi
  fi

  # uv tools: ferramentas com interpreter ausente
  if has uv; then
    local uv_json broken_uv
    uv_json="$(uv tool list --format=json 2>/dev/null || true)"
    if [[ -n "${uv_json//[[:space:]]/}" ]]; then
      broken_uv="$(printf '%s\n' "$uv_json" | python3 -c '
import json, sys, os
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for tool in (data if isinstance(data, list) else []):
    py = tool.get("python", "") or tool.get("python_path", "")
    name = tool.get("name", "?")
    if py and not os.path.isfile(py):
        print(f"{name}: {py}")
' 2>/dev/null || true)"
      if [[ -n "${broken_uv//[[:space:]]/}" ]]; then
        local buc
        buc="$(printf '%s\n' "$broken_uv" | wc -l)"
        log "  uv tools: ${buc} ferramenta(s) com interpreter ausente:"
        printf '%s\n' "$broken_uv" | tee >(_strip_ansi >> "$LOG_FILE")
        log "  Repare com: uv tool install --reinstall <nome>"
        (( status == 0 )) && status="$RC_TODO"
      else
        log "  uv tools: interpreters OK."
      fi
    fi
  fi

  if ! has pipx && ! has uv; then
    log "  pipx e uv não instalados; nada a auditar."
  fi


  return "$status"
}


# F3 — saúde do btrfs: erros de I/O acumulados por device + idade do último
# scrub. Em raiz não-btrfs, pula limpo. RC_TODO se scrub vencido (>
# BTRFS_SCRUB_MAX_DAYS) ou se houver erros de device > 0.
doctor_btrfs_health() {
  if ! has btrfs; then
    log "  btrfs-progs não instalado; pulando."
    return 0
  fi

  local rootfs
  rootfs="$(findmnt -no FSTYPE / 2>/dev/null || true)"
  if [[ "$rootfs" != "btrfs" ]]; then
    log "  Raiz não é btrfs (${rootfs:-?}); nada a verificar."
    return 0
  fi

  if ! _doctor_sudo_ok; then
    log "  btrfs device stats/scrub requerem sudo sem prompt; checagem pulada."
    return 0
  fi

  local status=0

  # 1) Erros de device acumulados (write/read/flush/corruption/generation).
  local stats errs
  stats="$(sudo -n btrfs device stats / 2>/dev/null || true)"
  if [[ -n "${stats//[[:space:]]/}" ]]; then
    errs="$(printf '%s\n' "$stats" | sum_btrfs_dev_errors)"
    if [[ "$errs" =~ ^[0-9]+$ ]] && (( errs > 0 )); then
      log "  ${C_YELLOW}btrfs: ${errs} erro(s) de device acumulado(s) em / — possível defeito físico.${C_RESET}"
      printf '%s\n' "$stats" | grep -E '_errs' | grep -vE '_errs[[:space:]]+0$' | tee >(_strip_ansi >> "$LOG_FILE")
      log "  Remediação: investigue o disco (smartctl) e zere após resolver: sudo btrfs device stats -z /"
      status="$RC_TODO"
    else
      log "  btrfs: sem erros de device em / (contadores zerados)."
    fi
  fi

  # 2) Idade do último scrub.
  local scrub max_days last_epoch now_epoch age_days
  max_days="${BTRFS_SCRUB_MAX_DAYS:-30}"
  scrub="$(sudo -n btrfs scrub status / 2>/dev/null || true)"
  if printf '%s\n' "$scrub" | grep -qiE 'no stats available|never'; then
    log "  ${C_YELLOW}btrfs: nenhum scrub registrado em / — recomendado rodar periodicamente.${C_RESET}"
    log "  Remediação: sudo btrfs scrub start /"
    (( status == 0 )) && status="$RC_TODO"
  else
    # Extrai a data do início do último scrub (linhas variam por versão).
    local started
    started="$(printf '%s\n' "$scrub" | sed -nE 's/.*(started at|Scrub started:)[[:space:]]*//Ip' | head -1)"
    if [[ -n "$started" ]]; then
      last_epoch="$(date -d "$started" +%s 2>/dev/null || true)"
      now_epoch="$(date +%s 2>/dev/null || true)"
      if [[ "$last_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]]; then
        age_days=$(( (now_epoch - last_epoch) / 86400 ))
        if (( age_days > max_days )); then
          log "  ${C_YELLOW}btrfs: último scrub há ${age_days} dia(s) (> ${max_days}).${C_RESET}"
          log "  Remediação: sudo btrfs scrub start /"
          (( status == 0 )) && status="$RC_TODO"
        else
          log "  btrfs: último scrub há ${age_days} dia(s) (limite ${max_days}) — OK."
        fi
      fi
    fi
  fi

  if (( status == RC_TODO )); then
    STEP_REASON="btrfs: erros de device e/ou scrub vencido em /"
  fi
  return "$status"
}


# F4 — tempo de boot: total via systemd-analyze + piores units (blame).
# RC_WARN se o tempo total exceder BOOT_TIME_WARN_S.
doctor_boot_time() {
  if ! has systemd-analyze; then
    log "  systemd-analyze não disponível; pulando."
    return 0
  fi

  # Em container/sistema sem boot completo, systemd-analyze falha — trata limpo.
  local time_out
  time_out="$(systemd-analyze time 2>/dev/null || true)"
  if [[ -z "${time_out//[[:space:]]/}" ]]; then
    log "  systemd-analyze sem dados de boot (container?); pulando."
    return 0
  fi
  printf '%s\n' "$time_out" | tee >(_strip_ansi >> "$LOG_FILE")

  # "Startup finished in ... = 12.345s" — pega o total após o último '='.
  local total_str total_s warn_s
  total_str="$(printf '%s\n' "$time_out" | sed -nE 's/.*=[[:space:]]*//p' | head -1)"
  [[ -z "$total_str" ]] && total_str="$time_out"
  total_s="$(systemd_time_to_seconds "$total_str")"
  warn_s="${BOOT_TIME_WARN_S:-60}"

  # Top 5 piores units (blame).
  if has systemd-analyze; then
    local blame
    blame="$(systemd-analyze blame --no-pager 2>/dev/null | head -5 || true)"
    if [[ -n "${blame//[[:space:]]/}" ]]; then
      log "  Piores units no boot (top 5):"
      printf '%s\n' "$blame" | tee >(_strip_ansi >> "$LOG_FILE")
    fi
  fi

  if [[ "$total_s" =~ ^[0-9]+$ ]] && (( total_s > warn_s )); then
    log "  ${C_YELLOW}Boot levou ~${total_s}s (limite ${warn_s}s) — investigue as units acima.${C_RESET}"
    STEP_REASON="boot ~${total_s}s acima do limite (${warn_s}s)"
    return "$RC_WARN"
  fi

  log "  Tempo de boot dentro do limite (~${total_s}s ≤ ${warn_s}s)."
  return 0
}

