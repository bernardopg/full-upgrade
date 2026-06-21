#!/usr/bin/env bats
# tests/pip_check.bats — resumo de pip check (J1).

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/doctor.sh"
}

@test "summarize: agrupa requirement conflitante por pacote" {
  out="$(printf '%s\n' \
    "pygount 1.6.1 has requirement chardet>=5.0, but you have chardet 7.4.3." \
    | summarize_pip_check)"
  [[ "$out" == "pygount"*"chardet>=5.0 (instalado: chardet 7.4.3)"* ]]
}

@test "summarize: trata dependência ausente" {
  out="$(printf '%s\n' \
    "doctoralia-scrapper 0.1 requires redis, which is not installed." \
    | summarize_pip_check)"
  [[ "$out" == "doctoralia-scrapper"*"redis (ausente)"* ]]
}

@test "summarize: múltiplos conflitos do mesmo pacote numa linha" {
  out="$(printf '%s\n' \
    "auto-cpufreq 1.0 has requirement urwid>=2.0, but you have urwid 4.0.2." \
    "auto-cpufreq 1.0 has requirement click>=8, but you have click 7.0." \
    | summarize_pip_check)"
  # um único registro para auto-cpufreq com ambos os detalhes
  [ "$(printf '%s\n' "$out" | grep -c 'auto-cpufreq')" -eq 1 ]
  [[ "$out" == *"urwid>=2.0"* ]]
  [[ "$out" == *"click>=8"* ]]
}

@test "summarize: ordena por pacote" {
  out="$(printf '%s\n' \
    "zlib-tool 1 requires foo, which is not installed." \
    "alpha-tool 1 requires bar, which is not installed." \
    | summarize_pip_check)"
  [ "$(printf '%s\n' "$out" | head -1 | cut -f1)" = "alpha-tool" ]
}

@test "summarize: versão instalada com pontos é preservada (não truncada)" {
  out="$(printf '%s\n' \
    "pygount 1.6.1 has requirement chardet>=5.0, but you have chardet 7.4.3." \
    | summarize_pip_check)"
  [[ "$out" == *"instalado: chardet 7.4.3"* ]]
  [[ "$out" != *"instalado: chardet 7)"* ]]
}

@test "summarize: spec PEP 440 multi-bound com vírgula (has requirement)" {
  out="$(printf '%s\n' \
    "foo-tool 1.0 has requirement bar>=1.0,<2.0, but you have bar 3.5.0." \
    | summarize_pip_check)"
  [[ "$out" == "foo-tool"*"bar>=1.0,<2.0 (instalado: bar 3.5.0)"* ]]
}

@test "summarize: spec PEP 440 multi-bound com vírgula (requires ausente)" {
  out="$(printf '%s\n' \
    "baz-tool 2 requires qux>=1,<2, which is not installed." \
    | summarize_pip_check)"
  [[ "$out" == "baz-tool"*"qux>=1,<2 (ausente)"* ]]
}

@test "summarize: entrada sem conflito reconhecível => vazio" {
  out="$(printf 'tudo certo aqui\n' | summarize_pip_check)"
  [ -z "${out//[[:space:]]/}" ]
}
