#!/usr/bin/env bats
# tests/series_w_candidates.bats — os 20 steps da Série W (W8–W27) para
# componentes que nenhum gerenciador atualiza, e os helpers compartilhados
# (_native_update, github_latest_release_tag com regex). Todo comando externo é
# stub em $BATS_TEST_TMPDIR/bin e registra a chamada em $CALLS; tarballs,
# perfis e índices são descartáveis. Nada toca a rede, o $HOME real nem o sistema.

load test_helper

setup() {
  load_libs
  local f
  for f in manual_apps tools security lang_other shell editor packages ai; do
    # shellcheck source=/dev/null
    source "${FU_LIB}/steps/${f}.sh"
  done
  log() { printf '%s\n' "$*"; }
  log_raw() { :; }
  log_stream() { cat; }
  remediation() { printf 'REMEDIACAO: %s\n' "$*"; }
  run_logged() { "$@"; }
  export HOME="$BATS_TEST_TMPDIR/home"
  unset XDG_DATA_HOME XDG_CONFIG_HOME XDG_CACHE_HOME ZDOTDIR ZINIT_HOME ANTIDOTE_HOME SDKMAN_DIR
  unset TMUX_PLUGIN_MANAGER_PATH IDF_TOOLS_PATH OLLAMA_MODELS_UPDATE PROTON_GE_KEEP PROTON_GE_DIR
  unset APPIMAGE_DIRS NERD_FONTS_DIR EXPLOITDB_DIR
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export CALLS="$BATS_TEST_TMPDIR/calls" SRV="$BATS_TEST_TMPDIR/srv"
  mkdir -p "$SRV"
  : >"$CALLS"
  STEP_REASON=""
  SUDO_READY=0
  run_network_cmd() { "$@" 2>&1; }
  PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin"
}

# Cria o comando $1 em bin/ que registra "$1 args" em $CALLS e roda o corpo $2.
_rec() {
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$CALLS" "${2:-exit 0}" >"$BATS_TEST_TMPDIR/bin/$1"
  chmod +x "$BATS_TEST_TMPDIR/bin/$1"
}

# curl falso: redirect de /releases/latest em $LATEST_TAG; assets saem de $SRV
# pelo último segmento da URL (falha 22 quando não existe ou está em $CURL_FAIL).
_stub_curl() {
  _rec curl '
out="" url="" w=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "$w" == "%{url_effective}" ]]; then
  [[ -n "${LATEST_TAG:-}" ]] || exit 6
  printf "https://github.com/o/r/releases/tag/%s" "$LATEST_TAG"
  exit 0
fi
f="$SRV/${url##*/}"
[[ -f "$f" && "${CURL_FAIL:-}" != *"${url##*/}"* ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi'
}

# ── helpers compartilhados ────────────────────────────────────────────────────
@test "_native_update: ok, rede e falha" {
  _rec tool 'echo "linha"; exit ${TOOL_RC:-0}'
  run _native_update "tool up" tool up
  [ "$status" -eq 0 ]
  [[ "$output" == *linha* ]]
  run_network_cmd() { return "$RC_WARN"; }
  _native_update "tool up" tool up >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "tool up: rede indisponível" ]
  run_network_cmd() { "$@" 2>&1; }
  status=0
  TOOL_RC=4 _native_update "tool up" tool up >/dev/null || status=$?
  [ "$status" -eq 1 ]
  [ "$STEP_REASON" = "tool up falhou (rc=4)" ]
}

@test "github_latest_release_tag: regex própria aceita tag sem número de versão" {
  _stub_curl
  LATEST_TAG=GE-Proton11-12 run github_latest_release_tag o/r '^GE-Proton[0-9]+-[0-9]+$'
  [ "$output" = GE-Proton11-12 ]
  LATEST_TAG=GE-Proton11-12 run github_latest_release_tag o/r
  [ "$status" -eq "$RC_WARN" ]
}

# ── W8: modelos do Ollama ─────────────────────────────────────────────────────
_stub_ollama() {
  _rec ollama '
case "$1" in
  list) [[ -n "${OL_LIST_FAIL:-}" ]] && { echo "could not connect to ollama app"; exit 1; }
        printf "NAME ID SIZE MODIFIED\n%b" "${OL_MODELS:-}" ;;
  pull) case "$2" in
          local*) echo "Error: pull model manifest: file does not exist"; exit 1 ;;
          ruim*) echo "Error: erro estranho"; exit 1 ;;
          *) echo "success" ;;
        esac ;;
esac'
}

