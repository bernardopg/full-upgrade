#!/usr/bin/env bash
# lib/steps/doctor/system.sh — auditorias de sistema: systemd, journal, coredumps, rede, sessão desktop e serviços.
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)


# Versão do systemd EM EXECUÇÃO, extraída da 1ª linha de `systemctl --version`.
# Em Arch a linha é "systemd 261 (261-1-arch)": o parêntese traz a versão Arch
# COMPLETA (com pkgrel), idêntica à de `pacman -Q systemd` ("261-1"). Puro.
# O token $2 ("261") NÃO traz o pkgrel, então comparar com "261-1" falso-positivava
# "reboot pendente" para sempre após bump de pkgrel — daí preferir o parêntese.
# Fallback (formato atípico/sem parêntese): só o major numérico do $2.
systemd_running_version() {
  local line="$1" v
  v="$(sed -nE 's/.*\(([0-9][^)]*)\).*/\1/p' <<<"$line" | sed 's/-arch.*$//')"
  [[ -n "$v" ]] || v="$(awk '{print $2}' <<<"$line" | grep -oE '^[0-9]+' || true)"
  printf '%s' "$v"
}


# Nome do pacote do kernel EM EXECUÇÃO. Arch grava o pkgbase de cada kernel em
# /usr/lib/modules/<release>/pkgbase — é a fonte canônica (a mesma usada por
# kernel-modules-hook) e a única que distingue as variantes. Sem ela o Doctor
# comparava o kernel rodando contra o pacote `linux` fixo: numa máquina que
# BOOTA linux-lts e tem `linux` instalado em paralelo, "6.18.48-1-lts" nunca
# igualava "7.2.2-arch1-1", então "reboot pendente" ficava cravado em todo run
# e envenenava REBOOT_RECOMMENDATION com um motivo falso. Puro: recebe o
# release e o diretório-raiz dos módulos, para ser testável sem tocar o host.
kernel_running_pkgbase() {
  local release="$1" modules_root="${2:-/usr/lib/modules}" pkgbase_file
  pkgbase_file="${modules_root}/${release}/pkgbase"
  if [[ -r "$pkgbase_file" ]]; then
    tr -d '[:space:]' <"$pkgbase_file"
    return 0
  fi
  # Sem diretório de módulos, o kernel em execução já foi desinstalado ou
  # substituído — o pacote de origem é indeterminável, mas isso por si só já
  # significa reboot pendente. Emite nada (rc 1) e deixa o chamador decidir.
  return 1
}


doctor_reboot_pending() {
  if ! has pacman; then
    log "  pacman indisponível; pulando checagem de reboot do kernel."
    return 0
  fi

  local running installed expected pkgbase
  running="$(uname -r)"

  if ! pkgbase="$(kernel_running_pkgbase "$running")"; then
    log "  Kernel em execução ${running} não tem mais módulos instalados — reboot pendente."
    remediation "systemctl reboot"
    STEP_REASON="kernel ${running} sem módulos instalados"
    return "$RC_TODO"
  fi

  if ! pacman -Q "$pkgbase" >/dev/null 2>&1; then
    log "  Pacote ${pkgbase} não encontrado; pulando checagem de reboot do kernel."
    return 0
  fi

  installed="$(pacman -Q "$pkgbase" 2>/dev/null | awk '{print $2}' || true)"
  # `pacman -Q linux` diz "7.2.2.arch1-1" e o `uname -r` diz "7.2.2-arch1-1";
  # as variantes com sufixo (lts/zen/hardened/rt) ainda anexam o flavour ao
  # release. Normaliza os dois efeitos para comparar maçã com maçã.
  expected="${installed/.arch/-arch}"
  case "$pkgbase" in
    linux) ;;
    linux-*)
      local flavour="${pkgbase#linux-}"
      expected="${expected/.${flavour}/-${flavour}}"
      [[ "$expected" == *"-${flavour}" ]] || expected="${expected}-${flavour}"
      ;;
  esac

  if [[ -z "$installed" || -z "$expected" ]]; then
    log "  Não foi possível determinar versão instalada do kernel."
    return "$RC_WARN"
  fi

  local status=0
  local -a reboot_reasons=()

  if [[ "$running" == "$expected" ]]; then
    log "  Kernel em execução corresponde ao pacote instalado: ${running} (${pkgbase})."
  else
    log "  Reboot pendente: kernel em execução=${running}; pacote ${pkgbase} instalado=${expected}."
    remediation "systemctl reboot"
    reboot_reasons+=("kernel ${running} → ${expected}")
    status="$RC_TODO"
  fi

  # systemd: versão em uso vs instalado (comparação precisa via parêntese da
  # `systemctl --version`, que traz a versão Arch completa com pkgrel).
  if has systemctl; then
    local sd_running sd_installed
    sd_running="$(systemd_running_version "$(systemctl --version 2>/dev/null | head -1)")"
    sd_installed="$(pacman -Q systemd 2>/dev/null | awk '{print $2}' || true)"
    # Se o parse trouxe só o major (fallback sem pkgrel), reduz o instalado ao
    # mesmo nível para não comparar "261" contra "261-1".
    [[ "$sd_running" == *-* ]] || sd_installed="${sd_installed%%-*}"
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

  if [[ $failed_system != *[![:space:]]* && $failed_user != *[![:space:]]* ]]; then
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

  local _sys_cnt=0 _usr_cnt=0
  if [[ $failed_system == *[![:space:]]* ]]; then
    _sys_cnt="$(printf '%s\n' "$failed_system" | grep -c '[^[:space:]]' || true)"
    log "  Units systemd falhadas:"
    printf '%s\n' "$failed_system" | log_stream
  fi

  # Units app-<nome>@autostart.service são geradas pelo
  # systemd-xdg-autostart-generator a partir de .desktop em ~/.config/autostart.
  # Têm Restart=no e ficam "failed" sempre que o app de sessão gráfica é
  # fechado/KILLado — artefato do generator, não um serviço quebrado. Separamos
  # essas das units --user reais: se só restarem app-autostart, vira nota
  # informativa (✔) em vez de TODO.
  local _usr_real="" _usr_autostart=""
  if [[ $failed_user == *[![:space:]]* ]]; then
    while IFS= read -r _line; do
      [[ $_line != *[![:space:]]* ]] && continue
      if [[ "$_line" =~ ^[[:space:]]*app-.*@autostart\.service[[:space:]] ]] ||
         [[ "$_line" =~ ^[[:space:]]*app-.*\.scope[[:space:]] ]]; then
        _usr_autostart+="${_line}"$'\n'
      else
        _usr_real+="${_line}"$'\n'
      fi
    done <<< "$failed_user"
  fi

  _usr_cnt="$(printf '%s' "$_usr_real" | grep -c '[^[:space:]]' || true)"

  if [[ $_usr_real == *[![:space:]]* ]]; then
    log "  Units systemd --user falhadas:"
    printf '%s' "$_usr_real" | sed '/^[[:space:]]*$/d' | log_stream
  fi
  if [[ $_usr_autostart == *[![:space:]]* ]]; then
    local _auto_cnt
    _auto_cnt="$(printf '%s' "$_usr_autostart" | grep -c '[^[:space:]]' || true)"
    log "  ${_auto_cnt} unit(s) gerada(s) para app de sessão em estado failed (autostart/scope transitório — app encerrado, não é serviço persistente quebrado):"
    printf '%s' "$_usr_autostart" | sed '/^[[:space:]]*$/d' | log_stream
  fi
  if [[ -z "${_usr_real}${_usr_autostart}" ]] && [[ "$user_scope" != "available" ]]; then
    case "$user_scope" in
      no-runtime) log "  Checagem systemd --user pulada (sem XDG_RUNTIME_DIR/sessão de usuário)." ;;
      no-bus) log "  Checagem systemd --user pulada (sem bus de sessão em XDG_RUNTIME_DIR)." ;;
    esac
  fi

  # Se só há app-autostart (generator) e nenhuma unit de sistema/usuário real
  # falhada, é informativo — não aciona TODO.
  if (( _sys_cnt == 0 )) && (( _usr_cnt == 0 )) && [[ $_usr_autostart == *[![:space:]]* ]]; then
    log "  Nenhuma unit de serviço real falhada; só unit(s) transitória(s) de app de sessão."
    return 0
  fi

  STEP_REASON="${_sys_cnt} unit(s) sistema + ${_usr_cnt} unit(s) usuário falhada(s)"
  return "$RC_TODO"
}



