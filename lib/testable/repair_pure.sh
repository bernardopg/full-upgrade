#!/usr/bin/env bash
# lib/testable/repair_pure.sh — funções puras extraídas de lib/steps/repair.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# repair_command_shadowing — lógica de detecção de shadowing (sem I/O real)
# Retorna: 0 = sem shadowing / já gerenciado / ok, 1 = erro, 2 = moveria binário
# Parâmetros: $1=name, $2=managed_path, $3=local_path (default /usr/local/bin/$name; override em testes)
repair_command_shadowing() {
  local name="$1"
  local managed_path="$2"
  local local_path="${3:-/usr/local/bin/${name}}"

  if [[ ! -e "$local_path" ]]; then
    return 0
  fi

  if [[ ! -e "$managed_path" ]]; then
    return 1
  fi

  if pacman -Qo "$local_path" >/dev/null 2>&1; then
    return 0
  fi

  if ! pacman -Qo "$managed_path" >/dev/null 2>&1; then
    return 1
  fi

  # Simularia: mv "$local_path" "${local_path}.manual.$(date +%Y%m%d-%H%M%S)"
  return 2
}

# repair_known_command_shadowing — lista de comandos conhecidos com shadowing
repair_known_command_shadowing() {
  repair_command_shadowing wireshark /usr/bin/wireshark
  repair_command_shadowing dumpcap /usr/bin/dumpcap
}