#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  source "${FU_LIB}/config.sh"
  source "${FU_LIB}/steps/artcraft.sh"
  source "${FU_LIB}/steps/tools.sh"
  source "${FU_LIB}/steps/doctor/packages.sh"
  source "${FU_LIB}/tray.sh"
  export HOME="${BATS_TEST_TMPDIR}/home"
  export ARTCRAFT_DIR="$HOME/development/artcraft"
  export ARTCRAFT_FIXTURES="${BATS_TEST_TMPDIR}/fixtures"
  export XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config"
  export XDG_CACHE_HOME="${BATS_TEST_TMPDIR}/cache"
  export PYTHONPATH="${FU_ROOT}/tests/fixtures/artcraft"
  export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == clone ]]; then
  mkdir -p "${@: -1}/.git"
else
  printf '%040d\n' 1
fi
SH
  cat > "${BATS_TEST_TMPDIR}/bin/desktop-file-validate" <<'SH'
#!/usr/bin/env bash
[[ ${ARTCRAFT_DESKTOP_FAIL:-0} != 1 ]]
SH
  for command in update-mime-database update-desktop-database gtk-update-icon-cache; do
    cat > "${BATS_TEST_TMPDIR}/bin/$command" <<'SH'
#!/usr/bin/env bash
[[ ${ARTCRAFT_CACHE_FAIL:-0} != 1 ]]
SH
  done
  chmod +x "${BATS_TEST_TMPDIR}"/bin/*
}

fixture() {
  python3 "${FU_ROOT}/tests/artcraft_fixture.py" "$ARTCRAFT_DIR" "$ARTCRAFT_FIXTURES" "$@"
}

release_field() {
  python3 - "$ARTCRAFT_FIXTURES/$1.json" "$2" "$3" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1]); d = json.loads(p.read_text())
d[sys.argv[2]] = json.loads(sys.argv[3]); p.write_text(json.dumps(d))
PY
}

@test "Artcraft: atualiza os sete apps, preserva clones, MIME e comandos MCP" {
  fixture photocraft vectorcraft filmcraft lightcraft pdfcraft effectcraft designcraft
  run update_artcraft
  [ "$status" -eq 0 ]
  [[ "$output" == *"7 atualizado(s), 0 falha(s)"* ]]
  python3 - "$ARTCRAFT_DIR" <<'PY'
import configparser, json, os, sys
from pathlib import Path
root = Path(sys.argv[1]); home = Path.home()
records = json.loads((root/'installation.json').read_text())
assert len(records) == 7 and all(r['version'] == 'v2.0.0' for r in records)
for record in records:
    app = record['app']; p = root/app
    assert (p/'v0.1.0').exists() and (p/'source/user-work.txt').read_text() == 'local changes must survive'
    assert (p/'source-current/.git').exists()
    assert (home/'.local/bin'/app).resolve() == (p/'current/bin'/app).resolve()
    assert (p/'mcp-command.json').exists() and list((p/'backups').glob('*/rollback.json'))
    desktop = configparser.ConfigParser(interpolation=None); desktop.read(home/'.local/share/applications'/f'ai.storyteller.{app}.desktop')
    assert desktop['Desktop Entry']['Exec'] == f'{home}/.local/bin/{app} %F'
mime = configparser.ConfigParser(); mime.read(home/'.config/mimeapps.list')
assert mime['Default Applications']['application/pdf'] == 'reader.desktop;'
assert mime['Default Applications']['application/x-vectorcraft'] == 'custom.desktop;'
assert 'ai.storyteller.pdfcraft.desktop;' in mime['Added Associations']['application/pdf']
PY
}

@test "Artcraft: segunda execução não reinstala nem baixa os pacotes" {
  fixture vectorcraft
  update_artcraft
  local pointer inventory requests
  pointer="$(readlink "$ARTCRAFT_DIR/vectorcraft/current")"
  inventory="$(cat "$ARTCRAFT_DIR/installation.json")"
  requests="$(grep -c '/releases/download/' "$ARTCRAFT_FIXTURES/requests")"
  run update_artcraft
  [ "$status" -eq 0 ]
  [ "$(readlink "$ARTCRAFT_DIR/vectorcraft/current")" = "$pointer" ]
  [ "$(cat "$ARTCRAFT_DIR/installation.json")" = "$inventory" ]
  [ "$(grep -c '/releases/download/' "$ARTCRAFT_FIXTURES/requests")" = "$requests" ]
}