# K4 — dica acionável para assinaturas de erro de journal conhecidas. Recebe uma
# linha de erro (já filtrada/agrupada) e emite uma sugestão curta, ou nada quando
# não há dica conhecida. Read-only; só agrega contexto ao diagnóstico.
journal_hint_for() {
  local l="$1"
  case "$l" in
    *applications.menu*not\ found*|*'"applications.menu"'*)
      printf 'menu XDG ausente: instale "archlinux-xdg-menu" e rode "XDG_MENU_PREFIX=arch- kbuildsycoca6" (KDE) para regenerar o cache de menus' ;;
    *ZapZap\ WAWeb\ Theme\ Controller*|*WhatsApp\ Web\ ThemeContext*)
      printf 'ZapZap/WhatsApp Web: falha transitória ao detectar tema; atualize/reinicie o app se persistir' ;;
    *Uncaught\ \(in\ promise\)\ DisconnectedError*|*Uncaught\ \(in\ promise\)\ cancel*|*Uncaught\ \(in\ promise\)\ CustomError:\ fh*)
      printf 'erro de promise em app Electron/Chromium sem serviço falhado; normalmente benigno se não houver crash visível' ;;
    *Bluetooth:\ hci0*|*a2dp-sink*|*btd_service_connect*|*bluetoothd*|*profiles/audio/avdtp.c*|*bluez_output*)
      printf 'Bluetooth/áudio transitório (normalmente benigno): verifique firmware do adaptador e reconexão do dispositivo; se recorrente, "systemctl restart bluetooth"' ;;
    *ftdi_sio\ ttyUSB0:\ error\ from\ flowcontrol\ urb*)
      printf 'USB serial FTDI: erro transitório de flow control; verifique cabo/dispositivo ttyUSB0 se houver falha prática' ;;
    *full-upgrade-tray.service:\ Failed\ at\ step\ EXEC\ spawning\ */full-upgrade:*)
      printf 'full-upgrade-tray: a unit tentou executar um caminho inexistente; atualize/reinstale o pacote e reinicie a unit com "systemctl --user daemon-reload && systemctl --user restart full-upgrade-tray.service"' ;;
    *pam_unix*authentication\ failure*|*sudo*authentication\ failure*|*pam_authenticate*)
      printf 'falha de autenticação sudo/PAM registrada: confirme se não há script/serviço tentando sudo com senha incorreta' ;;
    *Found\ ordering\ cycle*|*Job\ *deleted\ to\ break\ ordering\ cycle*|*Breaking\ ordering\ cycle*)
      printf 'ciclo de ordenação systemd: uma unit declara After= de um alvo que também a puxa via WantedBy=; o systemd quebra o ciclo descartando um job, então a unit pode não rodar. Rode "systemd-analyze verify <unit>" e troque o WantedBy= pelo serviço concreto (ou remova o After=)' ;;
    *dumped\ core*)
      printf 'coredump de app: "coredumpctl list" e "coredumpctl info <PID>" identificam o processo; crash de app de usuário (Electron/IDE) costuma ser bug do app, não do sistema' ;;
    *)
      : ;;
  esac
}


# Classifica uma assinatura agrupada do journal (com ou sem prefixo de contagem
# do `uniq -c`). Saída: benign/actionable/unknown. Usada para evitar warn
# recorrente quando só restam erros ambientais conhecidos de sessão gráfica,
# Bluetooth/áudio ou USB serial.
journal_signature_class() {
  local l="$1"
  l="${l#"${l%%[![:space:]]*}"}"
  l="$(printf '%s\n' "$l" | sed -E 's/^[0-9]+[[:space:]]+//')"
  case "$l" in
    *ZapZap\ WAWeb\ Theme\ Controller*|*WhatsApp\ Web\ ThemeContext*|\
    *Uncaught\ \(in\ promise\)\ DisconnectedError*|\
    *Uncaught\ \(in\ promise\)\ cancel*|\
    *Uncaught\ \(in\ promise\)\ CustomError:\ fh*|\
    *profiles/audio/avdtp.c*|*bluez_output*|\
    *ftdi_sio\ ttyUSB0:\ error\ from\ flowcontrol\ urb*)
      printf 'benign' ;;
    *pam_unix*authentication\ failure*|*sudo*authentication\ failure*|*pam_authenticate*|\
    *I/O\ error*|*Buffer\ I/O*|*EXT4-fs\ error*|*BTRFS:\ error*|\
    *kernel\ panic*|*Oops:*|*segfault*|*dumped\ core*)
      printf 'actionable' ;;
    *)
      printf 'unknown' ;;
  esac
}