@test "ollama_model_names: tira o cabeçalho" {
  run ollama_model_names "$(printf 'NAME ID\nllama3:8b abc\nqwen:7b def\n')"
  [ "$output" = "$(printf '%s\n' llama3:8b qwen:7b)" ]
}

@test "update_ollama_models: opt-in desligado não chama o ollama" {
  _stub_ollama
  run update_ollama_models
  [ "$status" -eq 0 ]
  [[ "$output" == *"OLLAMA_MODELS_UPDATE=0"* ]]
  [ ! -s "$CALLS" ]
}

@test "update_ollama_models: servidor parado vira RC_WARN; sem modelos é ok" {
  _stub_ollama
  export OLLAMA_MODELS_UPDATE=1
  OL_LIST_FAIL=1 update_ollama_models >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  run update_ollama_models
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum modelo"* ]]
}

@test "update_ollama_models: puxa do registry, pula o local e falha no erro real" {
  _stub_ollama
  export OLLAMA_MODELS_UPDATE=1 OL_MODELS='llama3:8b a 4G x\nlocal-x:1 b 1G y\n'
  run update_ollama_models
  [ "$status" -eq 0 ]
  grep -q 'ollama pull llama3:8b' "$CALLS"
  [[ "$output" == *"local-x:1: modelo local"* ]]
  export OL_MODELS='ruim:1 c 1G z\n'
  update_ollama_models >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "1 modelo(s) do Ollama não renovado(s)" ]
}

@test "update_ollama_models: só rede faltando vira RC_WARN" {
  _stub_ollama
  export OLLAMA_MODELS_UPDATE=1 OL_MODELS='llama3:8b a 4G x\n'
  run_network_cmd() { return "$RC_WARN"; }
  update_ollama_models >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

# ── W9: Proton-GE ─────────────────────────────────────────────────────────────
_ge_setup() {
  GE_DIR="$HOME/.local/share/Steam/compatibilitytools.d"
  mkdir -p "$GE_DIR/GE-Proton10-1" "$GE_DIR/GE-Proton9-20"
  _stub_curl
  export LATEST_TAG=GE-Proton11-12
  local stage="$BATS_TEST_TMPDIR/ge"
  mkdir -p "$stage/GE-Proton11-12"
  echo proton >"$stage/GE-Proton11-12/proton"
  tar -czf "$SRV/GE-Proton11-12-x86_64.tar.gz" -C "$stage" GE-Proton11-12
  (cd "$SRV" && sha512sum GE-Proton11-12-x86_64.tar.gz >GE-Proton11-12-x86_64.sha512sum)
  uname() { echo x86_64; }
}

@test "proton_ge_dir: só onde já existe GE-Proton; PROTON_GE_DIR força" {
  run proton_ge_dir
  [ -z "$output" ]
  mkdir -p "$HOME/.steam/root/compatibilitytools.d/GE-Proton9-1"
  run proton_ge_dir
  [ "$output" = "$HOME/.steam/root/compatibilitytools.d" ]
  mkdir -p "$HOME/outro/GE-Proton1-1"
  PROTON_GE_DIR="$HOME/outro" run proton_ge_dir
  [ "$output" = "$HOME/outro" ]
}

@test "proton_ge_prune_list: keep 0 não remove; keep 1 deixa a mais nova" {
  mkdir -p "$BATS_TEST_TMPDIR/c"/{GE-Proton9-20,GE-Proton10-1,GE-Proton11-12}
  run proton_ge_prune_list "$BATS_TEST_TMPDIR/c" 0
  [ -z "$output" ]
  run proton_ge_prune_list "$BATS_TEST_TMPDIR/c" 1
  [ "$output" = "$(printf '%s\n' GE-Proton10-1 GE-Proton9-20)" ]
}

@test "update_proton_ge: sem GE-Proton e arquitetura sem build" {
  run update_proton_ge
  [[ "$output" == *"Nenhum GE-Proton"* ]]
  _ge_setup
  uname() { echo riscv64; }
  run update_proton_ge
  [ "$status" -eq 0 ]
  [[ "$output" == *"sem build"* ]]
}

@test "update_proton_ge: instala ao lado, confere sha512 e poda com PROTON_GE_KEEP" {
  _ge_setup
  PROTON_GE_KEEP=2 run update_proton_ge
  [ "$status" -eq 0 ]
  [ -f "$GE_DIR/GE-Proton11-12/proton" ]
  [ -d "$GE_DIR/GE-Proton10-1" ]
  [ ! -d "$GE_DIR/GE-Proton9-20" ]
  [ -z "$(compgen -G "$GE_DIR/.full-upgrade-*")" ]
  run update_proton_ge
  [[ "$output" == *"GE-Proton11-12 já instalado"* ]]
}

@test "update_proton_ge: tag indisponível e download falho viram RC_WARN" {
  _ge_setup
  unset LATEST_TAG
  update_proton_ge >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  export LATEST_TAG=GE-Proton11-12
  status=0
  CURL_FAIL=GE-Proton11-12-x86_64.sha512sum update_proton_ge >/dev/null || status=$?
  [ "$status" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "download do GE-Proton11-12 falhou" ]
}

@test "update_proton_ge: sha512 divergente não instala" {
  _ge_setup
  printf '%0128d  GE-Proton11-12-x86_64.tar.gz\n' 0 >"$SRV/GE-Proton11-12-x86_64.sha512sum"
  update_proton_ge >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ ! -d "$GE_DIR/GE-Proton11-12" ]
}

