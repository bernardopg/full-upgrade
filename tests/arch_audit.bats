#!/usr/bin/env bats
# tests/arch_audit.bats — CVEs de pacotes oficiais via arch-audit (G2/N1).
#
# arch_audit_affected_count é puro (conta afetados, formato moderno e antigo).
# doctor_arch_audit_cves orquestra arch-audit: o total vem da saída padrão, os
# corrigíveis de `arch-audit -u`. Os testes stubam has/arch-audit (este último
# distingue a chamada com -u/--upgradable) e validam a máquina de estados.

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

@test "count: formato moderno (sem prefixo Package) é contado" {
  out="$(printf '%s\n' \
    'djvulibre is affected by arbitrary code execution. High risk!' \
    'libxml2 is affected by denial of service. High risk!' \
    'pam is affected by arbitrary filesystem access. High risk!' \
    | arch_audit_affected_count)"
  [ "$out" = "3" ]
}

@test "count: formato antigo (com prefixo Package) ainda é contado" {
  out="$(printf '%s\n' \
    'Package openssl is affected by CVE-2024-0001. High risk! Update to 3.0.1-1!' \
    'Package foo is affected by CVE-2024-0002. Medium risk!' \
    | arch_audit_affected_count)"
  [ "$out" = "2" ]
}

@test "count: saída vazia => 0" {
  run bash -c 'printf "" | { source '"${FU_LIB}"'/steps/doctor.sh; arch_audit_affected_count; }'
  [ "$output" = "0" ]
}

@test "count: ignora linhas não-afetadas" {
  out="$(printf '%s\n' 'banner irrelevante' 'Avisos: nenhum' | arch_audit_affected_count)"
  [ "$out" = "0" ]
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

@test "step: CVE corrigível (via -u) vira RC_WARN citando pacman -Syu" {
  # saída padrão lista 1 afetado; -u confirma que ele já tem correção.
  arch-audit() {
    if [[ "$*" == *"-u"* || "$*" == *"--upgradable"* ]]; then
      printf 'openssl 3.0.0-1\n'
    else
      printf 'openssl is affected by arbitrary code execution. High risk!\n'
    fi
    return 0
  }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"corrigível"* ]]
  [[ "$output" == *"pacman -Syu"* ]]
}

@test "step: apenas CVE sem correção upstream => informativo (return 0)" {
  # 2 afetados na saída padrão; -u vazio (nenhum corrigível ainda).
  arch-audit() {
    if [[ "$*" == *"-u"* || "$*" == *"--upgradable"* ]]; then
      printf ''
    else
      printf '%s\n' \
        'libheif is affected by information disclosure. Medium risk!' \
        'linux is affected by multiple issues. Medium risk!'
    fi
    return 0
  }
  run doctor_arch_audit_cves
  [ "$status" -eq 0 ]
  [[ "$output" == *"sem correção upstream"* ]]
  [[ "$output" == *"informativo"* ]]
}

@test "step: mistura corrigível + sem-correção => RC_WARN e cita o resto" {
  # 3 afetados; -u confirma 1 corrigível => 2 sem correção.
  arch-audit() {
    if [[ "$*" == *"-u"* || "$*" == *"--upgradable"* ]]; then
      printf 'openssl 3.0.0-1\n'
    else
      printf '%s\n' \
        'openssl is affected by arbitrary code execution. High risk!' \
        'libheif is affected by information disclosure. Medium risk!' \
        'linux is affected by multiple issues. Medium risk!'
    fi
    return 0
  }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"1 pacote(s) com CVE já corrigível"* ]]
  [[ "$output" == *"2 sem correção"* ]]
}

@test "step: falha de rede vira RC_WARN" {
  arch-audit() { printf 'error: could not resolve host security.archlinux.org\n'; return 1; }
  run doctor_arch_audit_cves
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"rede"* ]]
}