# Um erro antigo do próprio full-upgrade-tray pode ficar no journal do boot
# mesmo depois de o pacote atualizar a unit e o daemon voltar. Só rebaixa essa
# assinatura quando o serviço atual está ativo; se a unit ainda estiver quebrada,
# o Doctor continua avisando.
journal_full_upgrade_tray_exec_self_healed() {
  local l="$1"
  [[ "$l" == *"full-upgrade-tray.service: Failed at step EXEC spawning "*"/full-upgrade:"* ]] || return 1
  has systemctl || return 1
  systemctl --user is-active full-upgrade-tray.service >/dev/null 2>&1
}


journal_dmail_exec_self_healed() {
  local l="$1"
  [[ "$l" == *"dmail.service:"*"Neither a valid executable name nor an absolute path:"* ]] || return 1
  has systemctl || return 1
  systemctl --user is-active dmail.service >/dev/null 2>&1
}


journal_battery_warning_self_healed() {
  local l="$1" result status
  [[ "$l" == *"Failed to start Battery Low Warning Check."* ]] || return 1
  has systemctl || return 1
  result="$(systemctl --user show battery-warning.service -p Result --value 2>/dev/null || true)"
  status="$(systemctl --user show battery-warning.service -p ExecMainStatus --value 2>/dev/null || true)"
  [[ "$result" == "success" && "$status" == "0" ]]
}


journal_effective_signature_class() {
  local l="$1" class
  class="$(journal_signature_class "$l")"
  if [[ "$class" == "unknown" ]] && {
    journal_full_upgrade_tray_exec_self_healed "$l" ||
      journal_dmail_exec_self_healed "$l" ||
      journal_battery_warning_self_healed "$l"
  }; then
    printf 'benign'
  else
    printf '%s' "$class"
  fi
}


# Aplica a mesma allow-list estrita de ruído a qualquer recorte do journal.
# Mantida separada para o Doctor poder mostrar o boot inteiro, mas decidir a
# severidade apenas com eventos ocorridos durante o run atual.
journal_filter_known_noise() {
  local input="$1" pat_file
  local -a pats=()
  mapfile -t pats < <(journal_noise_patterns)
  pat_file="$(mktemp 2>/dev/null || printf '')"
  if [[ -n "$pat_file" ]]; then
    printf '%s\n' "${pats[@]}" > "$pat_file"
    printf '%s\n' "$input" | grep -Evf "$pat_file" || true
    rm -f "$pat_file"
    return 0
  fi

  local filtered="$input" pat
  for pat in "${pats[@]}"; do
    filtered="$(printf '%s\n' "$filtered" | grep -Ev "$pat" || true)"
  done
  printf '%s\n' "$filtered"
}



# Padrões de ruído conhecido do journal (um ERE por linha via stdout) — grep-E
# aplicado linha a linha antes de agrupar. São erros priority<=3 (err) que são
# benignos/não-acionáveis na prática: bugs de firmware (DSDT/ACPI), drivers
# pedindo report upstream, hardware ausente, ou races transitórios de boot.
# Mantidos específicos para nunca mascarar uma falha real (ex.: serviço que
# não subiu, I/O error de disco). Inclui os padrões extras de
# ~/.config/full-upgrade/journal-noise.txt. Compartilhado por
# doctor_journal_errors e journal_unknown_signatures (--doctor-ack-journal).
journal_noise_patterns() {
  local -a pats=(
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
    # ── systemd: o processo morreu antes do registro do pidref. Corrida
    #    interna do systemd com processo de vida curta; nada a fazer. ──
    'Failed to initialize pidref: No such process'
    # ── Virtualização: host sem Intel TDX — informativo, não é falha ──
    'virt/tdx: TDX not supported by the host platform'
    # ── USB: falha de enumeração de dispositivo/hub com problema de hardware
    #    (mau contato, controlador do dispositivo falhando). O kernel já faz
    #    power-cycle e desiste; não há ação do full-upgrade — é between-device.
    #    Caso típico: Genesys Hub + dispositivo na porta debaixo que o kernel
    #    não consegue ler o device descriptor (error -32 EPIPE / -71 EPROTO).
    'usb [0-9].*: device descriptor read/(all|64),? error -(32|71|110)'
    'usb [0-9].*-port[0-9]+: unable to enumerate USB device'
    'usb [0-9].*-port[0-9]+: attempt power cycle'
    'usb [0-9].*: device not accepting address [0-9]+, error -(32|71|110)'
    'usb [0-9].*: device descriptor read/all, error'
    # ── Intel WiFi (iwlwifi): microcode SW error → firmware crash dump no log.
    #    Bug entre driver iwlwifi e firmware Intel AX-series. O driver detecta o
    #    erro, faz dump do estado (registers, PC, Fseq), reinicia o firmware e
    #    recupera. Não acionável por software — é upstream driver/firmware. ──
    'iwlwifi [0-9].*: Start IWL Error Log Dump'
    'iwlwifi [0-9].*: Microcode SW error detected'
    'iwlwifi [0-9].*: Device error - SW reset'
    'iwlwifi [0-9].*: Transport status:'
    'iwlwifi [0-9].*: (UMAC|LMAC)[0-9]* (CURRENT PC|CURRENT)'
    'iwlwifi [0-9].*: Not associated and the session protection'
    'iwlwifi [0-9].*: Loaded firmware version:'
    'iwlwifi [0-9].*: IML/ROM dump'
    'iwlwifi [0-9].*: Fseq'
    'iwlwifi [0-9].*: 0x[0-9A-Fa-f]+ \|'
  )
  printf '%s\n' "${pats[@]}"

  # Coerência com COREDUMP_IGNORE_EXE: um executável já declarado como
  # "crash esperado" (ex.: ffmpeg probando streams dentro de um container)
  # é saciado no Doctor de coredumps, mas o systemd-coredump também emite
  # uma linha priority=err por crash no journal. Sem espelhar a lista aqui,
  # o mesmo evento reabria warn no Doctor de journal — um único ffmpeg em
  # loop produzia centenas de "erros críticos" que o usuário já reconheceu.
  local _exe _exe_re
  for _exe in ${COREDUMP_IGNORE_EXE:-}; do
    # Só o glob '*' é aceito como coringa; o resto vira literal para não
    # transformar um nome com '.' ou '+' em padrão amplo demais.
    _exe_re="$(sed -E 's/[][(){}.^$+?|\\]/\\&/g; s/\*/[^)]*/g' <<< "$_exe")"
    printf 'Process [0-9]+ \(%s\) of user [0-9]+ (terminated abnormally|dumped core)\n' "$_exe_re"
  done

  local noise_file="${XDG_CONFIG_HOME:-${HOME}/.config}/full-upgrade/journal-noise.txt"
  if [[ -f "$noise_file" ]]; then
    local pat
    while IFS= read -r pat; do
      [[ $pat != *[![:space:]]* || "${pat:0:1}" == "#" ]] && continue
      printf '%s\n' "$pat"
    done < "$noise_file"
  fi
}