# ── W12: Spicetify ────────────────────────────────────────────────────────────
_stub_spicetify() {
  _rec spicetify '
case "$*" in
  upgrade) exit ${SP_UP_RC:-0} ;;
  "-n apply") printf "%b\n" "${SP_APPLY_OUT:-success}"; exit ${SP_APPLY_RC:-0} ;;
  "-n backup apply") printf "%b\n" "${SP_BACKUP_OUT:-backup ok}"; exit ${SP_BACKUP_RC:-0} ;;
esac'
}

@test "update_spicetify: do pacote só reaplica; do \$HOME também faz upgrade" {
  _stub_spicetify
  run update_spicetify
  [ "$status" -eq 0 ]
  ! grep -q 'spicetify upgrade' "$CALLS"
  mkdir -p "$HOME/.spicetify"
  cp "$BATS_TEST_TMPDIR/bin/spicetify" "$HOME/.spicetify/spicetify"
  PATH="$HOME/.spicetify:$PATH" run update_spicetify
  [ "$status" -eq 0 ]
  grep -q 'spicetify upgrade' "$CALLS"
}

@test "update_spicetify: upgrade falhando interrompe" {
  _stub_spicetify
  mkdir -p "$HOME/.spicetify"
  cp "$BATS_TEST_TMPDIR/bin/spicetify" "$HOME/.spicetify/spicetify"
  PATH="$HOME/.spicetify:$PATH" SP_UP_RC=2 update_spicetify >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
}

@test "update_spicetify: Spotify mudou de versão => backup apply" {
  _stub_spicetify
  SP_APPLY_OUT='error: Spotify version and backup version are mismatched' SP_APPLY_RC=1 run update_spicetify
  [ "$status" -eq 0 ]
  grep -q 'spicetify -n backup apply' "$CALLS"
}

@test "update_spicetify: permissão negada vira TODO; outro erro é fail" {
  _stub_spicetify
  export SP_APPLY_RC=1 SP_BACKUP_RC=1 SP_BACKUP_OUT='open /opt/spotify/Apps: permission denied'
  update_spicetify >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  status=0
  SP_BACKUP_OUT='erro' update_spicetify >/dev/null || status=$?
  [ "$status" -eq 1 ]
}

# ── W13/W14: krew e Helm ──────────────────────────────────────────────────────
@test "krew_installed e update_krew_plugins" {
  run krew_installed
  [ "$status" -ne 0 ]
  _rec kubectl 'exit 0'
  run krew_installed
  [ "$status" -eq 0 ]
  run update_krew_plugins
  [ "$status" -eq 0 ]
  grep -q 'kubectl krew upgrade' "$CALLS"
}

@test "update_helm_plugins: nenhum, todos e pior rc" {
  _rec helm 'case "$1 $2" in "plugin list") printf "%b" "${HELM_LIST:-NAME VERSION\n}" ;; "plugin update") [[ "$3" == quebrado ]] && exit 1 ;; esac; exit 0'
  run update_helm_plugins
  [[ "$output" == *"Nenhum plugin do Helm"* ]]
  HELM_LIST='NAME VERSION\ndiff 3.9\nsecrets 4.6\n' run update_helm_plugins
  [ "$status" -eq 0 ]
  grep -q 'helm plugin update diff' "$CALLS"
  grep -q 'helm plugin update secrets' "$CALLS"
  HELM_LIST='NAME VERSION\nquebrado 1\ndiff 3.9\n' update_helm_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
}

# ── W16: AppImages ────────────────────────────────────────────────────────────
@test "appimage_files: padrão e APPIMAGE_DIRS; symlink não conta" {
  mkdir -p "$HOME/Applications" "$HOME/apps"
  touch "$HOME/Applications/A.AppImage" "$HOME/apps/b.appimage"
  ln -s "$HOME/Applications/A.AppImage" "$HOME/Applications/L.AppImage"
  run appimage_files
  [ "$output" = "$HOME/Applications/A.AppImage" ]
  APPIMAGE_DIRS='~/apps,~/nada' run appimage_files
  [ "$output" = "$HOME/apps/b.appimage" ]
}

