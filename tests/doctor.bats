#!/usr/bin/env bats
# tests/doctor.bats — funções puras de auditoria (lib/steps/doctor.sh).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
}

# ── fwupd 2.1.7: Locked MTD sem dados não é regressão da máquina ─────────────

@test "fwupd HSI:1: somente Locked MTD não suportado é lacuna de medição" {
  local out
  out=$'HSI-1\n✔ TPM v2.0: Encontrado\n\n\e[1mHSI-2\e[0m\n✘ Locked MTD: Não suportado\n✘ Locked MTD: Não suportado\n\nHSI-3\n✔ CET Platform: Suportado'
  run fwupd_hsi_only_mtd_measurement_gap "$out" 1
  [ "$status" -eq 0 ]
}

@test "fwupd HSI:1: bloqueador real adicional continua acionável" {
  local out
  out=$'HSI-2\n✘ Locked MTD: Not supported\n✘ IOMMU: Disabled\n\nHSI-3'
  run fwupd_hsi_only_mtd_measurement_gap "$out" 1
  [ "$status" -ne 0 ]
}

@test "fwupd: helper não mascara HSI:0 nem nível já aceitável" {
  local out=$'HSI-2\n✘ Locked MTD: Not supported\n\nHSI-3'
  run fwupd_hsi_only_mtd_measurement_gap "$out" 0
  [ "$status" -ne 0 ]
  run fwupd_hsi_only_mtd_measurement_gap "$out" 2
  [ "$status" -ne 0 ]
}

# ── resumo da tabela de security (evita despejar ~55 linhas no terminal) ─────

@test "fwupd_security_failed_attrs: extrai o nome do atributo, sem o valor" {
  local out=$'HSI-2\n✘ Locked MTD:                    Não suportado\n✔ IOMMU: Habilitado'
  run fwupd_security_failed_attrs "$out"
  [ "$output" = "Locked MTD" ]
}

@test "fwupd_security_failed_attrs: atributo repetido aparece uma vez só" {
  local out=$'✘ Locked MTD: Não suportado\n✘ Locked MTD: Não suportado'
  run fwupd_security_failed_attrs "$out"
  [ "$output" = "Locked MTD" ]
}

@test "fwupd_security_failed_attrs: ignora o bloco de histórico com data" {
  local out=$'✘ RAM criptografada: Não suportado\n2026-03-13 18:11:41:  ✘ Kernel está contaminado'
  run fwupd_security_failed_attrs "$out"
  [ "$output" = "RAM criptografada" ]
}

@test "fwupd_security_failed_attrs: tabela sem ✘ devolve vazio" {
  local out=$'HSI-1\n✔ TPM v2.0: Encontrado\n✔ IOMMU: Habilitado'
  run fwupd_security_failed_attrs "$out"
  [ -z "$output" ]
}

@test "fwupd_security_failed_attrs: escapes ANSI não vazam para o nome" {
  local out
  out=$'\e[1mHSI-2\e[0m\n✘ Secure boot de UEFI:  \e[31m\e[1mDesabilitado\e[0m'
  run fwupd_security_failed_attrs "$out"
  [ "$output" = "Secure boot de UEFI" ]
}

@test "systemd_running_version: extrai versão Arch completa do parêntese" {
  run systemd_running_version "systemd 261 (261-1-arch)"
  [ "$status" -eq 0 ]
  [ "$output" = "261-1" ]
}

@test "systemd_running_version: preserva minor (257.8-1)" {
  run systemd_running_version "systemd 257 (257.8-1-arch)"
  [ "$output" = "257.8-1" ]
}

@test "systemd_running_version: parêntese sem sufixo -arch" {
  run systemd_running_version "systemd 254 (254)"
  [ "$output" = "254" ]
}

@test "systemd_running_version: sem parêntese cai no major do token" {
  run systemd_running_version "systemd 261"
  [ "$output" = "261" ]
}

@test "systemd_running_version: regressão — não falso-positiva após reboot" {
  # Versão em execução (parêntese) deve bater com a do pacman ("261-1"),
  # evitando 'reboot pendente' permanente que o antigo cut -d. -f1 causava.
  running="$(systemd_running_version "systemd 261 (261-1-arch)")"
  installed="261-1"
  [ "$running" = "$installed" ]
}

