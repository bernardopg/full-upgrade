#!/usr/bin/env bash
# lib/steps/doctor/boot.sh — auditorias de boot/firmware: systemd-boot, fwupd security e tempo de boot.
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)



# Nomes dos atributos ✘ da tabela do `fwupdmgr security`, um por linha e sem
# repetição. Serve para resumir a tabela (~55 linhas) no terminal sem perder o
# que é acionável. Ignora o bloco de histórico no fim da saída (linhas
# prefixadas por data): ele também usa ✘, mas descreve eventos passados, não
# atributos do host. Puro/testável.
fwupd_security_failed_attrs() {
  local output="$1"
  printf '%s\n' "$output" \
    | grep '✘' \
    | grep -vE '^[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}' \
    | sed -E 's/.*✘[[:space:]]*//; s/:.*$//; s/[[:space:]]+$//' \
    | awk 'NF && !seen[$0]++'
}



# Verdadeiro quando um HSI:1 é causado somente pelo atributo introduzido no
# fwupd 2.1.7 para lock de MTD, mas o firmware/hardware não fornece os dados
# necessários. Isso é uma lacuna de medição ("not-supported"/"missing-data"),
# não uma regressão de segurança da máquina. Qualquer outro ✘ em HSI-2 mantém o
# warning. Puro/testável.
fwupd_hsi_only_mtd_measurement_gap() {
  local output="$1" hsi_level="$2"
  [[ "$hsi_level" == "1" ]] || return 1

  local failures
  failures="$(
    printf '%s\n' "$output" | _strip_ansi | awk '
      /^HSI-2([[:space:]]|$)/ { in_hsi2=1; next }
      /^HSI-[0-9]+([[:space:]]|$)/ { if (in_hsi2) exit }
      in_hsi2 && /✘/ { print }
    '
  )"
  [[ -n "${failures//[[:space:]]/}" ]] || return 1

  local others
  others="$(grep -viE 'Locked MTD.*(not supported|não suportado)' <<<"$failures")"
  [[ -z "${others//[[:space:]]/}" ]]
}


doctor_fwupd_security() {
  if ! has fwupdmgr; then
    log "  fwupdmgr não instalado."
    return 0
  fi

  local output rc
  output="$(fwupdmgr security 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc != 0 )); then
    log "  fwupdmgr security retornou código ${rc}:"
    printf '%s\n' "$output" | grep -v '^$' | log_out || true
    return "$RC_WARN"
  fi

  # A tabela completa já foi para o arquivo via log_raw acima. Repeti-la no
  # terminal custava ~50 linhas por run, quase todas atributos ✔ sem ação
  # possível — o sinal (nível HSI + itens ✘) sai resumido abaixo.
  local attr_ok failed_attrs
  attr_ok="$(grep -c '✔' <<<"$output" || true)"
  failed_attrs="$(fwupd_security_failed_attrs "$output")"
  log "  fwupd security: ${attr_ok} atributo(s) ✔ (tabela completa no log)."
  if [[ -n "$failed_attrs" ]]; then
    # `paste -d', '` trataria , e espaço como delimitadores alternados; o join
    # tem que ser feito com um separador só.
    log "  Sem suporte neste hardware: $(paste -sd',' - <<<"$failed_attrs" | sed 's/,/, /g')"
  fi

  # O nível HSI agregado (0–4) é o sinal de verdade. O sufixo "!" indica apenas
  # que há medições de runtime presentes (HSI-Runtime), não insegurança. E os
  # marcadores "✘" em sub-itens são esperados mesmo em níveis altos (atributos
  # não suportados/não aplicáveis no hardware), então NÃO devem disparar aviso
  # por si só. Critério: avisar somente quando o nível agregado é baixo (< 2).
  local hsi_level
  hsi_level="$(printf '%s\n' "$output" | grep -oiE 'HSI:[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"

  if [[ -n "$hsi_level" ]]; then
    if (( hsi_level < 2 )); then
      if fwupd_hsi_only_mtd_measurement_gap "$output" "$hsi_level"; then
        log "  fwupd security: HSI:1 limitado apenas por Locked MTD sem suporte/dados no fwupd 2.1.7; postura de firmware inalterada."
        return 0
      fi
      STEP_REASON="nível HSI baixo (HSI:${hsi_level} de 4)"
      log "  fwupd security: nível HSI:${hsi_level} abaixo do recomendado (>= 2)."
      return "$RC_WARN"
    fi
    log "  fwupd security: HSI:${hsi_level} de 4 (aceitável). Marcadores ✘ em sub-itens são normais."
    return 0
  fi

  # Sem nível HSI legível (formato inesperado): cair para heurística de falha.
  if grep -q '✘' <<<"$output"; then
    STEP_REASON="fwupd security reportou falha(s) sem nível HSI legível"
    return "$RC_WARN"
  fi
  return 0
}


