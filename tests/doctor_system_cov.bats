#!/usr/bin/env bats
# tests/doctor_system_cov.bats — caminhos dos Doctors de sistema (reboot, libs
# antigas, rede, desktop, ruído do journal). PATH isolado (stub_helper): nada
# executa pacman, sudo ou systemctl reais.

load test_helper
load stub_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  stub_path_init
  LOG_FILE=/dev/null QUIET=0
  STEP_REASON=""
}

# ── doctor_reboot_pending ─────────────────────────────────────────────────────

_pacman_versions() {
  # $1 = versão do kernel; $2 = versão do systemd
  stub_script pacman "case \"\$*\" in
    '-Q linux') echo 'linux $1' ;;
    '-Q linux-lts') echo 'linux-lts $1' ;;
    '-Q systemd') echo 'systemd $2' ;;
    '-Q intel-ucode') echo 'intel-ucode 20261111-1' ;;
    *) exit 1 ;;
  esac"
}

@test "reboot_pending: sem pacman não checa nada" {
  run doctor_reboot_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"pacman indisponível"* ]]
}

@test "reboot_pending: kernel sem módulos instalados vira TODO" {
  stub pacman 0
  stub uname 0 "7.3.4-arch1-2"
  kernel_running_pkgbase() { return 1; }
  doctor_reboot_pending || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "kernel 7.3.4-arch1-2 sem módulos instalados" ]]
}

@test "reboot_pending: kernel, systemd e microcode em dia => ok" {
  _pacman_versions "7.3.4.arch1-2" "261.1-1"
  stub uname 0 "7.3.4-arch1-2"
  stub systemctl 0 "systemd 261 (261.1-1-arch)"
  kernel_running_pkgbase() { echo linux; }
  run doctor_reboot_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"corresponde ao pacote instalado"* ]]
  [[ "$output" == *"systemd em execução ok: 261.1-1"* ]]
}

@test "reboot_pending: kernel lts e systemd desatualizados somam os motivos" {
  _pacman_versions "6.18.49-1" "262-1"
  stub uname 0 "6.18.48-1-lts"
  stub systemctl 0 "systemd 261 (261.1-1-arch)"
  kernel_running_pkgbase() { echo linux-lts; }
  doctor_reboot_pending || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"kernel 6.18.48-1-lts → 6.18.49-1-lts"* ]]
  [[ "$STEP_REASON" == *"systemd 261.1-1 → 262-1"* ]]
}

@test "reboot_pending: pacote do kernel ausente pula sem erro" {
  stub_script pacman 'exit 1'
  stub uname 0 "7.3.4-arch1-2"
  kernel_running_pkgbase() { echo linux-zen; }
  run doctor_reboot_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pacote linux-zen não encontrado"* ]]
}

# ── doctor_stale_services ─────────────────────────────────────────────────────

@test "stale_services: sem sudo sem prompt a checagem é pulada" {
  run doctor_stale_services
  [ "$status" -eq 0 ]
  [[ "$output" == *"requerem sudo sem prompt"* ]]
}

@test "stale_services: needrestart com serviço e kernel desatualizado => TODO" {
  stub_privilege
  stub_script needrestart 'printf "NEEDRESTART-KSTA: 3\nNEEDRESTART-SVC: sshd.service\nNEEDRESTART-SVC: NetworkManager.service\n"'
  STALE_SERVICES_IGNORE="NetworkManager.service"
  doctor_stale_services >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "1 serviço(s) com bibliotecas antigas (needrestart)" ]]
}

@test "stale_services: needrestart limpo => ok" {
  stub_privilege
  stub needrestart 0 "NEEDRESTART-KSTA: 1"
  run doctor_stale_services
  [ "$status" -eq 0 ]
  [[ "$output" == *"nenhum serviço usando bibliotecas antigas"* ]]
}

@test "stale_services: needrestart que falha sem saída vira warn" {
  stub_privilege
  stub needrestart 3
  run doctor_stale_services
  [ "$status" -eq "$RC_WARN" ]
}

@test "stale_services: checkservices com units => TODO; todas ignoradas => ok" {
  stub_privilege
  stub_script checkservices "printf \"Found: 2\n'foo.service'\n'bar.service'\n\""
  RESTART_SERVICES=1
  doctor_stale_services >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == "2 serviço(s) com libs antigas (reinício pendente)" ]]
  STALE_SERVICES_IGNORE="foo.service bar.service"
  run doctor_stale_services
  [ "$status" -eq 0 ]
}