# ── restart_stale_services: proteção da sessão ────────────────────────────────

@test "restart_stale_services: nunca reinicia display manager da sessão" {
  QUIET=0
  RESTART_SERVICES=1
  ASSUME_YES=1
  STEP_REASON=""
  calls="${BATS_TEST_TMPDIR}/restart-calls"
  : >"$calls"
  export calls

  _doctor_sudo_ok() { return 0; }
  has() { [[ "$1" == checkservices || "$1" == systemctl ]]; }
  sudo() {
    [[ "$1 $2 $3 $4 $5 $6" == "-n checkservices -P -L -F -R" ]] || return 1
    printf '%s\n' \
      "'greetd.service'" \
      "'postgresql.service'"
  }
  systemctl() {
    [[ "$1" == show ]] && printf '%s\n' 'greetd.service display-manager.service'
  }
  run_logged() { printf '%s\n' "$*" >>"$calls"; }

  run restart_stale_services

  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"greetd.service"*"NÃO"* || "$output" == *"NÃO"*"greetd.service"* ]]
  grep -q 'systemctl restart postgresql.service' "$calls"
  ! grep -q 'systemctl restart greetd.service' "$calls"
}

# ── usage_pct_severity (classificação de uso disco/inodes) ────────────────────
@test "usage_pct_severity: >=95 => todo" {
  run usage_pct_severity 95;  [ "$output" = "todo" ]
  run usage_pct_severity 99;  [ "$output" = "todo" ]
  run usage_pct_severity 100; [ "$output" = "todo" ]
}

@test "usage_pct_severity: 90..94 => warn" {
  run usage_pct_severity 90; [ "$output" = "warn" ]
  run usage_pct_severity 94; [ "$output" = "warn" ]
}

@test "usage_pct_severity: <90 => ok" {
  run usage_pct_severity 0;  [ "$output" = "ok" ]
  run usage_pct_severity 89; [ "$output" = "ok" ]
}

@test "usage_pct_severity: aceita sufixo % e ignora não-numérico" {
  run usage_pct_severity "96%"; [ "$output" = "todo" ]
  run usage_pct_severity "-";   [ "$output" = "ok" ]
  run usage_pct_severity "";    [ "$output" = "ok" ]
}

# ── http_code_class (classificação de status HTTP) ────────────────────────────
@test "http_code_class: 2xx/3xx => ok" {
  run http_code_class 200; [ "$output" = "ok" ]
  run http_code_class 204; [ "$output" = "ok" ]
  run http_code_class 301; [ "$output" = "ok" ]
}

@test "http_code_class: 4xx/5xx/vazio => fail" {
  run http_code_class 404; [ "$output" = "fail" ]
  run http_code_class 500; [ "$output" = "fail" ]
  run http_code_class "";  [ "$output" = "fail" ]
}

# ── smart_health_class ────────────────────────────────────────────────────────
@test "smart_health_class: PASSED/OK => ok" {
  run smart_health_class PASSED; [ "$output" = "ok" ]
  run smart_health_class OK;     [ "$output" = "ok" ]
}

@test "smart_health_class: vazio => unknown; outro => todo" {
  run smart_health_class "";       [ "$output" = "unknown" ]
  run smart_health_class FAILING;  [ "$output" = "todo" ]
  run smart_health_class FAILED;   [ "$output" = "todo" ]
}

# ── smart_counter_severity ────────────────────────────────────────────────────
@test "smart_counter_severity: >0 => warn" {
  run smart_counter_severity 1;   [ "$output" = "warn" ]
  run smart_counter_severity 42;  [ "$output" = "warn" ]
}

@test "smart_counter_severity: 0/vazio/não-numérico => ok" {
  run smart_counter_severity 0;   [ "$output" = "ok" ]
  run smart_counter_severity "";  [ "$output" = "ok" ]
  run smart_counter_severity "-"; [ "$output" = "ok" ]
}

