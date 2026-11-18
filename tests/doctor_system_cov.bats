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