@test "stale_services: checkservices com erro vira warn; sem ferramenta, ok" {
  stub_privilege
  stub checkservices 2
  run doctor_stale_services
  [ "$status" -eq "$RC_WARN" ]
  rm "${STUB_BIN}/checkservices"; hash -r
  run doctor_stale_services
  [ "$status" -eq 0 ]
  [[ "$output" == *"needrestart e checkservices não encontrados"* ]]
}

# ── doctor_network_health ─────────────────────────────────────────────────────

@test "network_health: sem resolver DNS vira warn" {
  run doctor_network_health
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao resolver archlinux.org"* ]]
}

@test "network_health: DNS ok e um HTTPS falhando vira warn" {
  stub dig 0 "95.217.163.246"
  stub_script curl 'case "$*" in *aur.archlinux*) echo 000 ;; *) echo 200 ;; esac'
  run doctor_network_health
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"HTTPS OK: https://archlinux.org (200)"* ]]
  [[ "$output" == *"HTTPS FALHOU: https://aur.archlinux.org"* ]]
}

@test "network_health: nslookup e host como resolvers; sem curl pula HTTPS" {
  stub_script nslookup 'printf "Server: x\nAddress: 1.1.1.1#53\n\nName: archlinux.org\nAddress: 95.217.163.246\n"'
  run doctor_network_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"DNS OK: archlinux.org → 1.1.1.1#53"* || "$output" == *"DNS OK: archlinux.org → 95.217.163.246"* ]]
  [[ "$output" == *"curl não encontrado"* ]]
  rm "${STUB_BIN}/nslookup"; hash -r
  stub host 0 "archlinux.org has address 95.217.163.246"
  stub curl 0 "200"
  run doctor_network_health
  [ "$status" -eq 0 ]
  [[ "$output" == *"DNS OK: archlinux.org → 95.217.163.246"* ]]
}

# ── journal_noise_patterns ────────────────────────────────────────────────────

@test "journal_noise_patterns: inclui COREDUMP_IGNORE_EXE e o arquivo do usuário" {
  export XDG_CONFIG_HOME="${BATS_TEST_TMPDIR}/cfg"
  mkdir -p "$XDG_CONFIG_HOME/full-upgrade"
  printf '%s\n' '# comentário' '' 'meu-ruido .*' > "$XDG_CONFIG_HOME/full-upgrade/journal-noise.txt"
  COREDUMP_IGNORE_EXE="ffmpeg my.app*"
  run journal_noise_patterns
  [ "$status" -eq 0 ]
  [[ "$output" == *'Process [0-9]+ \(ffmpeg\) of user'* ]]
  [[ "$output" == *'Process [0-9]+ \(my\.app[^)]*\) of user'* ]]
  [[ "$output" == *"meu-ruido .*"* ]]
  [[ "$output" != *"# comentário"* ]]
}

# ── doctor_desktop_health ─────────────────────────────────────────────────────

@test "desktop_health: portal ausente sugere backend do Hyprland e não falha" {
  HYPRLAND_INSTANCE_SIGNATURE=x
  run doctor_desktop_health
  [[ "$output" == *"xdg-desktop-portal-hyprland"* || "$output" == *"xdg-desktop-portal: "* ]]
}

@test "desktop_health: PipeWire instalado mas parado vira warn" {
  stub pipewire 0
  stub_script pgrep 'exit 1'
  stub pacman 0
  doctor_desktop_health >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

# ── --doctor-ack-journal e --doctor-ack-coredumps ────────────────────────────

@test "ack_journal: sem journalctl, sem unknown e grava padrões com --yes" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  run doctor_ack_journal_interactive
  [[ "$output" == *"journalctl não encontrado"* ]]
  stub journalctl 0 ""
  run doctor_ack_journal_interactive
  [[ "$output" == *"Nenhuma assinatura"* ]]
  stub journalctl 0 "2026-11-17T10:00:00-03:00 host minhaapp[123]: falha estranha 42"
  journal_effective_signature_class() { echo unknown; }
  ASSUME_YES=0 run doctor_ack_journal_interactive </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"nada gravado"* ]]
  ASSUME_YES=1 run doctor_ack_journal_interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"padrão(ões) adicionado(s)"* ]]
  [ -s "$XDG_CONFIG_HOME/full-upgrade/journal-noise.txt" ]
  # O padrão gravado passa a filtrar a linha: nada mais a reconhecer.
  ASSUME_YES=1 run doctor_ack_journal_interactive
  [[ "$output" == *"Nenhuma assinatura"* ]]
}