# ── bootctl_status_field ──────────────────────────────────────────────────────
@test "bootctl_status_field: extrai linux e initrd" {
  out=$'Default Boot Loader Entry:\n        title: Arch Linux\n        linux: /vmlinuz-linux\n        initrd: /initramfs-linux.img'
  run bootctl_status_field "$out" linux
  [ "$output" = "/vmlinuz-linux" ]
  run bootctl_status_field "$out" initrd
  [ "$output" = "/initramfs-linux.img" ]
}

@test "bootctl_status_field: normaliza barras duplicadas do bootctl" {
  out=$'Default Boot Loader Entry:\n        linux: /boot//vmlinuz-linux\n        initrd: /boot///intel-ucode.img'
  run bootctl_status_field "$out" linux
  [ "$output" = "/boot/vmlinuz-linux" ]
  run bootctl_status_field "$out" initrd
  [ "$output" = "/boot/intel-ucode.img" ]
}

@test "bootctl_status_field: extrai title da entrada padrão" {
  out=$'Default Boot Loader Entry:\n        title: Arch Linux'
  run bootctl_status_field "$out" title
  [ "$output" = "Arch Linux " ]
}

@test "bootctl_status_field: campo ausente => vazio" {
  out=$'Default Boot Loader Entry:\n        title: Arch'
  run bootctl_status_field "$out" linux
  [ -z "$output" ]
}

# ── pacman_qk_filter_noise (filtra falsos-positivos do pacman -Qkq) ────────────
@test "pacman_qk_filter_noise: remove linhas que casam padrões de ruído" {
  out=$'hicolor-icon-theme /usr/share/icons/hicolor/256x256@2/x.png\nfoo /usr/bin/foo: arquivo modificado\nbar /usr/lib/__pycache__/m.pyc'
  run pacman_qk_filter_noise '^hicolor-icon-theme /usr/share/icons/hicolor/256x256@2/' '/__pycache__/[^ ]*\.py[co]$' <<<"$out"
  [ "$output" = "foo /usr/bin/foo: arquivo modificado" ]
}

@test "pacman_qk_filter_noise: sem padrões => mantém linhas não-vazias" {
  out=$'a\n\nb'
  run pacman_qk_filter_noise <<<"$out"
  [ "${lines[0]}" = "a" ]
  [ "${lines[1]}" = "b" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "pacman_qk_filter_noise: tudo ruído => vazio" {
  out=$'intel-ucode /boot/intel-ucode.img'
  run pacman_qk_filter_noise '^intel-ucode /boot/intel-ucode.img$' <<<"$out"
  [ -z "$output" ]
}

# ── journal_strip_prefix (normaliza linhas do journal) ────────────────────────
@test "journal_strip_prefix: remove timestamp/host/unit deixando a mensagem" {
  line="2026-06-30T10:00:00+0000 host kernel: ACPI BIOS Error (bug): algo"
  run journal_strip_prefix <<<"$line"
  [ "$output" = "ACPI BIOS Error (bug): algo" ]
}

@test "journal_strip_prefix: descarta linhas vazias e frames de stack" {
  in=$'2026-06-30T10:00:00+0000 host app: msg real\n   #3 0xdeadbeef foo()\nStack trace of thread 123'
  run journal_strip_prefix <<<"$in"
  [ "$output" = "msg real" ]
}

# ── journal_group_signatures (agrupa por frequência) ──────────────────────────
@test "journal_group_signatures: conta e ordena por frequência decrescente" {
  in=$'erro A\nerro B\nerro A\nerro A'
  run journal_group_signatures <<<"$in"
  # primeira linha é a mais frequente (erro A, 3x)
  [[ "${lines[0]}" =~ 3.*erro\ A ]]
  [[ "${lines[1]}" =~ 1.*erro\ B ]]
}

# ── journal_signature_class (classificação de ruído pós-filtro) ───────────────
@test "journal_signature_class: ZapZap/ThemeContext é benigno" {
  run journal_signature_class '5 [ZapZap WAWeb Theme Controller] Unable to find WhatsApp Web ThemeContext after 60000 milliseconds.'
  [ "$output" = "benign" ]
}

@test "journal_signature_class: promise DisconnectedError é benigno" {
  run journal_signature_class '7 Uncaught (in promise) DisconnectedError: DisconnectedError, EndCause = 72'
  [ "$output" = "benign" ]
}

@test "journal_signature_class: Bluetooth AVDTP/PipeWire é benigno" {
  run journal_signature_class '1 profiles/audio/avdtp.c:handle_unanswered_req() No reply to Start request'
  [ "$output" = "benign" ]
  run journal_signature_class '1 pw.node: (bluez_output.XX) running -> error (Received error event)'
  [ "$output" = "benign" ]
}

@test "journal_signature_class: I/O error é acionável" {
  run journal_signature_class '1 kernel: Buffer I/O error on dev nvme0n1'
  [ "$output" = "actionable" ]
}

@test "journal_signature_class: desconhecido permanece unknown" {
  run journal_signature_class '1 app: some brand new failure'
  [ "$output" = "unknown" ]
}

@test "journal_effective_signature_class: erro antigo do tray ativo vira benigno" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 0; }
  run journal_effective_signature_class '369 full-upgrade-tray.service: Failed at step EXEC spawning /home/user/.local/bin/full-upgrade: No such file or directory'
  [ "$output" = "benign" ]
}