@test "update_appimages: em dia, atualiza, sem update info e falha" {
  run update_appimages
  [[ "$output" == *"Nenhum AppImage"* ]]
  mkdir -p "$HOME/Applications"
  touch "$HOME/Applications/"{emdia,velho,manual}.AppImage "$HOME/Applications/velho.AppImage.zs-old"
  _rec appimageupdatetool '
if [[ "$1" == -j ]]; then case "$2" in *emdia*) exit 0 ;; *velho*) exit 1 ;; *) exit 2 ;; esac; fi
exit ${AIU_RC:-0}'
  run update_appimages
  [ "$status" -eq 0 ]
  [[ "$output" == *"AppImages: 1 atualizado(s), 1 sem update automático, 0 falha(s)."* ]]
  [ ! -e "$HOME/Applications/velho.AppImage.zs-old" ]
  AIU_RC=1 update_appimages >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

# ── W17: Nerd Fonts ───────────────────────────────────────────────────────────
_nf_setup() {
  NF="$HOME/.local/share/fonts/NerdFonts"
  mkdir -p "$NF/JetBrainsMono" "$NF/Sem"
  touch "$NF/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf" "$NF/Sem/SemNerdFont-Regular.ttf"
  _stub_curl
  export LATEST_TAG=v3.5.1
  local stage="$BATS_TEST_TMPDIR/nf"
  mkdir -p "$stage"
  touch "$stage/JetBrainsMonoNerdFont-Bold.ttf"
  tar -cJf "$SRV/JetBrainsMono.tar.xz" -C "$stage" JetBrainsMonoNerdFont-Bold.ttf
  (cd "$SRV" && sha256sum JetBrainsMono.tar.xz >SHA-256.txt)
  _rec fc-cache 'exit 0'
}

@test "nerd_font_families: só subdiretórios com NerdFont" {
  _nf_setup
  mkdir -p "$NF/Vazio"
  run nerd_font_families
  [ "$output" = "$(printf '%s\n' JetBrainsMono Sem)" ]
}

@test "update_nerd_fonts: nada a gerenciar e índice indisponível" {
  run update_nerd_fonts
  [[ "$output" == *"Nenhuma família"* ]]
  _nf_setup
  unset LATEST_TAG
  update_nerd_fonts >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  export LATEST_TAG=v3.5.1
  status=0
  CURL_FAIL=SHA-256.txt update_nerd_fonts >/dev/null || status=$?
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_nerd_fonts: instala sem marcador, grava a versão e roda fc-cache" {
  _nf_setup
  run update_nerd_fonts
  [ "$status" -eq 0 ]
  [ -f "$NF/JetBrainsMono/JetBrainsMonoNerdFont-Bold.ttf" ]
  [ ! -f "$NF/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf" ]
  [ "$(cat "$NF/JetBrainsMono/.nf-version")" = 3.5.1 ]
  [[ "$output" == *"Sem: o release 3.5.1 não tem Sem.tar.xz"* ]]
  grep -q fc-cache "$CALLS"
  run update_nerd_fonts
  [[ "$output" == *"JetBrainsMono: em dia (3.5.1)"* ]]
}

@test "update_nerd_fonts: checksum divergente mantém; download falho é warn" {
  _nf_setup
  printf '%064d  JetBrainsMono.tar.xz\n' 0 >"$SRV/SHA-256.txt"
  update_nerd_fonts >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ -f "$NF/JetBrainsMono/JetBrainsMonoNerdFont-Regular.ttf" ]
  (cd "$SRV" && sha256sum JetBrainsMono.tar.xz >SHA-256.txt)
  status=0
  CURL_FAIL=JetBrainsMono.tar.xz update_nerd_fonts >/dev/null || status=$?
  [ "$status" -eq "$RC_WARN" ]
}

