#!/usr/bin/env bats
# tests/editor_shell_pure.bats — testes para funções puras de lib/testable/editor_shell_pure.sh

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/testable/editor_shell_pure.sh"
}

@test "editor_shell_has_step: nvim reconhecido" {
  run editor_shell_has_step "nvim"
  [ "$status" -eq 0 ]
}

@test "editor_shell_has_step: vim reconhecido" {
  run editor_shell_has_step "vim"
  [ "$status" -eq 0 ]
}

@test "editor_shell_has_step: helix reconhecido" {
  run editor_shell_has_step "helix"
  [ "$status" -eq 0 ]
}

@test "editor_shell_has_step: code reconhecido" {
  run editor_shell_has_step "code"
  [ "$status" -eq 0 ]
}

@test "editor_shell_has_step: zsh reconhecido" {
  run editor_shell_has_step "zsh"
  [ "$status" -eq 0 ]
}

@test "editor_shell_has_step: fish reconhecido" {
  run editor_shell_has_step "fish"
  [ "$status" -eq 0 ]
}

@test "editor_shell_has_step: nano não reconhecido" {
  run editor_shell_has_step "nano"
  [ "$status" -ne 0 ]
}

@test "editor_shell_has_step: kate não reconhecido" {
  run editor_shell_has_step "kate"
  [ "$status" -ne 0 ]
}

@test "editor_shell_categorize: nvim é editor" {
  run editor_shell_categorize "nvim"
  [ "$output" = "editor" ]
}

@test "editor_shell_categorize: emacs é editor" {
  run editor_shell_categorize "emacs"
  [ "$output" = "editor" ]
}

@test "editor_shell_categorize: codium é editor" {
  run editor_shell_categorize "codium"
  [ "$output" = "editor" ]
}

@test "editor_shell_categorize: zsh é shell" {
  run editor_shell_categorize "zsh"
  [ "$output" = "shell" ]
}

@test "editor_shell_categorize: fish é shell" {
  run editor_shell_categorize "fish"
  [ "$output" = "shell" ]
}

@test "editor_shell_categorize: nu é shell" {
  run editor_shell_categorize "nu"
  [ "$output" = "shell" ]
}

@test "editor_shell_categorize: nano falha (desconhecido)" {
  run editor_shell_categorize "nano"
  [ "$status" -ne 0 ]
}