@test "ack_coredumps: sem coredumpctl, sem recorrentes e grava ack com --yes" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  run doctor_ack_coredumps_interactive
  [[ "$output" == *"coredumpctl não encontrado"* ]]
  stub coredumpctl 0 ""
  run doctor_ack_coredumps_interactive
  [[ "$output" == *"Nenhum crash recorrente"* ]]
  stub coredumpctl 0 "Thu 2026-11-17 01:00:00 -03 1 1000 1000 SIGSEGV present /usr/bin/prog 1K
Thu 2026-11-17 02:00:00 -03 2 1000 1000 SIGSEGV present /usr/bin/prog 1K
Thu 2026-11-17 03:00:00 -03 3 1000 1000 SIGSEGV present /usr/bin/prog 1K"
  ASSUME_YES=0 run doctor_ack_coredumps_interactive </dev/null
  [ "$status" -eq 1 ]
  ASSUME_YES=1 run doctor_ack_coredumps_interactive
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 ack(s) gravado(s)"* ]]
  grep -q "^prog	" "$XDG_CONFIG_HOME/full-upgrade/coredump-ack.txt"
}

# ── restart_stale_services ────────────────────────────────────────────────────

_checkservices_units() {
  stub_privilege
  stub_script checkservices "printf \"%s\n\" \"Found: 4\" $(printf "\"'%s'\" " "$@")"
}

@test "restart_stale_services: flag ausente, sem sudo, sem checkservices e erro" {
  RESTART_SERVICES=0 run restart_stale_services
  [[ "$output" == *"--restart-services não informado"* ]]
  RESTART_SERVICES=1 run restart_stale_services
  [[ "$output" == *"requer sudo sem prompt"* ]]
  stub_privilege
  RESTART_SERVICES=1 run restart_stale_services
  [[ "$output" == *"checkservices não instalado"* ]]
  stub checkservices 2
  RESTART_SERVICES=1 run restart_stale_services
  [ "$status" -eq "$RC_WARN" ]
}

@test "restart_stale_services: reinicia, para os de D-Bus e protege rede/sessão" {
  _checkservices_units sshd.service geoclue.service NetworkManager.service ignorado.service
  stub_script systemctl 'case "$*" in
    "show display-manager.service --property Names --value") echo "greetd.service display-manager.service" ;;
    "show geoclue.service -p Type,UnitFileState,BusName") printf "Type=dbus\nUnitFileState=static\nBusName=org.freedesktop.GeoClue2\n" ;;
    show*) printf "Type=simple\nUnitFileState=enabled\n" ;;
    *) exit 0 ;;
  esac'
  STALE_SERVICES_IGNORE="ignorado.service" RESTART_SERVICES=1 ASSUME_YES=1
  restart_stale_services >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  grep -q "^systemctl restart sshd.service" "$STUB_LOG"
  grep -q "^systemctl stop geoclue.service" "$STUB_LOG"
  ! grep -q "restart NetworkManager.service" "$STUB_LOG"
  ! grep -q "ignorado.service" "$STUB_LOG"
}

@test "restart_stale_services: sem --yes não reinicia; falha de restart vira warn" {
  _checkservices_units sshd.service
  stub_script systemctl 'case "$1" in show) exit 0 ;; restart) exit 1 ;; esac'
  RESTART_SERVICES=1 ASSUME_YES=0
  restart_stale_services </dev/null >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"--yes ausente"* ]]
  ASSUME_YES=1; unset status
  restart_stale_services >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "falha ao reiniciar: sshd.service"* ]]
}

@test "restart_stale_services: só units protegidas => TODO sem reiniciar nada" {
  _checkservices_units NetworkManager.service
  stub systemctl 0 ""
  RESTART_SERVICES=1 ASSUME_YES=1
  restart_stale_services >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  ! grep -q "restart" "$STUB_LOG"
}

# ── Cobertura completa de doctor/system.sh ────────────────────────────────────