@test "journal_effective_signature_class: erro do tray ainda quebrado permanece unknown" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 3; }
  run journal_effective_signature_class '369 full-upgrade-tray.service: Failed at step EXEC spawning /home/user/.local/bin/full-upgrade: No such file or directory'
  [ "$output" = "unknown" ]
}

@test "journal_effective_signature_class: falha antiga do AdGuard ativo vira benigno" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { [[ "$*" == "is-active adguardvpn-svc.service" ]]; }
  run journal_effective_signature_class '2 Failed to start AdGuard VPN Service.'
  [ "$output" = "benign" ]
}

@test "journal_effective_signature_class: AdGuard ainda inativo permanece unknown" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { return 3; }
  run journal_effective_signature_class '2 Failed to start AdGuard VPN Service.'
  [ "$output" = "unknown" ]
}

@test "journal_effective_signature_class: erro antigo do dmail ativo vira benigno" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { [[ "$*" == "--user is-active dmail.service" ]]; }
  run journal_effective_signature_class '1 /home/user/.config/systemd/user/dmail.service:9: Neither a valid executable name nor an absolute path: ~/.local/bin/dmail'
  [ "$output" = "benign" ]
}

@test "journal_effective_signature_class: Battery Warning recuperado vira benigno" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() {
    [[ "$*" == *"-p Result --value"* ]] && { printf 'success\n'; return 0; }
    [[ "$*" == *"-p ExecMainStatus --value"* ]] && { printf '0\n'; return 0; }
    return 1
  }
  run journal_effective_signature_class '1 Failed to start Battery Low Warning Check.'
  [ "$output" = "benign" ]
}

@test "journal_effective_signature_class: Battery Warning ainda falhando permanece unknown" {
  has() { [[ "$1" == systemctl ]]; }
  systemctl() { printf 'exit-code\n'; }
  run journal_effective_signature_class '1 Failed to start Battery Low Warning Check.'
  [ "$output" = "unknown" ]
}

@test "journal_signature_class: coredump é acionável" {
  run journal_signature_class '2 Process 841215 (antigravity-ide) of user 1000 dumped core.'
  [ "$output" = "actionable" ]
}

@test "journal_hint_for: coredump aponta coredumpctl" {
  run journal_hint_for 'Process 841215 (antigravity-ide) of user 1000 dumped core.'
  [[ "$output" == *"coredumpctl"* ]]
}

# ── doctor_journal_errors: filtro de ruído (incl. USB enum failures) ──────────
# Erros de enumeração USB (device descriptor read error -32/-71, unable to
# enumerate, power cycle) são hardware não-acionável — o kernel já desiste.
# Devem ser filtrados como ruído, mas um erro real (ex.: I/O de disco) ainda
# surfaced como warn.

