#!/usr/bin/env bats
# tests/core.bats — helpers puros de lib/core.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
}

# ── elapsed ───────────────────────────────────────────────────────────────────

@test "elapsed: segundos abaixo de 1 minuto" {
  run elapsed 5
  [ "$status" -eq 0 ]
  [ "$output" = "5s" ]
}

@test "elapsed: exatamente 60s vira 1m 00s" {
  run elapsed 60
  [ "$output" = "1m 00s" ]
}

@test "elapsed: minutos e segundos com zero-pad" {
  run elapsed 90
  [ "$output" = "1m 30s" ]
}

@test "elapsed: zero segundos" {
  run elapsed 0
  [ "$output" = "0s" ]
}

# ── _strip_ansi ───────────────────────────────────────────────────────────────

@test "_strip_ansi: remove códigos de cor preservando texto" {
  result="$(printf '\033[1;32mverde\033[0m normal\n' | _strip_ansi)"
  [ "$result" = "verde normal" ]
}

@test "_strip_ansi: texto sem ANSI passa intacto" {
  result="$(printf 'sem cor aqui\n' | _strip_ansi)"
  [ "$result" = "sem cor aqui" ]
}

@test "_strip_ansi: colapsa progresso com carriage return (curl/wget)" {
  # Barras de progresso reescrevem a mesma linha com \r; só o último estado fica.
  result="$(printf '10%%\r55%%\r100%% done\n' | _strip_ansi)"
  [ "$result" = "100% done" ]
}

@test "_strip_ansi: remove carriage return solto no fim da linha" {
  result="$(printf 'linha\r\n' | _strip_ansi)"
  [ "$result" = "linha" ]
}

# ── has ───────────────────────────────────────────────────────────────────────

@test "has: comando existente retorna 0" {
  run has bash
  [ "$status" -eq 0 ]
}

@test "has: comando inexistente retorna não-zero" {
  run has __comando_que_nao_existe_xyz__
  [ "$status" -ne 0 ]
}

# ── add_skip_step / skip_step_count ───────────────────────────────────────────

@test "skip_step_count: lista vazia é 0" {
  FULL_UPGRADE_SKIP=""
  run skip_step_count
  [ "$output" = "0" ]
}

@test "add_skip_step + skip_step_count: dois itens contam 2" {
  FULL_UPGRADE_SKIP=""
  add_skip_step "Step A"
  add_skip_step "Step B"
  run skip_step_count
  [ "$output" = "2" ]
}

@test "skip_step_count: ignora espaços em branco entre vírgulas" {
  FULL_UPGRADE_SKIP="A ,  B , C"
  run skip_step_count
  [ "$output" = "3" ]
}

# ── _step_skip_requested ──────────────────────────────────────────────────────

@test "_step_skip_requested: nome presente retorna 0" {
  FULL_UPGRADE_SKIP="Validar sudo,Atualizar mirrors"
  run _step_skip_requested "Atualizar mirrors"
  [ "$status" -eq 0 ]
}

@test "_step_skip_requested: respeita trim de espaços ao redor do nome" {
  FULL_UPGRADE_SKIP="  Validar sudo  ,  Atualizar mirrors  "
  run _step_skip_requested "Validar sudo"
  [ "$status" -eq 0 ]
}

@test "_step_skip_requested: nome ausente retorna não-zero" {
  FULL_UPGRADE_SKIP="Validar sudo"
  run _step_skip_requested "Step inexistente"
  [ "$status" -ne 0 ]
}

@test "_step_skip_requested: não casa substring parcial" {
  FULL_UPGRADE_SKIP="Atualizar mirrors"
  run _step_skip_requested "Atualizar"
  [ "$status" -ne 0 ]
}

# ── aur_ignore_args ───────────────────────────────────────────────────────────