doctor_journal_errors() {
  if ! has journalctl; then
    log "  journalctl não encontrado."
    return 0
  fi

  local output filtered rc line_count filtered_count grouped unique_count noise_count

  output="$(journalctl -q -p 3 -b --no-pager -o short-iso 2>&1)"
  rc=$?

  if (( rc != 0 )); then
    log "  Não foi possível ler erros críticos do journal."
    return "$RC_WARN"
  fi

  if [[ $output != *[![:space:]]* ]]; then
    log "  Nenhum erro crítico no journal do boot atual."
    return 0
  fi

  line_count="$(printf '%s\n' "$output" | wc -l)"

  filtered="$(journal_filter_known_noise "$output")"
  filtered="$(printf '%s\n' "$filtered" | journal_strip_prefix)"
  filtered_count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
  noise_count=$(( line_count - filtered_count ))

  if [[ $filtered != *[![:space:]]* ]]; then
    log "  Journal tem ${line_count} erro(s) crítico(s) — todos ruído conhecido filtrado (${noise_count} linha(s): firmware/ACPI, drivers, keyring, races de boot)."
    return 0
  fi

  grouped="$(printf '%s\n' "$filtered" | journal_group_signatures)"
  unique_count="$(printf '%s\n' "$grouped" | grep -c '[^[:space:]]' || true)"

  local noise_note=""
  (( noise_count > 0 )) && noise_note=", ${noise_count} de ruído filtrado"
  log "  Journal: ${filtered_count} erro(s) pós-filtro neste boot (${unique_count} assinatura(s)${noise_note}):"
  printf '%s\n' "$grouped" | log_stream

  # K4 — dicas acionáveis para assinaturas conhecidas (dedup por dica).
  local -A _hints=()
  local _g _h
  while IFS= read -r _g; do
    [[ $_g == *[![:space:]]* ]] || continue
    _h="$(journal_hint_for "$_g")"
    [[ -n "$_h" ]] && _hints["$_h"]=1
  done <<< "$grouped"
  if (( ${#_hints[@]} > 0 )); then
    log "  Dicas:"
    for _h in "${!_hints[@]}"; do log "    • ${_h}"; done
  fi

  log "  Erros filtrados agrupados por assinatura gravados no log para auditoria (1 linha por assinatura, com contagem; sem o dump bruto repetitivo)."
  {
    printf '\n--- journalctl -p 3 -b erros filtrados, agrupados por assinatura ---\n'
    printf '%s\n' "$filtered" | journal_dump_dedupe
  } >> "$LOG_FILE"

  # O inventário acima cobre o boot inteiro para auditoria, porém um erro já
  # resolvido antes do full-upgrade não deve contaminar o resultado atual nem o
  # tray. Units ainda falhadas têm um Doctor próprio; aqui o RC considera apenas
  # erros surgidos desde setup_logging, preservando coredumps/falhas causados
  # durante este run.
  local severity_grouped="$grouped" severity_count="$filtered_count" severity_unique="$unique_count"
  if [[ -n "${RUN_START_ISO:-}" ]]; then
    local recent_output recent_filtered recent_grouped recent_rc
    recent_output="$(journalctl -q -p 3 -b --since "$RUN_START_ISO" --no-pager -o short-iso 2>&1)"
    recent_rc=$?
    if (( recent_rc == 0 )); then
      recent_filtered="$(journal_filter_known_noise "$recent_output" | journal_strip_prefix)"
      if [[ $recent_filtered != *[![:space:]]* ]]; then
        log "  Assinaturas remanescentes são históricas (anteriores ao início deste run) — informativas; o estado atual é auditado pelos demais Doctors."
        STEP_REASON="journal: ${filtered_count} ocorrência(s) histórica(s), nenhuma durante o run"
        return 0
      fi
      recent_grouped="$(printf '%s\n' "$recent_filtered" | journal_group_signatures)"
      severity_grouped="$recent_grouped"
      severity_count="$(printf '%s\n' "$recent_filtered" | grep -c '[^[:space:]]' || true)"
      severity_unique="$(printf '%s\n' "$recent_grouped" | grep -c '[^[:space:]]' || true)"
      log "  Journal durante o run (desde o início): ${severity_count} ocorrência(s), ${severity_unique} assinatura(s)."
    fi
  fi

  local _all_benign=1 _class
  while IFS= read -r _g; do
    [[ $_g == *[![:space:]]* ]] || continue
    _class="$(journal_effective_signature_class "$_g")"
    if [[ "$_class" != "benign" ]]; then
      _all_benign=0
      break
    fi
  done <<< "$severity_grouped"

  if (( _all_benign )); then
    log "  Todas as assinaturas remanescentes são ruído conhecido/benigno de sessão, Bluetooth/áudio ou USB serial — informativo."
    STEP_REASON="journal: ${severity_count} erro(s) benigno(s) conhecido(s) (${severity_unique} assinatura(s))"
    return 0
  fi

  STEP_REASON="${severity_count} erro(s) crítico(s) do run (${severity_unique} assinatura(s))"
  return "$RC_WARN"
}



# Agrupa linhas de `coredumpctl list` por programa. Saída: "<contagem> <nome>
# <último caminho>", ordenada por contagem decrescente.
#
# O executável é o primeiro campo absoluto da linha, não uma posição fixa: a
# coluna COREFILE varia (present/inaccessible/none/error) e a coluna SIZE some
# quando o dump já foi removido, então índice fixo erra em parte das linhas.
#
# A chave é o basename, não o caminho: AppImages extraem para
# /tmp/appimage_extracted_<hash>/ a cada execução, e agrupar por caminho
# transformaria 17 crashes do mesmo programa em 17 ocorrências únicas — exatamente
# o padrão que este Doctor existe para enxergar. O caminho da ocorrência mais
# recente é preservado para o relatório.
coredump_group_by_executable() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if (substr($i, 1, 1) == "/") {
          n = split($i, parts, "/")
          name = parts[n]
          count[name]++
          last_path[name] = $i
          break
        }
      }
    }
    END { for (name in count) printf "%d %s %s\n", count[name], name, last_path[name] }
  ' | sort -k1,1nr -k2,2
}


