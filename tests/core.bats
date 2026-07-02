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

# ── parse_sha256_field ──────────────────────────────────────────────────────────

@test "parse_sha256_field: extrai hash do formato sha256sum" {
  run parse_sha256_field "06394af259db19355ccf0b668c77ec0fdd9b8d5aa388d848e1bb5959e80e2a24  arquivo.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "06394af259db19355ccf0b668c77ec0fdd9b8d5aa388d848e1bb5959e80e2a24" ]
}

@test "parse_sha256_field: aceita linha só com hash" {
  run parse_sha256_field "06394af259db19355ccf0b668c77ec0fdd9b8d5aa388d848e1bb5959e80e2a24"
  [ "$status" -eq 0 ]
  [ "$output" = "06394af259db19355ccf0b668c77ec0fdd9b8d5aa388d848e1bb5959e80e2a24" ]
}

@test "parse_sha256_field: normaliza maiúsculas" {
  run parse_sha256_field "06394AF259DB19355CCF0B668C77EC0FDD9B8D5AA388D848E1BB5959E80E2A24  x"
  [ "$output" = "06394af259db19355ccf0b668c77ec0fdd9b8d5aa388d848e1bb5959e80e2a24" ]
}

@test "parse_sha256_field: rejeita string que não é hash de 64 hex" {
  run parse_sha256_field "não-é-hash"
  [ "$status" -ne 0 ]
  run parse_sha256_field "abc123"
  [ "$status" -ne 0 ]
}

# ── file_sha256 / verify_sha256 ─────────────────────────────────────────────────