# ── W18: KiCad PCM ────────────────────────────────────────────────────────────
_kicad_setup() {
  local cfg="$HOME/.config/kicad/10.0" cache="$HOME/.cache/kicad/10.0/pcm"
  mkdir -p "$cfg" "$cache/r1" "$cache/r2"
  cat >"$cfg/installed_packages.json" <<'JSON'
{"packages":[
 {"current_version":"1.0","pinned":false,"repository_id":"r1","package":{"identifier":"a.plugin"}},
 {"current_version":"2.0","pinned":false,"repository_id":"r1","package":{"identifier":"b.plugin"}},
 {"current_version":"1.0","pinned":true,"repository_id":"r1","package":{"identifier":"c.fixo"}},
 {"current_version":"1.0","pinned":false,"repository_id":"r2","package":{"identifier":"d.fora"}}]}
JSON
  echo '{"packages":{"url":"https://repo.example/r1-packages.json"}}' >"$cache/r1/repository.json"
  echo '{"packages":{"url":"https://repo.example/r2-packages.json"}}' >"$cache/r2/repository.json"
  cat >"$SRV/r1-packages.json" <<'JSON'
{"packages":[
 {"identifier":"a.plugin","versions":[{"version":"1.0","status":"stable"},{"version":"1.2","status":"stable"},{"version":"9.9","status":"deprecated"}]},
 {"identifier":"b.plugin","versions":[{"version":"2.0","status":"stable"}]}]}
JSON
  _stub_curl
}

@test "kicad_pcm_installed e kicad_pcm_latest" {
  _kicad_setup
  run kicad_pcm_installed "$HOME/.config/kicad/10.0/installed_packages.json"
  [ "$output" = "$(printf 'a.plugin\t1.0\tr1\nb.plugin\t2.0\tr1\nd.fora\t1.0\tr2')" ]
  run kicad_pcm_latest "$SRV/r1-packages.json" a.plugin
  [ "$output" = 1.2 ]
}

@test "check_kicad_plugins: sem PCM; versão nova vira TODO; repo fora do ar só avisa" {
  run check_kicad_plugins
  [[ "$output" == *"Nenhum pacote do PCM"* ]]
  _kicad_setup
  fetch_network_text() { curl "$@"; }
  [ "$(kicad_pcm_config_dir)" = "$HOME/.config/kicad/10.0" ]
  check_kicad_plugins >"$BATS_TEST_TMPDIR/out" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  grep -q 'a.plugin 1.0 → 1.2' "$BATS_TEST_TMPDIR/out"
  grep -q 'b.plugin: em dia' "$BATS_TEST_TMPDIR/out"
  grep -q 'repositório r2 indisponível' "$BATS_TEST_TMPDIR/out"
  [ "$STEP_REASON" = "1 plugin(s) do KiCad com versão nova no PCM" ]
}

@test "check_kicad_plugins: tudo em dia => 0" {
  _kicad_setup
  fetch_network_text() { curl "$@"; }
  sed -i 's/"1.2"/"1.0"/' "$SRV/r1-packages.json"
  run check_kicad_plugins
  [ "$status" -eq 0 ]
}

# ── W23: arkenfox ─────────────────────────────────────────────────────────────
_arkenfox_profile() {
  local d="$HOME/.mozilla/firefox/$1"
  mkdir -p "$d"
  echo "/* arkenfox user.js */" >"$d/user.js"
  printf '#!/usr/bin/env bash\necho "updater $PWD $*" >>"%s"\nexit ${ARK_RC:-0}\n' "$CALLS" >"$d/updater.sh"
  chmod +x "$d/updater.sh"
}

@test "arkenfox_profiles: só perfis com user.js do arkenfox e updater.sh" {
  _arkenfox_profile abc.default
  mkdir -p "$HOME/.mozilla/firefox/outro"
  echo "user_pref" >"$HOME/.mozilla/firefox/outro/user.js"
  run arkenfox_profiles
  [ "$output" = "$HOME/.mozilla/firefox/abc.default" ]
}

@test "update_arkenfox: nenhum, sucesso no perfil e falha" {
  run update_arkenfox
  [[ "$output" == *"Nenhum perfil"* ]]
  _arkenfox_profile abc.default
  run update_arkenfox
  [ "$status" -eq 0 ]
  grep -q "updater $HOME/.mozilla/firefox/abc.default -s -u" "$CALLS"
  ARK_RC=1 update_arkenfox >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$STEP_REASON" = "arkenfox: updater.sh falhou em algum perfil" ]
}

# ── W15: bases de arquivos ────────────────────────────────────────────────────
@test "update_file_databases: .files presente, pkgfile fora do timer e nenhum" {
  export PACMAN_SYNC_DIR="$BATS_TEST_TMPDIR/sync"
  mkdir -p "$PACMAN_SYNC_DIR"
  _rec sudo 'exec "$@"'
  _rec pacman 'exit 0'
  _rec systemctl 'exit 3'
  run update_file_databases
  [[ "$output" == *"Sem base .files"* ]]
  touch "$PACMAN_SYNC_DIR/core.files"
  _rec pkgfile 'exit ${PKGF_RC:-0}'
  run update_file_databases
  [ "$status" -eq 0 ]
  grep -q 'pacman -Fy' "$CALLS"
  grep -q 'pkgfile --update' "$CALLS"
  PKGF_RC=1 update_file_databases >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  _rec systemctl 'exit 0'
  run pkgfile_needs_update
  [ "$status" -ne 0 ]
}