@test "aur_ignore_args: lista vazia não produz saída" {
  FULL_UPGRADE_AUR_IGNORE=""
  run aur_ignore_args
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "aur_ignore_args: cada pacote vira --ignore=<pkg>" {
  FULL_UPGRADE_AUR_IGNORE="foo bar"
  run aur_ignore_args
  [ "${lines[0]}" = "--ignore=foo" ]
  [ "${lines[1]}" = "--ignore=bar" ]
}

# ── parse_checkservices_units ───────────────────────────────────────────────────

@test "parse_checkservices_units: extrai só units, ignora Found/8</pacnew" {
  out=$'==> pacnew file found for /etc/pacman.d/mirrorlist\nFound: 3\n-------8<-------------------------------8<---------\nsystemctl restart \'NetworkManager.service\'\nsystemctl restart \'postgresql.service\'\nsystemctl restart \'udisks2.service\'\n-------8<-------------------------------8<---------'
  mapfile -t result < <(printf '%s\n' "$out" | parse_checkservices_units)
  [ "${#result[@]}" -eq 3 ]
  [ "${result[0]}" = "NetworkManager.service" ]
  [ "${result[1]}" = "postgresql.service" ]
  [ "${result[2]}" = "udisks2.service" ]
}

@test "parse_checkservices_units: deduplica units repetidas" {
  out=$'systemctl restart \'foo.service\'\nsystemctl restart \'foo.service\''
  mapfile -t result < <(printf '%s\n' "$out" | parse_checkservices_units)
  [ "${#result[@]}" -eq 1 ]
  [ "${result[0]}" = "foo.service" ]
}

@test "parse_checkservices_units: saída sem units não produz nada" {
  out=$'Found: 0\n:: header'
  result="$(printf '%s\n' "$out" | parse_checkservices_units)"
  [ -z "$result" ]
}

# ── parse_cargo_vuln_bins ───────────────────────────────────────────────────────

@test "parse_cargo_vuln_bins: extrai basename dos binários vulneráveis" {
  out=$'error: 7 vulnerabilities found in /home/u/.cargo/bin/rustup\nerror: 1 vulnerability found in /home/u/.cargo/bin/cargo-audit'
  mapfile -t result < <(printf '%s\n' "$out" | parse_cargo_vuln_bins)
  [ "${#result[@]}" -eq 2 ]
  [ "${result[0]}" = "cargo-audit" ]
  [ "${result[1]}" = "rustup" ]
}

@test "parse_cargo_vuln_bins: sem vulnerabilidades não produz nada" {
  out=$'Loaded 1123 security advisories\nwarning: not built with cargo auditable'
  result="$(printf '%s\n' "$out" | parse_cargo_vuln_bins)"
  [ -z "$result" ]
}

# ── classify_cargo_bin ──────────────────────────────────────────────────────────

@test "classify_cargo_bin: rustup/cargo/rustc são toolchain" {
  [ "$(classify_cargo_bin rustup)" = "toolchain" ]
  [ "$(classify_cargo_bin cargo)" = "toolchain" ]
  [ "$(classify_cargo_bin rustc)" = "toolchain" ]
  [ "$(classify_cargo_bin rust-analyzer)" = "toolchain" ]
}

@test "classify_cargo_bin: ferramentas instaladas via cargo são cargo" {
  [ "$(classify_cargo_bin cargo-audit)" = "cargo" ]
  [ "$(classify_cargo_bin ripgrep)" = "cargo" ]
  [ "$(classify_cargo_bin bat)" = "cargo" ]
}

# ── space_is_sufficient ─────────────────────────────────────────────────────────

@test "space_is_sufficient: avail acima do mínimo retorna 0" {
  # 5 GiB disponíveis (5*1048576 KiB), mínimo 2 GiB
  run space_is_sufficient $((5 * 1048576)) 2
  [ "$status" -eq 0 ]
}

@test "space_is_sufficient: avail abaixo do mínimo retorna 1" {
  # 1 GiB disponível, mínimo 2 GiB
  run space_is_sufficient $((1 * 1048576)) 2
  [ "$status" -ne 0 ]
}

@test "space_is_sufficient: exatamente no limiar é suficiente" {
  run space_is_sufficient $((2 * 1048576)) 2
  [ "$status" -eq 0 ]
}

@test "space_is_sufficient: mínimo 0 desabilita (sempre suficiente)" {
  run space_is_sufficient 0 0
  [ "$status" -eq 0 ]
}

@test "space_is_sufficient: avail não-numérico retorna 1" {
  run space_is_sufficient "xyz" 2
  [ "$status" -ne 0 ]
}
