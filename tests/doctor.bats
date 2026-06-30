#!/usr/bin/env bats
# tests/doctor.bats — funções puras de auditoria (lib/steps/doctor.sh).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
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