# ── W20/W21/W22: nuclei, Exploit-DB, rkhunter ─────────────────────────────────
@test "update_nuclei_templates: chama -update-templates" {
  _rec nuclei 'exit 0'
  run update_nuclei_templates
  [ "$status" -eq 0 ]
  grep -q 'nuclei -update-templates -disable-update-check' "$CALLS"
}

@test "update_exploitdb: sem clone, gravável, via sudo e sem sudo" {
  _rec searchsploit 'exit 0'
  _rec sudo 'exec "$@"'
  EXPLOITDB_DIR="$HOME/nada" run update_exploitdb
  [ "$status" -eq 0 ]
  mkdir -p "$HOME/exploitdb/.git"
  run update_exploitdb
  [ "$status" -eq 0 ]
  grep -q '^searchsploit -u' "$CALLS"
  chmod 555 "$HOME/exploitdb"
  update_exploitdb >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  SUDO_READY=1 run update_exploitdb
  chmod 755 "$HOME/exploitdb"
  [ "$status" -eq 0 ]
  grep -q '^sudo searchsploit -u' "$CALLS"
}

@test "update_rkhunter: update ok/atualizado, mirror fora e propupd falhando" {
  _rec sudo 'exec "$@"'
  _rec rkhunter 'case "$1" in --update) echo "Checking file x [ Updated ]"; exit ${RK_UP_RC:-0} ;; --propupd) exit ${RK_PROP_RC:-0} ;; esac'
  RK_UP_RC=2 run update_rkhunter
  [ "$status" -eq 0 ]
  grep -q 'rkhunter --propupd' "$CALLS"
  RK_UP_RC=1 update_rkhunter >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  status=0
  RK_PROP_RC=1 update_rkhunter >/dev/null || status=$?
  [ "$status" -eq 1 ]
  [ "$STEP_REASON" = "rkhunter --propupd falhou" ]
}

# ── W19: ESP-IDF ──────────────────────────────────────────────────────────────
_idf_json='{"VERSIONS":[{"name":"latest"},{"name":"v6.1.1"},{"name":"v6.0.2"},{"name":"v6.0.1"},{"name":"v6.0"},{"name":"v5.5.3"},{"name":"v6.2-beta1"}]}'

@test "esp_idf_installed, esp_idf_published e esp_idf_latest_in_series" {
  mkdir -p "$HOME/.espressif/v6.0.1/esp-idf" "$HOME/.espressif/v5.5" "$HOME/.espressif/tools"
  run esp_idf_installed
  [ "$output" = "$(printf '%s\n' v5.5 v6.0.1)" ]
  run esp_idf_published "$_idf_json"
  [ "$output" = "$(printf '%s\n' v5.5.3 v6.0 v6.0.1 v6.0.2 v6.1.1)" ]
  run esp_idf_latest_in_series v6.0.1 "$(esp_idf_published "$_idf_json")"
  [ "$output" = v6.0.2 ]
}

@test "check_esp_idf: patch novo na série vira TODO e série nova só é informada" {
  mkdir -p "$HOME/.espressif/v6.0.1"
  _rec eim
  fetch_network_text() { printf '%s\n' "$_idf_json"; }
  check_esp_idf >"$BATS_TEST_TMPDIR/out" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  grep -q 'patch v6.0.2 disponível' "$BATS_TEST_TMPDIR/out"
  grep -q 'Série mais nova publicada: v6.1.1' "$BATS_TEST_TMPDIR/out"
  grep -qF "REMEDIACAO: $BATS_TEST_TMPDIR/bin/eim install -i v6.0.2  # depois: $BATS_TEST_TMPDIR/bin/eim remove <versão antiga>" "$BATS_TEST_TMPDIR/out"
}

@test "esp_idf_series_heads: só a maior versão de cada série, na ordem das séries" {
  run esp_idf_series_heads "$(printf '%s\n' v5.5 v5.5.3 v6.0.1 v6.0.3 v6.1)"
  [ "$output" = "$(printf '%s\n' v5.5.3 v6.0.3 v6.1)" ]
  run esp_idf_series_heads v6.0.1
  [ "$output" = v6.0.1 ]
}