@test "reboot_pending: versão do kernel ilegível vira warn" {
  stub_script pacman 'case "$*" in "-Q linux") echo linux ;; *) exit 1 ;; esac'
  stub uname 0 "7.3.4-arch1-2"
  kernel_running_pkgbase() { echo linux; }
  run doctor_reboot_pending
  [ "$status" -eq "$RC_WARN" ]
}

@test "reboot_pending: microcode da AMD, da Intel e sem pacote" {
  export MICROCODE_VERSION_FILE="$BATS_TEST_TMPDIR/ucode"; echo "0xa20120e" > "$MICROCODE_VERSION_FILE"
  stub uname 0 "7.3.4-arch1-2"
  kernel_running_pkgbase() { echo linux; }
  stub_script pacman 'case "$*" in "-Q linux") echo "linux 7.3.4.arch1-2" ;; "-Q amd-ucode") echo "amd-ucode 20261111-1" ;; *) exit 1 ;; esac'
  run doctor_reboot_pending
  [[ "$output" == *"pacote amd-ucode 20261111-1"* ]]
  stub_script pacman 'case "$*" in "-Q linux") echo "linux 7.3.4.arch1-2" ;; *) exit 1 ;; esac'
  run doctor_reboot_pending
  [[ "$output" == *"Microcode aplicado: 0xa20120e (pacote não detectado)"* ]]
}

@test "failed_systemd_units: sem systemctl e escopo de usuário indisponível" {
  run doctor_failed_systemd_units
  [[ "$output" == *"systemctl não encontrado"* ]]
  stub systemctl 0 ""
  systemd_user_scope_status() { echo no-runtime; }
  run doctor_failed_systemd_units
  [[ "$output" == *"sem XDG_RUNTIME_DIR"* ]]
  systemd_user_scope_status() { echo no-bus; }
  run doctor_failed_systemd_units
  [[ "$output" == *"sem bus de sessão"* ]]
  stub systemctl 0 "nginx.service loaded failed failed nginx"
  run doctor_failed_systemd_units
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"sem bus de sessão"* ]]
  systemd_user_scope_status() { echo no-runtime; }
  run doctor_failed_systemd_units
  [[ "$output" == *"sem XDG_RUNTIME_DIR"* ]]
}

@test "journal_hint_for e journal_signature_class: cada família de assinatura" {
  [[ "$(journal_hint_for 'app: Uncaught (in promise) DisconnectedError: x')" == *"Electron/Chromium"* ]]
  [[ "$(journal_hint_for 'systemd[1]: full-upgrade-tray.service: Failed at step EXEC spawning /usr/bin/full-upgrade: No such file')" == *"full-upgrade-tray"* ]]
  [[ "$(journal_hint_for 'sudo: pam_unix(sudo:auth): authentication failure')" == *"sudo/PAM"* ]]
  [[ "$(journal_hint_for 'systemd[1]: Found ordering cycle on x')" == *"ciclo de ordenação"* ]]
  [[ "$(journal_hint_for 'systemd-coredump: Process 1 (x) of user 1 dumped core.')" == *"coredump de app"* ]]
  [ -z "$(journal_hint_for 'nada conhecido')" ]
  [ "$(journal_signature_class '3 ZapZap WAWeb Theme Controller falhou')" = benign ]
  [ "$(journal_signature_class 'kernel: BTRFS: error (device nvme0n1p2)')" = actionable ]
  [ "$(journal_signature_class 'algo novo')" = unknown ]
}

@test "journal_filter_known_noise e journal_unknown_signatures: fallback sem mktemp" {
  stub mktemp 1
  run journal_filter_known_noise "kernel: ACPI BIOS Error (bug): x
erro real"
  [ "$output" = "erro real" ]
  stub journalctl 0 "2026-11-17T10:00:00-03:00 host app[1]: erro estranho 7"
  run journal_unknown_signatures
  [[ "$output" == *"erro estranho"* ]]
}

@test "journal_errors: sem journalctl, leitura falha, vazio e só ruído" {
  run doctor_journal_errors
  [[ "$output" == *"journalctl não encontrado"* ]]
  stub journalctl 1 ""
  run doctor_journal_errors
  [ "$status" -eq "$RC_WARN" ]
  stub journalctl 0 ""
  run doctor_journal_errors
  [[ "$output" == *"Nenhum erro crítico"* ]]
  stub journalctl 0 "2026-11-17T10:00:00-03:00 host kernel: ACPI BIOS Error (bug): Could not resolve"
  run doctor_journal_errors
  [[ "$output" == *"todos ruído conhecido filtrado"* ]]
}