@test "Artcraft: consulta de releases é read-only e não instala apps ausentes" {
  fixture vectorcraft
  local before="$(cat "$ARTCRAFT_DIR/installation.json")"
  run artcraft_check_updates
  [ "$status" -eq 0 ]
  [ "$output" = 'vectorcraft v0.1.0 -> v2.0.0' ]
  [ "$(cat "$ARTCRAFT_DIR/installation.json")" = "$before" ]
  [ ! -d "$ARTCRAFT_DIR/vectorcraft/releases" ]
  [ ! -e "$ARTCRAFT_DIR/photocraft" ]
}

@test "Artcraft: não faz downgrade" {
  fixture vectorcraft
  release_field vectorcraft tag_name '"v0.0.9"'
  run artcraft_check_updates
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$ARTCRAFT_DIR/vectorcraft/releases" ]
}

@test "Artcraft: SHA-256 incorreto preserva versão e metadados anteriores" {
  fixture vectorcraft
  printf 'corruption' >> "$ARTCRAFT_FIXTURES/vectorcraft.tar.gz"
  local before="$(cat "$ARTCRAFT_DIR/installation.json")"
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"SHA-256"* ]]
  [ "$(cat "$ARTCRAFT_DIR/installation.json")" = "$before" ]
  [ "$(readlink "$ARTCRAFT_DIR/vectorcraft/current")" = 'v0.1.0/vectorcraft-0.1.0-linux-x86_64' ]
}

@test "Artcraft: rollback restaura arquivos, symlinks e inventário se cache falha" {
  fixture vectorcraft
  export ARTCRAFT_CACHE_FAIL=1
  local before="$(cat "$ARTCRAFT_DIR/installation.json")" mime="$(cat "$HOME/.config/mimeapps.list")"
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [ "$(cat "$ARTCRAFT_DIR/installation.json")" = "$before" ]
  [ "$(cat "$HOME/.config/mimeapps.list")" = "$mime" ]
  [ "$(readlink "$ARTCRAFT_DIR/vectorcraft/current")" = 'v0.1.0/vectorcraft-0.1.0-linux-x86_64' ]
  [ ! -e "$ARTCRAFT_DIR/vectorcraft/source-current" ]
  [ ! -e "$HOME/.local/share/icons/hicolor/48x48/apps/ai.storyteller.vectorcraft.png" ]
}

@test "Artcraft: destino bloqueado não impede rollback dos arquivos já alterados" {
  fixture vectorcraft
  mkdir -p "$XDG_DATA_HOME"
  printf 'user file' > "$XDG_DATA_HOME/metainfo"
  local before="$(cat "$ARTCRAFT_DIR/installation.json")" launcher
  launcher="$(cat "$XDG_DATA_HOME/applications/ai.storyteller.vectorcraft.desktop")"
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [ "$(cat "$ARTCRAFT_DIR/installation.json")" = "$before" ]
  [ "$(cat "$XDG_DATA_HOME/applications/ai.storyteller.vectorcraft.desktop")" = "$launcher" ]
  [ "$(cat "$XDG_DATA_HOME/metainfo")" = 'user file' ]
  [ "$(readlink "$ARTCRAFT_DIR/vectorcraft/current")" = 'v0.1.0/vectorcraft-0.1.0-linux-x86_64' ]
}

@test "Artcraft: uma API offline não impede atualizar os outros apps" {
  fixture vectorcraft pdfcraft
  rm "$ARTCRAFT_FIXTURES/vectorcraft.json"
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"1 atualizado(s), 1 falha(s)"* ]]
  python3 - "$ARTCRAFT_DIR" <<'PY'
import json, sys
from pathlib import Path
r = Path(sys.argv[1])
assert json.loads((r/'vectorcraft/installation.json').read_text())['version'] == 'v0.1.0'
assert json.loads((r/'pdfcraft/installation.json').read_text())['version'] == 'v2.0.0'
PY
}