# Um crash isolado é ruído (OOM, kill no shutdown, arquivo corrompido pontual);
# o mesmo programa quebrando várias vezes é bug. O Doctor de journal já lista
# "dumped core" como assinatura, mas apenas do boot atual e sem agregar por
# programa, então a recorrência — o único dado que separa acidente de defeito —
# se perdia como nota informativa.
#
# Não depende do core file estar no disco: os metadados ficam no journal mesmo
# depois de o dump ser removido por vacuum ou por Storage=none.
doctor_recurrent_coredumps() {
  if ! has coredumpctl; then
    log "  coredumpctl não encontrado."
    return 0
  fi

  # Janela larga para enxergar a recorrência; janela curta para saber se o
  # problema ainda está vivo. Sem a segunda, um crash já corrigido manteria o
  # step em todo por duas semanas.
  local window_days=14 recent_days=2 min_crashes=3
  local window_raw recent_names window_grouped

  # Ack do usuário (--doctor-ack-coredumps): dumps anteriores ao ack já foram
  # reconhecidos e a causa, corrigida. Filtrar por TIMESTAMP em vez de mutar
  # COREDUMP_IGNORE_EXE preserva a detecção de uma regressão futura do mesmo
  # programa — o mute permanente cegaria o Doctor para sempre.
  local ack_file acks=""
  ack_file="$(coredump_ack_file)"
  [[ -r "$ack_file" ]] && acks="$(cat -- "$ack_file" 2>/dev/null || true)"

  window_raw="$(coredumpctl list --no-legend --no-pager --since "-${window_days}d" 2>/dev/null || true)"
  window_raw="$(printf '%s\n' "$window_raw" | coredump_filter_acked "$acks")"

  if [[ $window_raw != *[![:space:]]* ]]; then
    log "  Nenhum coredump nos últimos ${window_days} dias."
    return 0
  fi

  window_grouped="$(printf '%s\n' "$window_raw" | coredump_group_by_executable)"

  log "  Coredumps nos últimos ${window_days} dias, por programa:"
  printf '%s\n' "$window_grouped" \
    | awk '{ printf "    %sx  %s  (%s)\n", $1, $2, $3 }' \
    | log_stream

  recent_names="$(
    coredumpctl list --no-legend --no-pager --since "-${recent_days}d" 2>/dev/null \
      | coredump_filter_acked "$acks" \
      | coredump_group_by_executable | awk '{ print $2 }'
  )"

  local hot="" stale="" ignored="" count name path
  while read -r count name path; do
    [[ -n "$name" ]] || continue
    (( count >= min_crashes )) || continue
    if coredump_exe_is_ignored "$name"; then
      ignored+="${ignored:+, }${name} (${count}x)"
      continue
    fi
    if grep -qxF -- "$name" <<<"$recent_names"; then
      hot+="${hot:+, }${name} (${count}x)"
    else
      stale+="${stale:+, }${name} (${count}x)"
    fi
  done <<< "$window_grouped"

  if [[ -n "$ignored" ]]; then
    log "  Saciado via COREDUMP_IGNORE_EXE (crash esperado/conhecido, sem TODO): ${ignored}"
  fi

  if [[ -n "$stale" ]]; then
    log "  Recorrente porém sem crash nas últimas $(( recent_days * 24 )) h (provavelmente já resolvido): ${stale}"
  fi

  if [[ -z "$hot" ]]; then
    log "  Nenhum programa com crash recorrente ativo."
    return 0
  fi

  log "  Crash recorrente ativo (>= ${min_crashes}x em ${window_days} dias, com ocorrência recente):"
  log "    ${hot}"
  log "  Investigue com: coredumpctl info <PID> e coredumpctl debug <PID>."
  log "  Crash repetido de app de usuário costuma ser bug do app; se for serviço, verifique também o Doctor de units falhadas."
  log "  Já corrigiu a causa? 'full-upgrade --doctor-ack-coredumps' marca os dumps atuais como vistos (crash novo volta a avisar)."

  STEP_REASON="crash recorrente: ${hot}"
  return "$RC_TODO"
}


# Normaliza linhas do journal: remove prefixo "timestamp host unit:" e descarta
# linhas vazias / frames de stack-trace, deixando só a mensagem (assinatura).
journal_strip_prefix() {
  sed -E 's/^[0-9T:+.-]+[[:space:]]+[^[:space:]]+[[:space:]]+[^:]+:[[:space:]]*//' \
    | grep -Ev '^[[:space:]]*$|^[[:space:]]*#[0-9]+[[:space:]]+0x|^[[:space:]]*ELF object binary architecture:|^[[:space:]]*Stack trace of thread ' \
    || true
}


# Agrupa assinaturas idênticas (stdin) por frequência decrescente, top 20.
# Saída: "<contagem> <assinatura>" por linha (formato de `uniq -c`).
journal_group_signatures() {
  sort | uniq -c | sort -nr | head -n 20
}


# Puro/testável: deduplica o dump de auditoria do journal normalizando números
# de PIDs/contadores para "N" — um crash loop com PIDs distintos (ex.: ffmpeg
# caindo 80x) colapsa em UMA assinatura com a contagem total, em vez de
# mascarar assinaturas diferentes no meio de linhas quase idênticas. Números
# colados a identificadores (wlan0, nl80211) ficam intactos para não fundir
# tokens distintos do kernel. Saída: "[ N ]x assinatura-normalizada", na ordem
# da primeira ocorrência. (sed faz a normalização: gsub do awk não suporta \1.)
journal_dump_dedupe() {
  sed -E 's/(^|[^A-Za-z0-9])[0-9]+/\1N/g' | awk '
    {
      count[$0]++
      if (!($0 in seen)) { order[++n] = $0; seen[$0] = 1 }
    }
    END { for (i = 1; i <= n; i++) printf "[ %d ]x %s\n", count[order[i]], order[i] }
  '
}