@test "journal_errors: benignos viram ok; histórico antes do run não alarma; novo vira warn" {
  LOG_FILE="$BATS_TEST_TMPDIR/run.log"; : > "$LOG_FILE"
  stub journalctl 0 "2026-11-17T10:00:00-03:00 host app[1]: ZapZap WAWeb Theme Controller falhou"
  doctor_journal_errors >/dev/null || status=$?
  [ "${status:-0}" -eq 0 ]
  [[ "$STEP_REASON" == "journal: 1 erro(s) benigno(s) conhecido(s)"* ]]
  grep -q "erros filtrados, agrupados" "$LOG_FILE"
  stub_script journalctl 'case "$*" in *--since*) exit 0 ;; *) echo "2026-11-17T10:00:00-03:00 host app[1]: erro desconhecido 9" ;; esac'
  RUN_START_ISO="2026-11-17T11:00:00-03:00"
  doctor_journal_errors >/dev/null
  [[ "$STEP_REASON" == *"histórica(s), nenhuma durante o run"* ]]
  stub_script journalctl 'echo "2026-11-17T12:00:00-03:00 host app[1]: erro desconhecido 9"'
  unset status
  doctor_journal_errors >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "ack_journal: confirmação interativa aceita e recusa" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  stub journalctl 0 "2026-11-17T10:00:00-03:00 host minhaapp[123]: falha estranha 42"
  pty_call "steps/doctor/_common.sh steps/doctor/system.sh" \
    'journal_effective_signature_class() { echo unknown; }; ASSUME_YES=0; doctor_ack_journal_interactive' 'n\r'
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cancelado"* ]]
  pty_call "steps/doctor/_common.sh steps/doctor/system.sh" \
    'journal_effective_signature_class() { echo unknown; }; ASSUME_YES=0; doctor_ack_journal_interactive' 's\r'
  [ "$status" -eq 0 ]
  [ -s "$XDG_CONFIG_HOME/full-upgrade/journal-noise.txt" ]
}

@test "ack_journal: padrão já gravado não duplica" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  stub journalctl 0 ""
  journal_unknown_signatures() { echo "app: erro 1"; }
  ASSUME_YES=1 run doctor_ack_journal_interactive
  [[ "$output" == *"1 padrão(ões) adicionado(s)"* ]]
  ASSUME_YES=1 run doctor_ack_journal_interactive
  [[ "$output" == *"já estavam"* ]]
}

@test "ack_coredumps: confirmação interativa aceita e recusa" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  stub coredumpctl 0 "Thu 2026-11-17 01:00:00 -03 1 1000 1000 SIGSEGV present /usr/bin/prog 1K
Thu 2026-11-17 02:00:00 -03 2 1000 1000 SIGSEGV present /usr/bin/prog 1K
Thu 2026-11-17 03:00:00 -03 3 1000 1000 SIGSEGV present /usr/bin/prog 1K"
  pty_call "steps/doctor/_common.sh steps/doctor/system.sh" 'ASSUME_YES=0; doctor_ack_coredumps_interactive' 'n\r'
  [ "$status" -eq 1 ]
  pty_call "steps/doctor/_common.sh steps/doctor/system.sh" 'ASSUME_YES=0; doctor_ack_coredumps_interactive' 's\r'
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 ack(s) gravado(s)"* ]]
}

# Regressão: o modo batch imprime "NEEDRESTART-KSTA: 3"; o parser por "="
# lia vazio e o kernel desatualizado nunca virava TODO por esta via.
@test "stale_services: needrestart só com kernel desatualizado vira TODO" {
  stub_privilege
  stub needrestart 0 "NEEDRESTART-KSTA: 3"
  run doctor_stale_services
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"kernel em execução está desatualizado"* ]]
}