@test "check_esp_idf: patch antigo ao lado do novo não mantém o TODO" {
  # O EIM instala o patch novo ao lado do antigo; medir a v6.0.1 deixava o step
  # em todo para sempre mesmo com a v6.0.2 instalada.
  mkdir -p "$HOME/.espressif/v6.0.1" "$HOME/.espressif/v6.0.2"
  fetch_network_text() { printf '%s\n' "$_idf_json"; }
  run check_esp_idf
  [ "$status" -eq 0 ]
  [[ "$output" == *"v6.0.2: em dia na série"* ]]
  [[ "$output" != *"v6.0.1: patch"* ]]
  [[ "$output" == *"Superadas por um patch mais novo da mesma série: v6.0.1"* ]]
}

@test "esp_idf_eim_bin: PATH, eimPath do eim_idf.json da GUI e ausente" {
  # PATH mínimo (só o jq) nas chamadas, para o eim do host não vazar no teste.
  local min="$BATS_TEST_TMPDIR/min"
  mkdir -p "$min" "$HOME/.espressif/tools" "$HOME/.espressif/eim_gui"
  ln -s "$(command -v jq)" "$min/jq"
  PATH="$min" run esp_idf_eim_bin
  [ -z "$output" ]
  printf '#!/bin/sh\n' >"$HOME/.espressif/eim_gui/eim"
  chmod +x "$HOME/.espressif/eim_gui/eim"
  printf '{"eimPath":"%s"}\n' "$HOME/.espressif/eim_gui/eim" >"$HOME/.espressif/tools/eim_idf.json"
  PATH="$min" run esp_idf_eim_bin
  [ "$output" = "$HOME/.espressif/eim_gui/eim" ]
  _rec eim
  PATH="$BATS_TEST_TMPDIR/bin:$min" run esp_idf_eim_bin
  [ "$output" = "$BATS_TEST_TMPDIR/bin/eim" ]
}

@test "check_esp_idf: sem EIM CLI a remediação aponta o eim-cli/GUI" {
  mkdir -p "$HOME/.espressif/v6.0.1"
  esp_idf_eim_bin() { :; }
  fetch_network_text() { printf '%s\n' "$_idf_json"; }
  check_esp_idf >"$BATS_TEST_TMPDIR/out" || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  grep -qF 'REMEDIACAO: eim install -i v6.0.2  # EIM CLI fora do PATH: instale o eim-cli ou use a GUI do EIM' "$BATS_TEST_TMPDIR/out"
}

@test "check_esp_idf: nada instalado, em dia, índice fora e índice vazio" {
  run check_esp_idf
  [[ "$output" == *"Nenhum ESP-IDF"* ]]
  mkdir -p "$HOME/.espressif/v6.1.1"
  fetch_network_text() { printf '%s\n' "$_idf_json"; }
  run check_esp_idf
  [ "$status" -eq 0 ]
  [[ "$output" == *"v6.1.1: em dia"* ]]
  fetch_network_text() { return "$RC_WARN"; }
  check_esp_idf >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  fetch_network_text() { echo '{}'; }
  status=0
  check_esp_idf >/dev/null || status=$?
  [ "$status" -eq "$RC_WARN" ]
}

# ── W25: gerenciadores de toolchain ───────────────────────────────────────────
@test "update_toolchain_managers: nenhum" {
  run update_toolchain_managers
  [[ "$output" == *"Nenhum gerenciador de toolchain"* ]]
}

@test "update_toolchain_managers: self-update só do \$HOME; sdkman; pior rc" {
  _rec juliaup 'exit 0'
  _rec elan 'exit 0'
  _rec cs 'exit ${CS_RC:-0}'
  mkdir -p "$HOME/.elan/bin"
  mv "$BATS_TEST_TMPDIR/bin/elan" "$HOME/.elan/bin/elan"
  mkdir -p "$HOME/.sdkman/bin"
  printf 'sdk() { echo "sdk $*" >>"%s"; }\n' "$CALLS" >"$HOME/.sdkman/bin/sdkman-init.sh"
  export PATH="$HOME/.elan/bin:$PATH"
  run toolchain_managers
  [ "$output" = "$(printf '%s\n' juliaup elan coursier sdkman)" ]
  run update_toolchain_managers
  [ "$status" -eq 0 ]
  ! grep -q 'juliaup self update' "$CALLS"
  grep -q 'juliaup update' "$CALLS"
  grep -q 'elan self update' "$CALLS"
  grep -q 'elan update' "$CALLS"
  grep -q 'cs update' "$CALLS"
  grep -q 'sdk selfupdate' "$CALLS"
  grep -q 'sdk update' "$CALLS"
  CS_RC=1 update_toolchain_managers >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
}

