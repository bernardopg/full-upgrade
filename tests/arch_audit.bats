#!/usr/bin/env bats
# tests/arch_audit.bats — CVEs de pacotes oficiais via arch-audit (G2).
#
# parse_arch_audit é puro (classifica a saída). doctor_arch_audit_cves orquestra
# arch-audit; os testes stubam has/arch-audit e validam a máquina de estados.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
  QUIET=0
  STEP_REASON=""
  has() { return 0; }
}

# ── parser puro ───────────────────────────────────────────────────────────────

@test "parse: conta corrigíveis e sem-correção" {
  out="$(printf '%s\n' \
    'Package openssl is affected by CVE-2024-0001. High risk! Update to 3.0.1-1!' \
    'Package foo is affected by CVE-2024-0002. Medium risk!' \
    'Package bar is affected by CVE-2024-0003. Low risk! Update to 1.0-2!' \
    | parse_arch_audit)"
  [ "$out" = "2 1" ]
}

@test "parse: saída vazia => 0 0" {
  run bash -c 'printf "" | { source '"${FU_LIB}"'/steps/doctor.sh; parse_arch_audit; }'
  [ "$output" = "0 0" ]
}

@test "parse: ignora linhas não-afetadas" {
  out="$(printf '%s\n' 'banner irrelevante' 'Avisos: nenhum' | parse_arch_audit)"
  [ "$out" = "0 0" ]
}

# ── máquina de estados doctor_arch_audit_cves ─────────────────────────────────

@test "step: sem arch-audit retorna 0" {
  has() { return 1; }
  run doctor_arch_audit_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"não instalado"* ]]
}

@test "step: sem CVEs retorna 0" {
  arch-audit() { printf ''; return 0; }
  run doctor_arch_audit_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem CVEs"* ]]
}

@test "step: CVE corrigível vira RC_WARN citando pacman -Syu" {
  arch-audit() { printf 'Package openssl is affected by CVE-2024-0001. High risk! Update to 3.0.1-1!\n'; return 0; }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"corrigível"* ]]
  [[ "$output" == *"pacman -Syu"* ]]
}

@test "step: apenas CVE sem correção vira RC_TODO" {
  arch-audit() { printf 'Package foo is affected by CVE-2024-0002. Medium risk!\n'; return 0; }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"sem correção"* ]]
}

@test "step: mistura corrigível + sem-correção => RC_WARN (precede)" {
  arch-audit() {
    printf '%s\n' \
      'Package openssl is affected by CVE-2024-0001. High! Update to 3.0.1-1!' \
      'Package foo is affected by CVE-2024-0002. Medium!'
    return 0
  }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_WARN" ]
}

@test "step: falha de rede vira RC_WARN" {
  arch-audit() { printf 'error: could not resolve host security.archlinux.org\n'; return 1; }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}