# Helper: mocka journalctl para devolver $1 (linhas) e has() p/ journalctl.
_mock_journal() {
  export _MOCK_JOURNAL_OUT="$1"
  has() { [[ "$1" == journalctl ]]; }
  journalctl() { printf '%s\n' "$_MOCK_JOURNAL_OUT"; }
}

_mock_journal_scoped() {
  export _MOCK_JOURNAL_OUT="$1" _MOCK_JOURNAL_RECENT="$2"
  has() { [[ "$1" == journalctl ]]; }
  journalctl() {
    if [[ "$*" == *"--since"* ]]; then
      printf '%s\n' "$_MOCK_JOURNAL_RECENT"
    else
      printf '%s\n' "$_MOCK_JOURNAL_OUT"
    fi
  }
}

@test "journal_errors: erro histórico não contamina o run atual" {
  QUIET=0 LOG_FILE=/dev/null RUN_START_ISO="2026-07-12T22:49:14-03:00"
  _mock_journal_scoped 'Process 123 (electron) of user 1000 dumped core.' ''
  run doctor_journal_errors
  [ "$status" -eq 0 ]
  [[ "$output" == *"históricas"* ]]
}

@test "journal_errors: erro novo durante o run mantém RC_WARN" {
  QUIET=0 LOG_FILE=/dev/null RUN_START_ISO="2026-07-12T22:49:14-03:00"
  _mock_journal_scoped 'nvme0n1: I/O error dev=nvme0n1 op=read' 'nvme0n1: I/O error dev=nvme0n1 op=read'
  run doctor_journal_errors
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"durante o run"* ]]
}

@test "journal_errors: só erros USB de enumeração => filtrados (rc 0)" {
  QUIET=0 LOG_FILE=/dev/null
  _mock_journal $'usb 3-9.3: device descriptor read/64, error -32\nusb 3-9-port3: unable to enumerate USB device\nusb 3-9.3: device not accepting address 9, error -71'
  run doctor_journal_errors
  [ "$status" -eq 0 ]
  [[ "$output" == *"ruído conhecido filtrado"* ]]
  [[ "$output" != *"unable to enumerate"* ]]
}

@test "journal_errors: erro real (I/O disco) => mantém RC_WARN" {
  QUIET=0 LOG_FILE=/dev/null
  _mock_journal 'sd 0:0:0:0: [sda] tag#0 FAILED Result: hostbyte=DID_ERROR'
  run doctor_journal_errors
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"FAILED Result"* ]]
}

@test "journal_errors: USB + erro real => só o real surfaced" {
  QUIET=0 LOG_FILE=/dev/null
  _mock_journal $'usb 3-9.3: device descriptor read/64, error -32\nnvme0n1: I/O error dev=sda op=read'
  run doctor_journal_errors
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"I/O error"* ]]
  [[ "$output" != *"descriptor read"* ]]
}

@test "journal_errors: enumeração USB bem-sucedida NÃO é filtrada" {
  # 'new high-speed USB device' / 'New USB device found' são info, não erro,
  # mas confirmamos que os padrões de filtro NÃO os casam (não mascarar
  # detecção de dispositivo novo). São priority<=3? Provavelmente não chegam
  # ao doctor, mas garantimos que o regex é específico o bastante.
  QUIET=0 LOG_FILE=/dev/null
  _mock_journal $'usb 3-9: new high-speed USB device number 4 using xhci_hcd'
  run doctor_journal_errors
  # Essa linha não casa nenhum padrão de ruído → surfaced (não filtrada).
  [[ "$output" == *"new high-speed USB device"* ]]
}

@test "journal_errors: journal vazio => rc 0, sem erros" {
  QUIET=0 LOG_FILE=/dev/null
  _mock_journal ''
  run doctor_journal_errors
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum erro crítico"* ]]
}

# ── doctor_recurrent_coredumps (crash recorrente por programa) ────────────────