@test "file_sha256: calcula o hash de um arquivo" {
  tmp="$(mktemp)"
  printf 'conteudo conhecido' > "$tmp"
  expected="$(sha256sum "$tmp" | awk '{print $1}')"
  run file_sha256 "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "verify_sha256: confere quando o hash bate" {
  tmp="$(mktemp)"
  printf 'payload' > "$tmp"
  h="$(sha256sum "$tmp" | awk '{print $1}')"
  run verify_sha256 "$tmp" "$h"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "verify_sha256: falha quando o hash não bate (adulteração)" {
  tmp="$(mktemp)"
  printf 'payload original' > "$tmp"
  wrong="0000000000000000000000000000000000000000000000000000000000000000"
  run verify_sha256 "$tmp" "$wrong"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}

@test "verify_sha256: aceita linha completa estilo sha256sum como esperado" {
  tmp="$(mktemp)"
  printf 'data' > "$tmp"
  line="$(sha256sum "$tmp")"   # "<hash>  <arquivo>"
  run verify_sha256 "$tmp" "$line"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
}

@test "verify_sha256: hash esperado inválido falha" {
  tmp="$(mktemp)"; printf 'x' > "$tmp"
  run verify_sha256 "$tmp" "lixo"
  rm -f "$tmp"
  [ "$status" -ne 0 ]
}

# ── sum_btrfs_dev_errors ────────────────────────────────────────────────────────

@test "sum_btrfs_dev_errors: soma os contadores *_errs" {
  out=$'[/dev/sda].write_io_errs    0\n[/dev/sda].read_io_errs     2\n[/dev/sda].flush_io_errs    0\n[/dev/sda].corruption_errs  1\n[/dev/sda].generation_errs  0'
  run sum_btrfs_dev_errors <<< "$out"
  [ "$output" = "3" ]
}

@test "sum_btrfs_dev_errors: tudo zero soma 0" {
  out=$'[/dev/sda].write_io_errs 0\n[/dev/sda].read_io_errs 0'
  run sum_btrfs_dev_errors <<< "$out"
  [ "$output" = "0" ]
}

@test "sum_btrfs_dev_errors: entrada vazia é 0" {
  run sum_btrfs_dev_errors <<< ""
  [ "$output" = "0" ]
}

# ── systemd_time_to_seconds ─────────────────────────────────────────────────────

@test "systemd_time_to_seconds: segundos simples" {
  run systemd_time_to_seconds "45.6s"
  [ "$output" = "45" ]
}

@test "systemd_time_to_seconds: minutos e segundos" {
  run systemd_time_to_seconds "1min 23.456s"
  [ "$output" = "83" ]
}

@test "systemd_time_to_seconds: horas, minutos e segundos" {
  run systemd_time_to_seconds "1h 2min 3s"
  [ "$output" = "3723" ]
}

@test "systemd_time_to_seconds: milissegundos contam como fração" {
  run systemd_time_to_seconds "500ms"
  [ "$output" = "0" ]
}

@test "systemd_time_to_seconds: string sem unidades é 0" {
  run systemd_time_to_seconds "sem tempo aqui"
  [ "$output" = "0" ]
}

# ── pkg_diff (L3) ─────────────────────────────────────────────────────────────

@test "pkg_diff: detecta atualizado, instalado e removido" {
  local b="${BATS_TEST_TMPDIR}/b" a="${BATS_TEST_TMPDIR}/a"
  printf 'linux 7.0.12\nbash 5.2\nold-pkg 1.0\n' > "$b"
  printf 'linux 7.0.13\nbash 5.2\nnew-pkg 2.0\n' > "$a"
  out="$(pkg_diff "$b" "$a")"
  [[ "$out" == *"U linux 7.0.12 7.0.13"* ]]
  [[ "$out" == *"I new-pkg 2.0"* ]]
  [[ "$out" == *"R old-pkg 1.0"* ]]
  # bash inalterado não aparece
  [[ "$out" != *"bash"* ]]
}

@test "pkg_diff: sem mudanças não emite nada" {
  local b="${BATS_TEST_TMPDIR}/b2" a="${BATS_TEST_TMPDIR}/a2"
  printf 'linux 7.0.12\nbash 5.2\n' > "$b"
  cp "$b" "$a"
  out="$(pkg_diff "$b" "$a")"
  [ -z "$out" ]
}

@test "pkg_diff: arquivo ausente => rc 1" {
  run pkg_diff "/nao/existe1" "/nao/existe2"
  [ "$status" -eq 1 ]
}

# ── dep_satisfied (override *_BIN no dep check do catálogo) ───────────────────

@test "dep_satisfied: comando no PATH satisfaz" {
  run dep_satisfied bash
  [ "$status" -eq 0 ]
}

@test "dep_satisfied: comando ausente sem override falha" {
  run dep_satisfied cmd-que-nao-existe-xyz
  [ "$status" -ne 0 ]
}

@test "dep_satisfied: override <CMD>_BIN executável satisfaz" {
  local fake="${BATS_TEST_TMPDIR}/fake-tool"
  printf '#!/bin/sh\n' > "$fake"
  chmod +x "$fake"
  # nome inexistente no PATH: só o override pode satisfazer
  TOOLFAKE_BIN="$fake"
  dep_satisfied toolfake
}

@test "dep_satisfied: hífen no nome vira _ no override (xyz-cli => XYZ_CLI_BIN)" {
  local fake="${BATS_TEST_TMPDIR}/fake-xyz"
  printf '#!/bin/sh\n' > "$fake"
  chmod +x "$fake"
  XYZ_CLI_INEXISTENTE_BIN="$fake"
  dep_satisfied xyz-cli-inexistente
}

@test "dep_satisfied: override apontando para não-executável falha" {
  local fake="${BATS_TEST_TMPDIR}/fake-nx"
  printf '#!/bin/sh\n' > "$fake"   # sem chmod +x
  FERRAMENTA_INEXISTENTE_XYZ_BIN="$fake"
  run dep_satisfied ferramenta-inexistente-xyz
  [ "$status" -ne 0 ]
}

# ── augment_user_path (PATH mínimo de launchers systemd/tray) ─────────────────

@test "augment_user_path: prependa dir existente ausente do PATH" {
  HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME/.local/bin"
  unset NPM_CONFIG_PREFIX
  PATH="/usr/bin"
  augment_user_path
  [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]
}

@test "augment_user_path: não duplica dir já presente" {
  HOME="${BATS_TEST_TMPDIR}/home2"
  mkdir -p "$HOME/.local/bin"
  unset NPM_CONFIG_PREFIX
  PATH="$HOME/.local/bin:/usr/bin"
  augment_user_path
  local antes="$PATH"
  augment_user_path
  [ "$PATH" = "$antes" ]
  [[ "$PATH" != "$HOME/.local/bin:$HOME/.local/bin:"* ]]
}

@test "augment_user_path: ignora dir inexistente" {
  HOME="${BATS_TEST_TMPDIR}/home3"
  mkdir -p "$HOME"
  unset NPM_CONFIG_PREFIX
  PATH="/usr/bin"
  augment_user_path
  [[ ":$PATH:" != *":$HOME/.npm-global/bin:"* ]]
}

# ── NETWORK_TRANSIENT_RE (regressão: paru/reqwest "channel closed") ──────────

@test "NETWORK_TRANSIENT_RE: casa erro reqwest do paru contra o RPC do AUR" {
  local msg='erro: error sending request for url (https://aur.archlinux.org/rpc): channel closed'
  printf '%s\n' "$msg" | grep -qiE "$NETWORK_TRANSIENT_RE"
}

@test "NETWORK_TRANSIENT_RE: casa erros clássicos de DNS/conectividade" {
  printf '%s\n' 'curl: (6) Could not resolve host: example.com' | grep -qiE "$NETWORK_TRANSIENT_RE"
  printf '%s\n' 'connect: Network is unreachable' | grep -qiE "$NETWORK_TRANSIENT_RE"
  printf '%s\n' 'Connection timed out' | grep -qiE "$NETWORK_TRANSIENT_RE"
}

@test "NETWORK_TRANSIENT_RE: não casa erro de compilação/PKGBUILD" {
  run bash -c "printf '%s\n' 'error: os pacotes foo falharam na compilação' | grep -qiE \"\$1\"" _ "$NETWORK_TRANSIENT_RE"
  [ "$status" -ne 0 ]
}