@test "Artcraft: fallback de SHA256SUMS é verificado quando API não tem digest" {
  fixture vectorcraft
  python3 - "$ARTCRAFT_FIXTURES/vectorcraft.json" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); d['assets'][0].pop('digest'); p.write_text(json.dumps(d))
PY
  run update_artcraft
  [ "$status" -eq 0 ]
}

@test "Artcraft: URL externa e tag inválida são recusadas antes do download" {
  fixture vectorcraft
  release_field vectorcraft tag_name '"../../escape"'
  run artcraft_check_updates
  [ "$status" -ne 0 ]
  [ ! -e "$ARTCRAFT_DIR/vectorcraft/releases" ]
  release_field vectorcraft tag_name '"v2.0.0"'
  python3 - "$ARTCRAFT_FIXTURES/vectorcraft.json" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); d['assets'][0]['browser_download_url']='https://example.com/payload'; p.write_text(json.dumps(d))
PY
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"URL do pacote"* ]]
}

@test "Artcraft: doctor é local e reconhece link quebrado" {
  fixture vectorcraft
  run doctor_artcraft
  [ "$status" -eq 0 ]
  [ ! -e "$ARTCRAFT_FIXTURES/requests" ]
  rm "$HOME/.local/bin/vectorcraft-cli"
  run doctor_artcraft
  [ "$status" -eq "$RC_TODO" ]
}

@test "Artcraft: inventário só marca como cobertos os apps realmente gerenciados" {
  fixture vectorcraft
  run _manual_apps_has_step vectorcraft
  [ "$status" -eq 0 ]
  run _manual_apps_has_step vectorcraft-cli
  [ "$status" -eq 0 ]
  run _manual_apps_kind photocraft
  [ "$output" = candidate ]
}

@test "Artcraft: bandeja inclui releases, contagem e reaproveita cache sem rede" {
  fixture vectorcraft
  LOG_DIR="$BATS_TEST_TMPDIR/log" TRAY_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  tray_is_full_upgrade_running() { return 1; }
  tray_gather_updates_detail() { : > "$1"; : > "$2"; : > "$3"; printf '0 0 0'; }
  tray_last_summary_counts() { printf '0 0 0'; }
  tray_last_summary_line() { return 1; }
  tray_last_doctor_pending_items() { :; }
  run tray_check_now no_notify
  [ "$status" -eq 0 ]
  [ "$output" = updates ]
  assert_json "$(cat "$TRAY_STATE_FILE")" 'd["artcraft"] == 1 and d["artcraft_updates"] == ["vectorcraft v0.1.0 -> v2.0.0"]'
  local requests="$(wc -l < "$ARTCRAFT_FIXTURES/requests")"
  run tray_check_now cached
  [ "$status" -eq 0 ]
  [ "$output" = updates ]
  [ "$(wc -l < "$ARTCRAFT_FIXTURES/requests")" = "$requests" ]
}

@test "Artcraft: erro na consulta da bandeja mantém estado anterior" {
  fixture vectorcraft
  rm "$ARTCRAFT_FIXTURES/vectorcraft.json"
  LOG_DIR="$BATS_TEST_TMPDIR/log" TRAY_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  printf '%s\n' '{"state":"updates","artcraft":5}' > "$TRAY_STATE_FILE"
  tray_is_full_upgrade_running() { return 1; }
  tray_gather_updates_detail() { printf '0 0 0'; }
  run tray_check_now no_notify
  [ "$status" -eq 1 ]
  [ "$(cat "$TRAY_STATE_FILE")" = '{"state":"updates","artcraft":5}' ]
}

@test "Artcraft: integração desabilitada não consulta a API na bandeja" {
  fixture vectorcraft
  FULL_UPGRADE_DISABLED_INTEGRATIONS=artcraft
  LOG_DIR="$BATS_TEST_TMPDIR/log" TRAY_STATE_FILE="$BATS_TEST_TMPDIR/state.json"
  tray_is_full_upgrade_running() { return 1; }
  tray_gather_updates_detail() { printf '0 0 0'; }
  tray_last_summary_counts() { printf '0 0 0'; }
  tray_last_summary_line() { return 1; }
  tray_last_doctor_pending_items() { :; }
  run tray_check_now no_notify
  [ "$status" -eq 0 ]
  [ "$output" = idle ]
  [ ! -e "$ARTCRAFT_FIXTURES/requests" ]
}

