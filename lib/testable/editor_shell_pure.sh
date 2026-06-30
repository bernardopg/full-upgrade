#!/usr/bin/env bash
# lib/testable/editor_shell_pure.sh — funções puras extraídas de lib/steps/editor_shell.sh
# Sourced por testes. Não executar direto.
# shellcheck shell=bash

# editor_shell_has_step — verifica se editor/shell tem step dedicado
editor_shell_has_step() {
  local name="$1"
  case "$name" in
    nvim|vim|helix|zed|code|vscode|codium|micro|emacs) return 0 ;;
    zsh|fish|bash|nu) return 0 ;;
    *) return 1 ;;
  esac
}

# editor_shell_categorize — retorna categoria: editor, shell, ou none
editor_shell_categorize() {
  local name="$1"
  case "$name" in
    nvim|vim|helix|zed|code|vscode|codium|micro|emacs) printf 'editor\n' ;;
    zsh|fish|bash|nu) printf 'shell\n' ;;
    *) return 1 ;;
  esac
}