@test "restart_stale_services: só unit que não é .service, confirmação e stop falho" {
  _checkservices_units foo.socket
  stub systemctl 0 ""
  RESTART_SERVICES=1 ASSUME_YES=1 run restart_stale_services
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum serviço systemd reiniciável"* ]]
  _checkservices_units geoclue.service
  stub_script systemctl 'case "$*" in show*) printf "Type=dbus\nUnitFileState=static\nBusName=org.x\n" ;; stop*) exit 1 ;; esac'
  RESTART_SERVICES=1 ASSUME_YES=1 run restart_stale_services
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao parar geoclue.service"* ]]
  stub_script systemctl 'case "$*" in show*) exit 0 ;; *) exit 0 ;; esac'
  pty_call "steps/doctor/_common.sh steps/doctor/system.sh" 'RESTART_SERVICES=1; ASSUME_YES=0; restart_stale_services' 'n\r'
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"cancelado pelo usuário"* ]]
  pty_call "steps/doctor/_common.sh steps/doctor/system.sh" 'RESTART_SERVICES=1; ASSUME_YES=0; restart_stale_services' 's\r'
  [ "$status" -eq 0 ]
}

@test "desktop_health: portal, PipeWire e WirePlumber rodando; GPU; sugestões por desktop" {
  stub pacman 0
  stub pipewire 0
  stub wireplumber 0
  stub_script pgrep 'exit 0'
  stub_script vulkaninfo 'printf "D=%s W=%s\n" "${DISPLAY-unset}" "${WAYLAND_DISPLAY-unset}" >> "$BATS_TEST_TMPDIR/vk.env"; printf "deviceName         = AMD Radeon RX 7600 (RADV NAVI33)\n"'
  stub glxinfo 0 "OpenGL renderer string: AMD Radeon (radeonsi)"
  DISPLAY=:0 WAYLAND_DISPLAY=wayland-1 run doctor_desktop_health
  [ "$status" -eq 0 ]
  # vulkaninfo roda sem display: com um X que recusa conexão ele segfaulta.
  [[ "$(cat "$BATS_TEST_TMPDIR/vk.env")" == "D=unset W=unset" ]]
  [[ "$output" == *"xdg-desktop-portal: em execução"* ]]
  [[ "$output" == *"WirePlumber: em execução"* ]]
  # Nome completo do dispositivo (antes saía só a 1ª palavra).
  [[ "$output" == *"GPU Vulkan: AMD Radeon RX 7600 (RADV NAVI33)"* ]]
  rm "$STUB_BIN/vulkaninfo"; hash -r
  run doctor_desktop_health
  [[ "$output" == *"GPU OpenGL: AMD Radeon (radeonsi)"* ]]
  stub_script pgrep 'case "$*" in *wireplumber*) exit 1 ;; *) exit 0 ;; esac'
  run doctor_desktop_health
  [ "$status" -eq "$RC_WARN" ]
}

@test "desktop_health: sugestão de portal por GNOME, KDE e Wayland genérico" {
  stub_script pgrep 'exit 1'
  local d
  for d in GNOME KDE; do
    XDG_CURRENT_DESKTOP="$d" run doctor_desktop_health
    [[ "$output" == *"xdg-desktop-portal-${d,,}"* || "$output" == *"xdg-desktop-portal: "* ]]
  done
  XDG_CURRENT_DESKTOP="" XDG_SESSION_TYPE=wayland run doctor_desktop_health
  [[ "$output" == *"xdg-desktop-portal-wlr"* || "$output" == *"xdg-desktop-portal: "* ]]
}

@test "desktop_health: portal ausente sugere o backend do desktop" {
  export XDG_PORTAL_BIN="$BATS_TEST_TMPDIR/nao-existe"
  stub_script pgrep 'exit 1'
  HYPRLAND_INSTANCE_SIGNATURE=x run doctor_desktop_health
  [[ "$output" == *"xdg-desktop-portal-hyprland"* ]]
  local d
  for d in GNOME KDE; do
    HYPRLAND_INSTANCE_SIGNATURE="" XDG_CURRENT_DESKTOP="$d" run doctor_desktop_health
    [[ "$output" == *"xdg-desktop-portal-${d,,}"* ]]
  done
  HYPRLAND_INSTANCE_SIGNATURE="" XDG_CURRENT_DESKTOP="" XDG_SESSION_TYPE=wayland run doctor_desktop_health
  [[ "$output" == *"xdg-desktop-portal-wlr"* ]]
  HYPRLAND_INSTANCE_SIGNATURE="" XDG_CURRENT_DESKTOP="" XDG_SESSION_TYPE=x11 run doctor_desktop_health
  [[ "$output" == *"--needed xdg-desktop-portal'"* ]]
}