@test "Artcraft: modo doctor e dry-run selecionam o step sem executar updates" {
  fixture vectorcraft
  run bash "${FU_ROOT}/full-upgrade.sh" --only artcraft --mode doctor --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$ARTCRAFT_FIXTURES/requests" ]
  [ ! -d "$ARTCRAFT_DIR/vectorcraft/releases" ]
  python3 - "$XDG_CACHE_HOME/system-upgrade/latest.jsonl" <<'PY'
import json, sys
events=[json.loads(line) for line in open(sys.argv[1])]
step=next(e for e in events if e.get('step')=='Doctor: suíte Artcraft')
assert step['status']=='skip' and step['reason']=='dry-run' and step['effect']=='read'
PY
}

rewrite_archive() {
  python3 - "$ARTCRAFT_FIXTURES" "$1" <<'PY'
import hashlib, io, json, sys, tarfile
from pathlib import Path
root=Path(sys.argv[1]); path=root/'vectorcraft.tar.gz'
with tarfile.open(path) as archive:
    files=[(member, archive.extractfile(member).read()) for member in archive.getmembers()]
with tarfile.open(path, 'w:gz') as archive:
    for member, content in files:
        if sys.argv[2]=='mcp' and member.name.endswith('/bin/vectorcraft-cli'):
            content=b'#!/bin/sh\nexit 1\n'; member.size=len(content)
        archive.addfile(member, io.BytesIO(content))
    if sys.argv[2]=='traversal':
        member=tarfile.TarInfo('../../escaped'); member.size=3
        archive.addfile(member, io.BytesIO(b'bad'))
p=root/'vectorcraft.json'; release=json.loads(p.read_text())
release['assets'][0]['digest']='sha256:'+hashlib.sha256(path.read_bytes()).hexdigest()
release['assets'][0]['size']=path.stat().st_size
p.write_text(json.dumps(release))
PY
}

@test "Artcraft: CLI MCP quebrada não é promovida mesmo com checksum correto" {
  fixture vectorcraft
  rewrite_archive mcp
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"MCP"* ]]
  [ "$(readlink "$ARTCRAFT_DIR/vectorcraft/current")" = 'v0.1.0/vectorcraft-0.1.0-linux-x86_64' ]
}

@test "Artcraft: archive traversal não escreve fora do staging" {
  fixture vectorcraft
  rewrite_archive traversal
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [ ! -e "$ARTCRAFT_DIR/escaped" ]
  [ "$(readlink "$ARTCRAFT_DIR/vectorcraft/current")" = 'v0.1.0/vectorcraft-0.1.0-linux-x86_64' ]
}

@test "Artcraft: launcher inválido e checksum ausente preservam instalação" {
  fixture vectorcraft
  export ARTCRAFT_DESKTOP_FAIL=1
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [ ! -e "$ARTCRAFT_DIR/vectorcraft/releases" ]
  export ARTCRAFT_DESKTOP_FAIL=0
  python3 - "$ARTCRAFT_FIXTURES/vectorcraft.json" <<'PY'
import json, sys
from pathlib import Path
p=Path(sys.argv[1]); d=json.loads(p.read_text()); d['assets'][0].pop('digest'); p.write_text(json.dumps(d))
PY
  rm "$ARTCRAFT_FIXTURES/vectorcraft.sums"
  run update_artcraft
  [ "$status" -eq "$RC_WARN" ]
  [ ! -e "$ARTCRAFT_DIR/vectorcraft/releases" ]
}

@test "Artcraft: dry-run do modo update não toca os apps nem a rede" {
  fixture vectorcraft
  run bash "${FU_ROOT}/full-upgrade.sh" --only artcraft --mode update --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$ARTCRAFT_FIXTURES/requests" ]
  [ ! -d "$ARTCRAFT_DIR/vectorcraft/releases" ]
  python3 - "$XDG_CACHE_HOME/system-upgrade/latest.jsonl" <<'PY'
import json, sys
events=[json.loads(line) for line in open(sys.argv[1])]
step=next(e for e in events if e.get('step')=='Atualizar suíte Artcraft')
assert step['status']=='skip' and step['reason']=='dry-run' and step['effect']=='mutating'
PY
}