# Escapa uma assinatura de journal (texto literal) para uso como padrão ERE
# em ~/.config/full-upgrade/journal-noise.txt — usado por --doctor-ack-journal
# para gravar match exato da assinatura, sem interpretar metacaracteres que
# porventura estejam na mensagem original (ex.: parênteses de Uncaught (in
# promise), colchetes, etc.).
journal_signature_to_pattern() {
  sed -E 's/[][(){}.^$*+?|\\]/\\&/g' <<< "$1"
}


# Read-only: assinaturas do journal do boot atual classificadas como "unknown"
# pelo pipeline de doctor_journal_errors — nem ruído já conhecido, nem erro
# acionável reconhecido (pam/I/O/EXT4/BTRFS/kernel panic/coredump etc. NUNCA
# entram aqui). Candidatas a serem marcadas como ruído local via
# --doctor-ack-journal. Uma assinatura (texto, sem o prefixo de contagem do
# uniq -c) por linha; vazio se journalctl ausente/falhar ou não houver nada
# unknown. Duplica só a etapa de fetch+filtro de doctor_journal_errors (não
# seu RC/logging) para não arriscar a lógica já testada daquele step.
journal_unknown_signatures() {
  has journalctl || return 0

  local output
  output="$(journalctl -q -p 3 -b --no-pager -o short-iso 2>&1)" || return 0
  [[ $output == *[![:space:]]* ]] || return 0

  local -a noise=()
  mapfile -t noise < <(journal_noise_patterns)

  local filtered noise_pat_file pat
  noise_pat_file="$(mktemp 2>/dev/null || printf '')"
  if [[ -n "$noise_pat_file" ]]; then
    printf '%s\n' "${noise[@]}" > "$noise_pat_file"
    filtered="$(printf '%s\n' "$output" | grep -Evf "$noise_pat_file" || true)"
    rm -f "$noise_pat_file"
  else
    filtered="$output"
    for pat in "${noise[@]}"; do
      filtered="$(printf '%s\n' "$filtered" | grep -Ev -- "$pat" || true)"
    done
  fi
  filtered="$(printf '%s\n' "$filtered" | journal_strip_prefix)"
  [[ $filtered == *[![:space:]]* ]] || return 0

  local sig class
  while IFS= read -r sig; do
    [[ $sig == *[![:space:]]* ]] || continue
    class="$(journal_effective_signature_class "$sig")"
    if [[ "$class" == "unknown" ]]; then
      printf '%s\n' "$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' <<< "$sig")"
    fi
  done < <(printf '%s\n' "$filtered" | journal_group_signatures)
  return 0
}


