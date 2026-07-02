#!/usr/bin/env bats
# tests/dms.bats — update_dms_plugins (steps.d/40-dms.sh)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/40-dms.sh"
  MOCKDIR="$(mktemp -d)"
  export LOG_FILE="/dev/null"
}

teardown() {
  rm -rf "$MOCKDIR"
}

# helper: cria um repo git dummy com 1 commit
create_dummy_repo() {
  local dir="$1" branch="${2:-main}"
  mkdir -p "$dir"
  git -C "$dir" init -b "$branch" --quiet
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  echo "initial" > "$dir/file.txt"
  git -C "$dir" add .
  git -C "$dir" commit -m "init" --quiet
}

# helper: cria repo com remote (bare + clone)
create_repo_with_remote() {
  local bare="$1" workdir="$2"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null
  create_dummy_repo "$workdir"
  git -C "$workdir" remote add origin "$bare" 2>/dev/null
  #首次 push
  git -C "$workdir" push origin "$branch" --quiet 2>/dev/null || \
    git -C "$workdir" push -u origin HEAD --quiet 2>/dev/null || true
}

# ── diretório inexistente ──────────────────────────────────────────────────────

@test "update_dms_plugins: diretório inexistente => return 0" {
  DMS_PLUGINS_DIR="$MOCKDIR/nonexistent"
  run update_dms_plugins
  [ "$status" -eq 0 ]
}

# ── plugins sem .git ──────────────────────────────────────────────────────────

@test "update_dms_plugins: plugins sem .git são ignorados (skipped)" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  mkdir -p "$DMS_PLUGINS_DIR/myplugin"
  echo "content" > "$DMS_PLUGINS_DIR/myplugin/file.txt"
  run update_dms_plugins
  [ "$status" -eq 0 ]
}

# ── plugin com .git mas sem remote ─────────────────────────────────────────────

@test "update_dms_plugins: fetch falha => failed" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  mkdir -p "$DMS_PLUGINS_DIR/myplugin"
  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  # remove remote para forçar fetch a falhar
  git -C "$DMS_PLUGINS_DIR/myplugin" remote remove origin 2>/dev/null || true
  run update_dms_plugins
  [ "$status" -eq 1 ]
}

# ── plugin já atualizado (behind=0) ───────────────────────────────────────────

@test "update_dms_plugins: plugin atualizado não faz nada" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null

  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  git -C "$DMS_PLUGINS_DIR/myplugin" remote add origin "$bare" 2>/dev/null
  # push initial commit to bare
  git -C "$DMS_PLUGINS_DIR/myplugin" push -u origin HEAD --quiet 2>/dev/null || true

  # behind=0 porque não há commits novos no remote
  run update_dms_plugins
  [ "$status" -eq 0 ]
}

# ── plugin com commits atrás — ff-only sucesso ────────────────────────────────

@test "update_dms_plugins: ff-only sucesso => updated" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null

  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  git -C "$DMS_PLUGINS_DIR/myplugin" remote add origin "$bare" 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/myplugin" push -u origin HEAD --quiet 2>/dev/null || true

  # Adicionar commit no remote via clone separado
  local clone="$MOCKDIR/remote-work"
  git clone "$bare" "$clone" --quiet 2>/dev/null
  git -C "$clone" config user.email "test@test.com"
  git -C "$clone" config user.name "Test"
  echo "new" > "$clone/newfile.txt"
  git -C "$clone" add .
  git -C "$clone" commit -m "add newfile" --quiet 2>/dev/null
  git -C "$clone" push origin HEAD --quiet 2>/dev/null || \
    git -C "$clone" push --quiet 2>/dev/null || true

  run update_dms_plugins
  [ "$status" -eq 0 ]
}

# ── plugin com stash pop conflito ─────────────────────────────────────────────

@test "update_dms_plugins: stash pop conflito => RC_TODO" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null

  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  git -C "$DMS_PLUGINS_DIR/myplugin" remote add origin "$bare" 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/myplugin" push -u origin HEAD --quiet 2>/dev/null || true

  # 1) Mudança NÃO-commitada localmente (será stashed)
  echo "local-variant" > "$DMS_PLUGINS_DIR/myplugin/file.txt"

  # 2) Commit remoto conflitante (mesmo arquivo)
  local clone="$MOCKDIR/remote-work"
  git clone "$bare" "$clone" --quiet 2>/dev/null
  git -C "$clone" config user.email "test@test.com"
  git -C "$clone" config user.name "Test"
  echo "remote-variant" > "$clone/file.txt"
  git -C "$clone" add .
  git -C "$clone" commit -m "remote change" --quiet 2>/dev/null
  git -C "$clone" push origin HEAD --quiet 2>/dev/null || \
    git -C "$clone" push --quiet 2>/dev/null || true

  # Agora: uncommitted local + remote divergiu => pull falha, stash salva,
  # reset --hard vai pro remote, stash pop conflita em file.txt
  run update_dms_plugins
  [ "$status" -eq "$RC_TODO" ]
}

# ── múltiplos plugins ─────────────────────────────────────────────────────────

@test "update_dms_plugins: mistura de plugins skipped e git" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  mkdir -p "$DMS_PLUGINS_DIR/nongit-plugin"
  echo "stuff" > "$DMS_PLUGINS_DIR/nongit-plugin/data.txt"

  create_dummy_repo "$DMS_PLUGINS_DIR/gitplugin"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/gitplugin" remote add origin "$bare" 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/gitplugin" push -u origin HEAD --quiet 2>/dev/null || true

  run update_dms_plugins
  [ "$status" -eq 0 ]
}

# ── monorepos do registry (.repos) ─────────────────────────────────────────────

@test "update_dms_plugins: symlink para .repos vira repo_managed, não skipped" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  mkdir -p "$DMS_PLUGINS_DIR/.repos/abc123/SubPlugin"
  ln -s "$DMS_PLUGINS_DIR/.repos/abc123/SubPlugin" "$DMS_PLUGINS_DIR/myLinked"
  QUIET=0
  run update_dms_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"via registry (.repos"* ]]
  [[ "$output" == *"myLinked"* ]]
  [[ "$output" != *"sem git (ignorados): myLinked"* ]]
}

@test "update_dms_plugins: monorepo .repos atrasado é atualizado via ff-only" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git" work="$MOCKDIR/work"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet
  create_dummy_repo "$work"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin main --quiet

  # clone como monorepo .repos e avança o remoto
  mkdir -p "$DMS_PLUGINS_DIR/.repos"
  git clone --quiet "$bare" "$DMS_PLUGINS_DIR/.repos/deadbeef"
  echo "v2" >> "$work/file.txt"
  git -C "$work" commit -am "update" --quiet
  git -C "$work" push origin main --quiet

  QUIET=0
  run update_dms_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *".repos/deadbeef"* ]]
  [ "$(git -C "$DMS_PLUGINS_DIR/.repos/deadbeef" rev-list HEAD..origin/HEAD --count)" -eq 0 ]
}