# Extrai um campo do output de `bootctl status` (recebido em $1).
# campo "linux" / "initrd" => primeiro caminho; "title" => título da entrada padrão.
bootctl_status_field() {
  local out="$1" field="$2"
  case "$field" in
    linux | initrd)
      printf '%s\n' "$out" | awk -v field="$field" '
        $1 == field ":" { path=$2; gsub(/\/+/, "/", path); print path; exit }
      '
      ;;
    title)
      printf '%s\n' "$out" | awk '/Default Boot Loader Entry:/{f=1} f && /^[[:space:]]+title:/{print $2" "$3" "$4; exit}'
      ;;
  esac
}



doctor_boot_health() {
  if ! has bootctl; then
    log "  bootctl não encontrado; pulando."
    return 0
  fi

  if ! _doctor_sudo_ok; then
    log "  Checagem de boot requer sudo sem prompt; pulando (valide o sudo para auditar o ESP)."
    return 0
  fi

  if ! sudo -n bootctl is-installed >/dev/null 2>&1; then
    log "  systemd-boot não instalado no ESP; pulando."
    return 0
  fi

  local output rc status=0

  # bootctl status — extrair entrada padrão e estado
  output="$(sudo -n bootctl status 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    log "  bootctl status retornou código ${rc}."
    return "$RC_WARN"
  fi

  # Entrada padrão e kernel/initrd
  local default_entry linux_path initrd_path
  default_entry="$(bootctl_status_field "$output" title)"
  linux_path="$(bootctl_status_field "$output" linux)"
  initrd_path="$(bootctl_status_field "$output" initrd)"

  log "  systemd-boot instalado. Entrada padrão: ${default_entry:-desconhecida}"

  # Verificar presença dos arquivos kernel e initrd no ESP
  local missing_files=()
  if [[ -n "$linux_path" ]]; then
    if ! sudo -n test -f "$linux_path" 2>/dev/null; then
      missing_files+=("kernel: ${linux_path}")
    else
      log "  kernel OK: ${linux_path}"
    fi
  fi
  if [[ -n "$initrd_path" ]]; then
    if ! sudo -n test -f "$initrd_path" 2>/dev/null; then
      missing_files+=("initrd: ${initrd_path}")
    else
      log "  initrd OK: ${initrd_path}"
    fi
  fi

  if (( ${#missing_files[@]} > 0 )); then
    log "  AVISO: arquivo(s) de boot ausente(s) no ESP:"
    for f in "${missing_files[@]}"; do
      log "    ${f}"
    done
    status="$RC_TODO"
  fi

  # Fallback initramfs
  local fallback_path
  fallback_path="$(printf '%s\n' "$output" | awk '/^\s+initrd:/{p=1; next} p && /^\s+initrd:/{print $2; exit} p && /^\s+linux:/{exit}' | head -1)"
  if [[ -z "$fallback_path" ]]; then
    # heurística: substituir initramfs-linux.img → initramfs-linux-fallback.img
    if [[ -n "$initrd_path" ]]; then
      fallback_path="${initrd_path/initramfs-linux.img/initramfs-linux-fallback.img}"
      [[ "$fallback_path" == "$initrd_path" ]] && fallback_path=""
    fi
  fi
  if [[ -n "$fallback_path" ]]; then
    if sudo -n test -f "$fallback_path" 2>/dev/null; then
      log "  fallback initramfs OK: ${fallback_path}"
    else
      log "  AVISO: fallback initramfs ausente: ${fallback_path}"
      log "  Regenere com: mkinitcpio -P"
      (( status == 0 )) && status="$RC_TODO"
    fi
  fi

  # Espaço livre no ESP
  local esp_mount esp_avail_pct esp_avail
  esp_mount="$(findmnt -n -o TARGET /boot 2>/dev/null || true)"
  if [[ -z "$esp_mount" ]]; then
    esp_mount="$(findmnt -n -o TARGET --target /boot/efi 2>/dev/null || true)"
  fi
  if [[ -n "$esp_mount" ]]; then
    esp_avail="$(df -h "$esp_mount" 2>/dev/null | awk 'NR==2{print $4}')"
    esp_avail_pct="$(df "$esp_mount" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print 100-$5}')"
    log "  ESP (${esp_mount}): ${esp_avail} livre (${esp_avail_pct}% disponível)"
    if [[ -n "$esp_avail_pct" ]] && (( esp_avail_pct < 20 )); then
      log "  AVISO: ESP com menos de 20% livre — risco de falha na atualização do boot loader."
      status="$RC_WARN"
    fi
  fi

  return "$status"
}



# F4 — tempo de boot: total via systemd-analyze + piores units (blame).
# RC_WARN se o tempo total exceder BOOT_TIME_WARN_S ou se o segmento loader
# (menu do bootloader) exceder BOOT_LOADER_WARN_S.
doctor_boot_time() {
  if ! has systemd-analyze; then
    log "  systemd-analyze não disponível; pulando."
    return 0
  fi

  # Em container/sistema sem boot completo, systemd-analyze falha — trata limpo.
  local time_out
  time_out="$(systemd-analyze time 2>/dev/null || true)"
  if [[ -z "${time_out//[[:space:]]/}" ]]; then
    log "  systemd-analyze sem dados de boot (container?); pulando."
    return 0
  fi
  # Via `log`, uma linha por vez: o `printf | tee` que havia aqui escrevia na
  # coluna 0, ignorava --quiet e não respeitava a largura do terminal.
  local _bt_line
  while IFS= read -r _bt_line; do
    [[ -n "${_bt_line//[[:space:]]/}" ]] && log "  ${_bt_line}"
  done <<< "$time_out"

  # "Startup finished in ... = 12.345s" — pega o total após o último '='.
  local total_str total_s warn_s
  total_str="$(printf '%s\n' "$time_out" | sed -nE 's/.*=[[:space:]]*//p' | head -1)"
  [[ -z "$total_str" ]] && total_str="$time_out"
  total_s="$(systemd_time_to_seconds "$total_str")"
  warn_s="${BOOT_TIME_WARN_S:-60}"

  # Segmento loader = menu/tempo do bootloader (GRUB_TIMEOUT, sd-boot, UEFI).
  # Lento aí é tempo parado antes de qualquer progresso visível — diferente de
  # units lentas no userspace. Limite próprio (BOOT_LOADER_WARN_S).
  local loader_warn_s="${BOOT_LOADER_WARN_S:-10}"
  local loader_s
  loader_s="$(systemd_time_segment_seconds "$time_out" loader)"

  # Top 5 piores units (blame).
  if has systemd-analyze; then
    local blame
    blame="$(systemd-analyze blame --no-pager 2>/dev/null | head -5 || true)"
    if [[ -n "${blame//[[:space:]]/}" ]]; then
      log "  Piores units no boot (top 5):"
      printf '%s\n' "$blame" | log_stream
    fi
  fi

  local -a reasons=()
  if [[ "$total_s" =~ ^[0-9]+$ ]] && (( total_s > warn_s )); then
    reasons+=("boot ~${total_s}s acima do limite (${warn_s}s)")
  fi
  if [[ -n "$loader_s" ]] && awk -v a="$loader_s" -v b="$loader_warn_s" 'BEGIN { exit !(a + 0 > b + 0) }'; then
    log "  ${C_YELLOW}Segmento loader (menu do bootloader) levou ~${loader_s}s (limite ${loader_warn_s}s) — verifique GRUB_TIMEOUT (/etc/default/grub) ou o timeout do bootloader.${C_RESET}"
    reasons+=("loader ~${loader_s}s acima do limite (${loader_warn_s}s)")
  fi
  if (( ${#reasons[@]} > 0 )); then
    local reason_line
    for reason_line in "${reasons[@]}"; do
      log "  ${C_YELLOW}${reason_line}.${C_RESET}"
    done
    STEP_REASON="${reasons[*]}"
    return "$RC_WARN"
  fi

  log "  Tempo de boot dentro do limite (~${total_s}s ≤ ${warn_s}s; loader ~${loader_s:-n/d}s ≤ ${loader_warn_s}s)."
  return 0
}


# Puro/testável: extrai da saída de `systemd-analyze time` os segundos de um
# segmento nomeado (firmware|loader|kernel|userspace), como "16.287s (loader)".
# Imprime o valor float cru (sem arredondar); vazio se o segmento não existir
# na linha (ex.: firmware costuma estar ausente em VMs).
systemd_time_segment_seconds() {
  local line="$1" segment="$2" raw
  raw="$(sed -nE "s/.*[^0-9.]([0-9]+(\\.[0-9]+)?)s[[:space:]]*\\(${segment}\\).*/\\1/p" <<< "$line" | head -n 1)"
  printf '%s' "$raw"
}
