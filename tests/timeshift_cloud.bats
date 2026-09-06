#!/usr/bin/env bats
# tests/timeshift_cloud.bats — política do backup off-site de snapshots Timeshift.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cloud_backup.sh"
}

@test "timeshift cloud: retenção padrão e inválida mantêm 3 versões" {
  unset TIMESHIFT_CLOUD_KEEP
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  TIMESHIFT_CLOUD_KEEP=0
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "timeshift cloud: retenção configurada é preservada" {
  TIMESHIFT_CLOUD_KEEP=7
  run timeshift_cloud_keep_count
  [ "$status" -eq 0 ]
  [ "$output" = "7" ]
}

@test "timeshift cloud: seleciona o snapshot Timeshift mais recente" {
  local root="${BATS_TEST_TMPDIR}/top"
  mkdir -p \
    "${root}/timeshift-btrfs/snapshots/2026-08-30_10-00-00/@" \
    "${root}/timeshift-btrfs/snapshots/2026-08-31_13-00-00/@"

  run timeshift_cloud_latest_name "$root"

  [ "$status" -eq 0 ]
  [ "$output" = "2026-08-31_13-00-00" ]
}

@test "timeshift cloud: sem snapshots retorna falha limpa" {
  local root="${BATS_TEST_TMPDIR}/empty"
  mkdir -p "$root"

  run timeshift_cloud_latest_name "$root"

  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "timeshift cloud: modo desligado é no-op" {
  TIMESHIFT_CLOUD_BACKUP=0
  run backup_timeshift_cloud

  [ "$status" -eq 0 ]
}

# ── Reparo de posse do rclone.conf na ENTRADA do step ────────────────────────
# Regressão real: o rclone roda sob sudo e reescreve o rclone.conf ao renovar o
# token, deixando-o root-owned. O chown de volta só existia no FIM do step, de
# modo que um run interrompido entre a reescrita e o conserto travava o backup
# para sempre: a guarda de credenciais barrava com "credenciais ausentes" antes
# de a linha de conserto ser alcançada, e só este step conserta.
@test "timeshift cloud: rclone.conf ilegível dispara chown antes da guarda" {
  # root lê arquivo 000 e o reparo nunca dispararia: o cenário não existe.
  [ "$(id -u)" -ne 0 ] || skip "root ignora o modo 000 que este teste depende"

  local cfg="${BATS_TEST_TMPDIR}/rclone.conf"
  local pwf="${BATS_TEST_TMPDIR}/restic-pass"
  local marker="${BATS_TEST_TMPDIR}/chown-chamado"
  printf 'segredo\n' >"$pwf"
  printf '[onedrive]\n' >"$cfg"
  chmod 000 "$cfg"

  # As guardas de dependência e de Btrfs vêm antes do reparo de posse: sem os
  # stubs, uma máquina sem restic/rclone/timeshift (todo runner de CI) sai do
  # step em RC_TODO e o trecho sob teste nunca roda — foi assim que este teste
  # passou localmente e quebrou no CI.
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  local tool
  for tool in restic rclone timeshift; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"${bin}/${tool}"
    chmod +x "${bin}/${tool}"
  done
  # FSTYPE precisa dizer btrfs; SOURCE volta vazio de propósito para encerrar o
  # step logo depois do trecho sob teste, sem montar nada.
  cat >"${bin}/findmnt" <<'STUB'
#!/usr/bin/env bash
[[ " $* " == *" FSTYPE "* ]] && { printf 'btrfs\n'; exit 0; }
exit 0
STUB
  chmod +x "${bin}/findmnt"
  PATH="${bin}:${PATH}"

  # Stub de sudo: registra o chown pedido e o executa de verdade no tmpdir.
  sudo() {
    if [[ "$1" == "-n" && "$2" == "chown" ]]; then
      printf '%s\n' "$4" >>"$marker"
      chmod 600 "$4"
      return 0
    fi
    return 1
  }
  export -f sudo 2>/dev/null || true

  TIMESHIFT_CLOUD_BACKUP=1 \
  TIMESHIFT_CLOUD_REPOSITORY="rclone:teste:repo" \
  TIMESHIFT_CLOUD_PASSWORD_FILE="$pwf" \
  TIMESHIFT_CLOUD_RCLONE_CONFIG="$cfg" \
    run backup_timeshift_cloud

  # O chown foi tentado no arquivo certo — é o que este teste protege.
  [ -s "$marker" ]
  grep -qF "$cfg" "$marker"
  # E o step não pode mais fechar com "credenciais ausentes" por posse.
  [[ "$output" != *"credenciais Restic/rclone ausentes"* ]]
}

# ── Progresso do upload ───────────────────────────────────────────────────────
# O upload leva ~95 min e não emitia uma linha sequer: o run parecia travado.
# Estes testes fixam o contrato do feedback, que é a razão de o bloco existir.

@test "timeshift cloud: intervalo de progresso cai para 60s quando inválido" {
  unset TIMESHIFT_CLOUD_PROGRESS_INTERVAL
  run timeshift_cloud_progress_interval
  [ "$output" = "60" ]

  TIMESHIFT_CLOUD_PROGRESS_INTERVAL=0 run timeshift_cloud_progress_interval
  [ "$output" = "60" ]

  TIMESHIFT_CLOUD_PROGRESS_INTERVAL=abc run timeshift_cloud_progress_interval
  [ "$output" = "60" ]

  TIMESHIFT_CLOUD_PROGRESS_INTERVAL=15 run timeshift_cloud_progress_interval
  [ "$output" = "15" ]
}

@test "timeshift cloud: bytes e segundos viram unidades legíveis" {
  run timeshift_cloud_human_bytes 512
  [ "$output" = "512B" ]
  run timeshift_cloud_human_bytes 13315844301
  [ "$output" = "12.4GiB" ]
  run timeshift_cloud_human_bytes "não-número"
  [ "$output" = "0B" ]

  run timeshift_cloud_human_secs 45
  [ "$output" = "45s" ]
  run timeshift_cloud_human_secs 1930
  [ "$output" = "32m10s" ]
  run timeshift_cloud_human_secs 5742
  [ "$output" = "1h35m" ]
}

@test "timeshift cloud: linha de progresso traz %, volume, arquivos e ETA" {
  local json='{"message_type":"status","seconds_elapsed":1930,"seconds_remaining":3760,"total_files":128900,"files_done":45231,"total_bytes":39514362675,"bytes_done":13315844301}'

  run timeshift_cloud_progress_line "$json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"33%"* ]]
  [[ "$output" == *"12.4GiB/36.7GiB"* ]]
  [[ "$output" == *"45231/128900 arq"* ]]
  [[ "$output" == *"32m10s decorrido"* ]]
  [[ "$output" == *"ETA 1h02m"* ]]
}

# Durante o scan o restic ainda não sabe o total: uma barra de 0% imóvel seria
# pior que nenhuma. A fase precisa se identificar como scan.
@test "timeshift cloud: fase de scan reporta volume lido em vez de 0%" {
  local json='{"message_type":"status","seconds_elapsed":65,"total_files":0,"files_done":9331,"total_bytes":0,"bytes_done":244055040}'

  run timeshift_cloud_progress_line "$json"

  [[ "$output" == *"escaneando"* ]]
  [[ "$output" == *"9331 arq"* ]]
  [[ "$output" == *"232.7MiB lidos"* ]]
  [[ "$output" != *"0%"* ]]
}

# A velocidade da janela é o que denuncia uma rede que caiu no meio; a média
# desde o início continuaria alta por dezenas de minutos.
@test "timeshift cloud: velocidade usa a janela quando há amostra anterior" {
  local json='{"message_type":"status","seconds_elapsed":1930,"total_files":100,"files_done":50,"total_bytes":39514362675,"bytes_done":13315844301}'

  run timeshift_cloud_progress_line "$json" 12315844301 1870
  local janela="$output"
  run timeshift_cloud_progress_line "$json"
  local media="$output"

  [ "$janela" != "$media" ]
  [[ "$janela" == *"15.8MiB/s"* ]]
}

@test "timeshift cloud: resumo final mostra volume enviado e snapshot" {
  local json='{"message_type":"summary","files_new":12345,"files_changed":234,"data_added":3435973836,"data_added_packed":3221225472,"total_bytes_processed":39514362675,"total_duration":5742.31,"snapshot_id":"a1b2c3d4e5f6"}'

  run timeshift_cloud_summary_line "$json"

  [[ "$output" == *"12345 novo(s), 234 alterado(s)"* ]]
  [[ "$output" == *"3.0GiB enviados"* ]]
  [[ "$output" == *"em 1h35m"* ]]
  [[ "$output" == *"snapshot a1b2c3d4"* ]]
}

# Regressão real: o restic era chamado fora de `log`, então "repository is
# already locked" existia só no terminal. O log do run de 2026-09-03 fecha com
# "retenção remota falhou" e nenhuma pista do motivo.
@test "timeshift cloud: texto não-JSON do restic chega ao log" {
  local saida
  # log() só escreve no terminal fora do modo silencioso; o helper liga QUIET.
  saida="$(QUIET=0 timeshift_cloud_consume_progress \
    <<<'unable to create lock in backend: repository is already locked')"

  [[ "$saida" == *"repository is already locked"* ]]
}

@test "timeshift cloud: heartbeats respeitam o intervalo configurado" {
  local json='{"message_type":"status","seconds_elapsed":10,"total_files":10,"files_done":5,"total_bytes":1000,"bytes_done":500}'
  local saida

  # Três status seguidos, intervalo de 3600s: só o primeiro sai.
  saida="$(printf '%s\n%s\n%s\n' "$json" "$json" "$json" \
    | QUIET=0 TIMESHIFT_CLOUD_PROGRESS_INTERVAL=3600 timeshift_cloud_consume_progress)"

  [ "$(printf '%s\n' "$saida" | grep -c '50%')" -eq 1 ]
}

# A % do restic mede leitura, não envio: a fase final (subir packs) é a mais
# longa e ficaria congelada em "100% · 0B/s", que lê como travamento.
@test "timeshift cloud: 100% de leitura é anunciado como envio ao remoto" {
  local json='{"message_type":"status","seconds_elapsed":4200,"total_files":128900,"files_done":128900,"total_bytes":39514362675,"bytes_done":39514362675}'

  run timeshift_cloud_progress_line "$json"

  [[ "$output" == *"enviando pacotes ao remoto"* ]]
  [[ "$output" == *"36.7GiB lidos"* ]]
  [[ "$output" != *"100%"* ]]
}