_mock_coredumpctl() {
  export _MOCK_CORE_WINDOW="$1" _MOCK_CORE_RECENT="$2"
  has() { [[ "$1" == coredumpctl ]]; }
  # A janela curta (-2d) e a larga (-14d) são distinguidas pelo argumento
  # --since, exatamente como o step as emite.
  coredumpctl() {
    if [[ "$*" == *"-2d"* ]]; then
      [[ -n "$_MOCK_CORE_RECENT" ]] || return 1
      printf '%s\n' "$_MOCK_CORE_RECENT"
    else
      [[ -n "$_MOCK_CORE_WINDOW" ]] || return 1
      printf '%s\n' "$_MOCK_CORE_WINDOW"
    fi
  }
}

@test "coredump_group_by_executable: agrupa por basename, não por caminho" {
  # AppImage extrai num diretório novo a cada execução: agrupar por caminho
  # esconderia a recorrência.
  in=$'Thu 2026-07-30 00:38:57 -03 1 1000 1000 SIGTRAP present /tmp/appimage_extracted_aaa/hub 7.5M\nThu 2026-07-30 01:27:25 -03 2 0 0 SIGTRAP inaccessible /tmp/appimage_extracted_bbb/hub -\nThu 2026-07-30 01:53:13 -03 3 1000 1000 SIGSEGV present /opt/x/cli 145.9K'
  run coredump_group_by_executable <<<"$in"
  [[ "${lines[0]}" == "2 hub /tmp/appimage_extracted_bbb/hub" ]]
  [[ "${lines[1]}" == "1 cli /opt/x/cli" ]]
}

@test "coredump_group_by_executable: acha o executável mesmo com colunas variáveis" {
  # COREFILE varia (present/inaccessible/none) e SIZE some quando o dump já foi
  # removido — por isso o executável é o primeiro campo absoluto, não $10.
  in=$'Thu 2026-07-30 01:27:25 -03 2641601 0 0 SIGTRAP none /usr/bin/prog\nThu 2026-07-30 01:53:13 -03 2726827 1000 1000 SIGSEGV present /usr/bin/prog 145.9K'
  run coredump_group_by_executable <<<"$in"
  [[ "${lines[0]}" == "2 prog /usr/bin/prog" ]]
}

@test "recurrent_coredumps: 3+ crashes com ocorrência recente => todo" {
  QUIET=0 LOG_FILE=/dev/null
  STEP_REASON=""
  local crash="Sat 2026-08-01 23:13:52 -03 40031 1000 1000 SIGSEGV present /opt/x/vpn-cli 140K"
  _mock_coredumpctl "$crash"$'\n'"$crash"$'\n'"$crash" "$crash"
  run doctor_recurrent_coredumps
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"Crash recorrente ativo"* ]]
  [[ "$output" == *"vpn-cli (3x)"* ]]
}

@test "recurrent_coredumps: crashes antigos sem ocorrência recente => ok" {
  QUIET=0 LOG_FILE=/dev/null
  local crash="Tue 2026-07-21 19:44:48 -03 3167135 0 0 SIGTRAP inaccessible /tmp/e/hub -"
  _mock_coredumpctl "$crash"$'\n'"$crash"$'\n'"$crash" ""
  run doctor_recurrent_coredumps
  [ "$status" -eq 0 ]
  [[ "$output" == *"provavelmente já resolvido"* ]]
  [[ "$output" != *"Crash recorrente ativo"* ]]
}

@test "recurrent_coredumps: crash isolado não vira todo" {
  QUIET=0 LOG_FILE=/dev/null
  local crash="Sat 2026-08-01 22:57:03 -03 6726 1000 1000 SIGSEGV present /usr/lib/tb/tb 45.4M"
  _mock_coredumpctl "$crash" "$crash"
  run doctor_recurrent_coredumps
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum programa com crash recorrente ativo"* ]]
}

@test "recurrent_coredumps: sem coredumps na janela => ok" {
  QUIET=0 LOG_FILE=/dev/null
  _mock_coredumpctl "" ""
  run doctor_recurrent_coredumps
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum coredump"* ]]
}

@test "recurrent_coredumps: sem coredumpctl => ok sem ruído" {
  QUIET=0 LOG_FILE=/dev/null
  has() { return 1; }
  run doctor_recurrent_coredumps
  [ "$status" -eq 0 ]
  [[ "$output" == *"coredumpctl não encontrado"* ]]
}