# ── W26: Composer ─────────────────────────────────────────────────────────────
@test "composer_global_json e update_composer_global" {
  mkdir -p "$HOME/.config/composer"
  _rec composer 'case "$*" in "global config home --quiet") echo "$HOME/.config/composer" ;; esac; exit 0'
  run composer_global_json
  [ -z "$output" ]
  echo '{}' >"$HOME/.config/composer/composer.json"
  run composer_global_json
  [ "$output" = "$HOME/.config/composer/composer.json" ]
  run update_composer_global
  [ "$status" -eq 0 ]
  grep -q 'composer global update --no-interaction --no-progress' "$CALLS"
}

# ── W10/W11/W24: tmux, fish e gerenciadores Zsh ───────────────────────────────
@test "tpm_dir: TMUX_PLUGIN_MANAGER_PATH, ~/.tmux e XDG" {
  run tpm_dir
  [ -z "$output" ]
  mkdir -p "$HOME/.config/tmux/plugins/tpm/bin"
  printf '#!/usr/bin/env bash\necho "tpm $*" >>"%s"\n' "$CALLS" >"$HOME/.config/tmux/plugins/tpm/bin/update_plugins"
  chmod +x "$HOME/.config/tmux/plugins/tpm/bin/update_plugins"
  run tpm_dir
  [ "$output" = "$HOME/.config/tmux/plugins/tpm" ]
  TMUX_PLUGIN_MANAGER_PATH="$HOME/.config/tmux/plugins/" run tpm_dir
  [ "$output" = "$HOME/.config/tmux/plugins/tpm" ]
  run update_tmux_plugins
  [ "$status" -eq 0 ]
  grep -q 'tpm all' "$CALLS"
}

@test "update_tmux_plugins: sem tpm" {
  run update_tmux_plugins
  [[ "$output" == *"tpm não encontrado"* ]]
}

@test "fisher_installed e update_fisher_plugins" {
  run fisher_installed
  [ "$status" -ne 0 ]
  _rec fish 'exit 0'
  run fisher_installed
  [ "$status" -eq 0 ]
  run update_fisher_plugins
  [ "$status" -eq 0 ]
  grep -q 'fish -c fisher update' "$CALLS"
}

@test "update_zsh_plugin_managers: nenhum" {
  run update_zsh_plugin_managers
  [[ "$output" == *"Nenhum gerenciador de plugin Zsh"* ]]
}

@test "update_zsh_plugin_managers: zinit, antidote e sheldon" {
  mkdir -p "$HOME/.local/share/zinit/zinit.git" "$HOME/.antidote"
  touch "$HOME/.local/share/zinit/zinit.git/zinit.zsh" "$HOME/.antidote/antidote.zsh"
  _rec zsh 'exit ${ZSH_RC:-0}'
  _rec sheldon 'exit 0'
  run zsh_plugin_managers
  [ "$output" = "$(printf '%s\n' zinit antidote sheldon)" ]
  run update_zsh_plugin_managers
  [ "$status" -eq 0 ]
  grep -q 'zinit self-update && zinit update --all --quiet' "$CALLS"
  grep -q 'antidote update' "$CALLS"
  grep -q 'sheldon lock --update' "$CALLS"
  ZSH_RC=1 update_zsh_plugin_managers >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
}

# ── W27: nvim-treesitter ──────────────────────────────────────────────────────
@test "treesitter_installed e update_treesitter_parsers: ok, rede, versão desconhecida e falha" {
  run treesitter_installed
  [ "$status" -ne 0 ]
  mkdir -p "$HOME/.local/share/nvim/lazy/nvim-treesitter"
  run treesitter_installed
  [ "$status" -eq 0 ]
  _rec nvim 'grep -q "require, .nvim-treesitter." "${3#luafile }" || exit 9; echo "Installed parser lua"; exit ${NVIM_RC:-0}'
  run update_treesitter_parsers
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installed parser lua"* ]]
  NVIM_RC=3 update_treesitter_parsers >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  status=0
  NVIM_RC=1 update_treesitter_parsers >/dev/null || status=$?
  [ "$status" -eq 1 ]
  run_network_cmd() { return "$RC_WARN"; }
  status=0
  update_treesitter_parsers >/dev/null || status=$?
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_proton_ge: aarch64 usa o asset da arquitetura" {
  _ge_setup
  uname() { echo aarch64; }
  export LATEST_TAG=GE-Proton11-12
  update_proton_ge >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  grep -q 'GE-Proton11-12-aarch64.tar.gz' "$CALLS"
}