# CLI entrypoint de --doctor-ack-journal (early-exit, chamado antes de
# setup_logging — por isso usa printf direto, não `log`). Lista assinaturas
# "unknown" do journal do boot atual e, com confirmação (ou direto com
# --yes), grava-as em ~/.config/full-upgrade/journal-noise.txt como padrões
# ERE literais, para doctor_journal_errors parar de reabrir warn a cada boot
# por causa delas. rc 0 = nada a fazer ou gravado; rc 1 = cancelado/erro.
doctor_ack_journal_interactive() {
  if ! has journalctl; then
    printf 'journalctl não encontrado; nada a fazer.\n'
    return 0
  fi

  local -a unknown=()
  mapfile -t unknown < <(journal_unknown_signatures)

  if (( ${#unknown[@]} == 0 )); then
    printf 'Nenhuma assinatura "unknown" no journal do boot atual — nada a marcar como ruído.\n'
    return 0
  fi

  local noise_file="${XDG_CONFIG_HOME:-${HOME}/.config}/full-upgrade/journal-noise.txt"

  printf '%d assinatura(s) "unknown" encontrada(s) no journal do boot atual:\n\n' "${#unknown[@]}"
  local sig
  for sig in "${unknown[@]}"; do
    printf '  • %s\n' "$sig"
  done
  printf '\n'

  if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
      printf 'Marcar todas como ruído local em %s? [s/N] ' "$noise_file"
      local answer
      read -r answer
      case "$answer" in
        [sS][iI][mM]|[sS]) ;;
        *) printf 'Cancelado.\n'; return 1 ;;
      esac
    else
      printf 'Execução não interativa sem --yes; nada gravado. Rode com --yes para confirmar automaticamente.\n'
      return 1
    fi
  fi

  local noise_dir
  noise_dir="$(dirname -- "$noise_file")"
  mkdir -p -- "$noise_dir" || { printf 'Erro: não foi possível criar %s.\n' "$noise_dir" >&2; return 1; }
  touch -- "$noise_file" || { printf 'Erro: não foi possível gravar em %s.\n' "$noise_file" >&2; return 1; }

  local added=0 pattern
  for sig in "${unknown[@]}"; do
    pattern="$(journal_signature_to_pattern "$sig")"
    grep -qxF -- "$pattern" "$noise_file" 2>/dev/null && continue
    printf '%s\n' "$pattern" >> "$noise_file"
    ((added++))
  done

  if (( added == 0 )); then
    printf 'Todas as assinaturas já estavam em %s; nada gravado.\n' "$noise_file"
  else
    printf '%d padrão(ões) adicionado(s) em %s.\n' "$added" "$noise_file"
  fi
  return 0
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
    if [[ "$(http_code_class "$http_code")" == "ok" ]]; then
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



# O checkservices tem efeitos colaterais por padrão: abre pacdiff, recarrega o
# systemd e oferece restart. Para descoberta, desliga explicitamente tudo isso
# (-P -L -F -R), preservando o contrato read-only do doctor.
_checkservices_readonly() {
  sudo -n checkservices -P -L -F -R
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
    if (( rc != 0 )) && [[ $output != *[![:space:]]* ]]; then
      log "  needrestart retornou código ${rc}."
      return "$RC_WARN"
    fi
    local -a svc_list=() svc_ignored=()
    local svc
    while IFS= read -r svc; do
      [[ -n "$svc" ]] || continue
      if stale_service_is_ignored "$svc"; then svc_ignored+=("$svc"); else svc_list+=("$svc"); fi
    done < <(printf '%s\n' "$output" | sed -nE 's/^NEEDRESTART-SVC:?[[:space:]]*//p')
    if (( ${#svc_ignored[@]} > 0 )); then
      log "  Ignorado(s) por STALE_SERVICES_IGNORE (libs antigas até reboot/logout, por decisão do usuário): ${svc_ignored[*]}"
    fi
    local svc_count="${#svc_list[@]}"
    local kstat
    kstat="$(printf '%s\n' "$output" | awk -F'=' '/NEEDRESTART-KSTA/{print $2; exit}')"
    if (( svc_count > 0 )); then
      log "  needrestart: ${svc_count} serviço(s) usando bibliotecas antigas:"
      printf '%s\n' "${svc_list[@]}" | sed 's/^/    /' | log_stream
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
    local output rc
    output="$(_checkservices_readonly 2>&1)"
    rc=$?
    if (( rc != 0 )); then
      log "  checkservices retornou código ${rc}."
      return "$RC_WARN"
    fi
    # A saída do checkservices mistura sinal e ruído:
    #   ==> pacnew file found for /etc/...   (não é serviço)
    #   Found: 10                            (contador, não item)
    #   -------8<--------                    (delimitadores do bloco de comandos)
    #   'foo.service'                        (modo read-only atual, -R)
    #   systemctl restart 'foo.service'      (formato de versões antigas)
    # O parser antigo (grep -v '^Found: 0') deixava passar "Found: 10", os
    # delimitadores "8<" e a linha "pacnew file found", inflando a contagem
    # (ex.: 14 itens reportados para 10 serviços reais). Extraímos apenas as
    # somente as linhas de unit reconhecidas — o conjunto canônico de serviços
    # que o checkservices recomenda reiniciar.
    local -a _affected_services=() _kept_services=() _ignored_services=()
    mapfile -t _affected_services < <(printf '%s\n' "$output" | parse_checkservices_units)
    local _svc
    for _svc in "${_affected_services[@]}"; do
      if stale_service_is_ignored "$_svc"; then _ignored_services+=("$_svc"); else _kept_services+=("$_svc"); fi
    done
    if (( ${#_ignored_services[@]} > 0 )); then
      log "  Ignorado(s) por STALE_SERVICES_IGNORE (libs antigas até reboot/logout, por decisão do usuário): ${_ignored_services[*]}"
    fi
    if (( ${#_kept_services[@]} == 0 )); then
      log "  checkservices: nenhum serviço com bibliotecas antigas (após ignores de config)."
      return 0
    fi
    local svc_count="${#_kept_services[@]}"
    log "  checkservices: ${svc_count} serviço(s) usando bibliotecas substituídas (reinício recomendado):"
    printf '%s\n' "${_kept_services[@]}" | log_stream
    STEP_REASON="${svc_count} serviço(s) com libs antigas (reinício pendente)"

    if (( RESTART_SERVICES )); then
      log "  --restart-services ativo: o reinício é feito pelo step 'Reiniciar serviços com libs antigas'."
    fi
    return "$RC_TODO"
  fi

  log "  needrestart e checkservices não encontrados; instale um para monitorar serviços com libs antigas."
  return 0
}


restart_stale_services() {
  if (( ! RESTART_SERVICES )); then
    log "  --restart-services não informado; reinício de serviços pulado."
    return 0
  fi
  if ! _doctor_sudo_ok; then
    log "  checkservices requer sudo sem prompt; reinício pulado."
    return 0
  fi
  if ! has checkservices; then
    log "  checkservices não instalado; reinício automático indisponível."
    return 0
  fi

  local output rc
  output="$(_checkservices_readonly 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    log "  checkservices retornou código ${rc}."
    return "$RC_WARN"
  fi

  local -a affected_services=() ignored_services=() kept_services=()
  mapfile -t affected_services < <(printf '%s\n' "$output" | parse_checkservices_units)

  local svc
  for svc in "${affected_services[@]}"; do
    if stale_service_is_ignored "$svc"; then ignored_services+=("$svc"); else kept_services+=("$svc"); fi
  done
  if (( ${#ignored_services[@]} > 0 )); then
    log "  Ignorando por STALE_SERVICES_IGNORE (não serão reiniciados nem reportados): ${ignored_services[*]}"
  fi
  affected_services=("${kept_services[@]}")

  local display_manager_units=""
  if has systemctl; then
    display_manager_units="$(systemctl show display-manager.service --property Names --value 2>/dev/null || true)"
  fi

  local -a restart_cmds=() protected_services=()
  for svc in "${affected_services[@]}"; do
    # O checkservices enumera somente services. Restringir também aqui evita
    # que um fallback malformado faça restart de mount/target/socket.
    [[ "$svc" =~ \.service$ ]] || continue
    if service_restart_is_session_critical "$svc" "$display_manager_units"; then
      protected_services+=("$svc")
    else
      restart_cmds+=("$svc")
    fi
  done

  if (( ${#protected_services[@]} > 0 )); then
    log "  Proteção de sessão/rede: ${#protected_services[@]} unit(s) crítica(s) NÃO será(ão) reiniciada(s): ${protected_services[*]}"
    log "  Faça logout completo ou reinicie a máquina para carregar as bibliotecas dessas units com segurança."
  fi
  if (( ${#restart_cmds[@]} == 0 )); then
    if (( ${#protected_services[@]} > 0 )); then
      STEP_REASON="$(protected_units_reason "${protected_services[@]}")"
      return "$RC_TODO"
    fi
    log "  Nenhum serviço systemd reiniciável detectado por checkservices."
    return 0
  fi

  log "  ${#restart_cmds[@]} serviço(s) a reiniciar: ${restart_cmds[*]}"
  if (( ASSUME_YES == 0 )); then
    if [[ -t 0 ]]; then
      printf '%b' "${C_YELLOW}  Reiniciar esses serviços agora? [s/N] ${C_RESET}"
      local answer
      read -r answer
      case "$answer" in
        [sS][iI][mM]|[sS]) ;;
        *) log "  Reinício de serviços cancelado pelo usuário."; STEP_REASON="reinício cancelado pelo usuário"; return "$RC_TODO" ;;
      esac
    else
      log "  Execução não interativa sem --yes; pulando reinício de serviços."
      STEP_REASON="--yes ausente; ${#restart_cmds[@]} serviço(s) pendente(s) de reinício"
      return "$RC_TODO"
    fi
  fi

  local all_ok=1
  for svc in "${restart_cmds[@]}"; do
    log "  Reiniciando ${svc}..."
    if run_logged sudo -n systemctl restart "$svc"; then
      log "  ${svc}: reiniciado."
    else
      log "  Aviso: falha ao reiniciar ${svc}."
      all_ok=0
    fi
  done
  if (( ${#protected_services[@]} > 0 )); then
    STEP_REASON="$(protected_units_reason "${protected_services[@]}")"
    (( all_ok )) && return "$RC_TODO"
  fi
  (( all_ok )) && return 0
  return "$RC_WARN"
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


# ── Acknowledgement de coredumps recorrentes ─────────────────────────────────
# Caminho do arquivo de ack. Formato: "<exe><TAB><epoch do ack>", um por linha.
coredump_ack_file() {
    printf '%s/full-upgrade/coredump-ack.txt' "${XDG_CONFIG_HOME:-${HOME}/.config}"
}


# Puro/testável: lê o conteúdo do arquivo de ack em stdin e imprime o epoch
# registrado para <exe>, ou nada se não houver ack. Última linha vence
# (um novo ack sobrepõe o anterior sem exigir reescrita do arquivo).
coredump_ack_cutoff() {
    local want="$1" name epoch found=""
    while IFS=$'\t' read -r name epoch; do
        [[ -n "$name" && "${name:0:1}" != "#" ]] || continue
        [[ "$name" == "$want" ]] || continue
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        found="$epoch"
    done
    # Sempre rc 0: "sem ack" é resposta válida, não erro (chamador usa em $( )).
    [[ -n "$found" ]] && printf '%s' "$found"
    return 0
}


# Puro/testável: filtra linhas de `coredumpctl list` em stdin, descartando as
# de executáveis com ack cujo crash é ANTERIOR ao ack. Diferente de
# COREDUMP_IGNORE_EXE (mute permanente), o ack só apaga o histórico já
# reconhecido: um crash novo do mesmo programa volta a aparecer. É o que
# fecha o caso "corrigi o bug no app, para de me cobrar pelos dumps velhos"
# sem cegar o Doctor para uma regressão futura.
#
# $1 = conteúdo do arquivo de ack (multilinha). Linha do coredumpctl:
# "Qui 2026-09-18 17:33:42 -03  297557  1000 1000 SIGABRT present /caminho/exe 3.6M"
coredump_filter_acked() {
    local acks="$1"
    [[ $acks == *[![:space:]]* ]] || { cat; return 0; }
    has date || { cat; return 0; }

    local -A cutoff=()
    local name epoch
    while IFS=$'\t' read -r name epoch; do
        [[ -n "$name" && "${name:0:1}" != "#" ]] || continue
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        cutoff["$name"]="$epoch"
    done <<< "$acks"
    (( ${#cutoff[@]} > 0 )) || { cat; return 0; }

    local line exe ts when
    while IFS= read -r line; do
        [[ $line == *[![:space:]]* ]] || continue
        # Executável: primeiro campo que começa com '/'.
        exe=""
        local f
        for f in $line; do
            [[ "${f:0:1}" == "/" ]] && { exe="${f##*/}"; break; }
        done
        if [[ -z "$exe" || -z "${cutoff[$exe]:-}" ]]; then
            printf '%s\n' "$line"
            continue
        fi
        # Data/hora: campos 2 e 3 ("Qui 2026-09-18 17:33:42 -03").
        ts="$(awk '{ print $2, $3 }' <<< "$line")"
        when="$(date -d "$ts" +%s 2>/dev/null || printf '')"
        # Sem data parseável, preserva a linha (falha para o lado de avisar).
        if [[ -z "$when" ]] || (( when > cutoff[$exe] )); then
            printf '%s\n' "$line"
        fi
    done
}


# CLI entrypoint de --doctor-ack-coredumps (early-exit, antes do run normal).
# Marca os crashes recorrentes ATUAIS como reconhecidos: o Doctor passa a
# contar só dumps posteriores ao ack.
doctor_ack_coredumps_interactive() {
    if ! has coredumpctl; then
        printf 'coredumpctl não encontrado; nada a fazer.\n'
        return 0
    fi

    local raw
    raw="$(coredumpctl list --no-legend --no-pager --since "-14d" 2>/dev/null || true)"
    local ack_file
    ack_file="$(coredump_ack_file)"
    local acks=""
    [[ -r "$ack_file" ]] && acks="$(cat -- "$ack_file")"
    raw="$(printf '%s\n' "$raw" | coredump_filter_acked "$acks")"

    local -a names=()
    local count name path
    while read -r count name path; do
        [[ -n "$name" ]] || continue
        (( count >= 3 )) || continue
        coredump_exe_is_ignored "$name" && continue
        names+=("$name")
    done < <(printf '%s\n' "$raw" | coredump_group_by_executable)

    if (( ${#names[@]} == 0 )); then
        printf 'Nenhum crash recorrente pendente nos últimos 14 dias — nada a reconhecer.\n'
        return 0
    fi

    printf '%d programa(s) com crash recorrente ainda não reconhecido(s):\n\n' "${#names[@]}"
    for name in "${names[@]}"; do printf '  • %s\n' "$name"; done
    printf '\nReconhecer marca os dumps ATUAIS como vistos; crashes novos voltam a avisar.\n\n'

    if (( ASSUME_YES == 0 )); then
        if [[ -t 0 ]]; then
            printf 'Gravar ack em %s? [s/N] ' "$ack_file"
            local answer
            read -r answer
            case "$answer" in
                [sS][iI][mM]|[sS]) ;;
                *) printf 'Cancelado.\n'; return 1 ;;
            esac
        else
            printf 'Execução não interativa sem --yes; nada gravado. Rode com --yes para confirmar.\n'
            return 1
        fi
    fi

    local ack_dir
    ack_dir="$(dirname -- "$ack_file")"
    mkdir -p -- "$ack_dir" || { printf 'Erro: não foi possível criar %s.\n' "$ack_dir" >&2; return 1; }

    local now
    now="$(date +%s)"
    for name in "${names[@]}"; do
        printf '%s\t%s\n' "$name" "$now" >> "$ack_file"
    done
    printf '%d ack(s) gravado(s) em %s.\n' "${#names[@]}" "$ack_file"
    return 0
}
