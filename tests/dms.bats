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
configure_test_git_repo() {
  local dir="$1"
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
}

create_dummy_repo() {
  local dir="$1" branch="${2:-main}"
  mkdir -p "$dir"
  git -C "$dir" init -b "$branch" --quiet
  configure_test_git_repo "$dir"
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
  configure_test_git_repo "$clone"
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
  configure_test_git_repo "$clone"
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

@test "update_dms_plugins: stash pop conflito não deixa marcadores no working tree" {
  # Regressão: marcadores de conflito num .qml quebram o plugin em runtime E
  # travam todo update futuro (git recusa fetch/pull/stash com paths unmerged).
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null

  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  git -C "$DMS_PLUGINS_DIR/myplugin" remote add origin "$bare" 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/myplugin" push -u origin HEAD --quiet 2>/dev/null || true

  echo "local-variant" > "$DMS_PLUGINS_DIR/myplugin/file.txt"

  local clone="$MOCKDIR/remote-work"
  git clone "$bare" "$clone" --quiet 2>/dev/null
  configure_test_git_repo "$clone"
  echo "remote-variant" > "$clone/file.txt"
  git -C "$clone" add .
  git -C "$clone" commit -m "remote change" --quiet 2>/dev/null
  git -C "$clone" push origin HEAD --quiet 2>/dev/null || \
    git -C "$clone" push --quiet 2>/dev/null || true

  run update_dms_plugins
  [ "$status" -eq "$RC_TODO" ]
  # árvore limpa (sem unmerged) e sem marcadores no arquivo
  [ -z "$(git -C "$DMS_PLUGINS_DIR/myplugin" ls-files --unmerged)" ]
  ! grep -q '^<<<<<<<' "$DMS_PLUGINS_DIR/myplugin/file.txt"
  # as mudanças locais continuam recuperáveis no stash
  [[ "$(git -C "$DMS_PLUGINS_DIR/myplugin" stash list)" == *"auto-stash myplugin"* ]]
}

@test "update_dms_plugins: pull.rebase+autostash não pode reportar sucesso com conflito" {
  # Regressão: com pull.rebase=true + rebase.autostash=true (combo comum em
  # dotfiles), `git pull --ff-only` vira rebase, conflita ao reaplicar o
  # autostash, deixa marcadores no working tree e MESMO ASSIM sai com 0 — o step
  # reportava "atualizado" com o plugin quebrado e o repo travado.
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null

  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  git -C "$DMS_PLUGINS_DIR/myplugin" remote add origin "$bare" 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/myplugin" push -u origin HEAD --quiet 2>/dev/null || true
  git -C "$DMS_PLUGINS_DIR/myplugin" config pull.rebase true
  git -C "$DMS_PLUGINS_DIR/myplugin" config rebase.autostash true

  echo "local-variant" > "$DMS_PLUGINS_DIR/myplugin/file.txt"

  local clone="$MOCKDIR/remote-work"
  git clone "$bare" "$clone" --quiet 2>/dev/null
  configure_test_git_repo "$clone"
  echo "remote-variant" > "$clone/file.txt"
  git -C "$clone" add .
  git -C "$clone" commit -m "remote change" --quiet 2>/dev/null
  git -C "$clone" push origin HEAD --quiet 2>/dev/null || \
    git -C "$clone" push --quiet 2>/dev/null || true

  run update_dms_plugins
  # o que importa: não pode terminar ok escondendo um repo travado
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$DMS_PLUGINS_DIR/myplugin" ls-files --unmerged)" ]
  ! grep -q '^<<<<<<<' "$DMS_PLUGINS_DIR/myplugin/file.txt"
}

# ── repo travado por conflito pendente ──────────────────────────────────

@test "update_dms_plugins: repo com paths unmerged => RC_TODO, não fail" {
  # Regressão do laço de fail permanente: com paths unmerged o git recusa
  # fetch/pull/stash, e o código antigo virava `return 1` (fail) em TODO run.
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet 2>/dev/null

  create_dummy_repo "$DMS_PLUGINS_DIR/myplugin"
  git -C "$DMS_PLUGINS_DIR/myplugin" remote add origin "$bare" 2>/dev/null
  git -C "$DMS_PLUGINS_DIR/myplugin" push -u origin HEAD --quiet 2>/dev/null || true

  # fabrica estado unmerged de verdade: merge conflitante deixado sem resolver
  git -C "$DMS_PLUGINS_DIR/myplugin" checkout -b other --quiet
  echo "other" > "$DMS_PLUGINS_DIR/myplugin/file.txt"
  git -C "$DMS_PLUGINS_DIR/myplugin" commit -am "other" --quiet
  git -C "$DMS_PLUGINS_DIR/myplugin" checkout main --quiet
  echo "mainside" > "$DMS_PLUGINS_DIR/myplugin/file.txt"
  git -C "$DMS_PLUGINS_DIR/myplugin" commit -am "mainside" --quiet
  git -C "$DMS_PLUGINS_DIR/myplugin" merge other --quiet 2>/dev/null || true
  [ -n "$(git -C "$DMS_PLUGINS_DIR/myplugin" ls-files --unmerged)" ]

  QUIET=0
  run update_dms_plugins
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"conflito pendente"* ]]
  [[ "$output" == *"myplugin"* ]]
}

# ── repo raso (shallow) ────────────────────────────────────────────

@test "update_dms_plugins: repo shallow atualiza via ff-only (sem reset --hard)" {
  # Regressão: fetch --depth=1 criava graft desconectado, HEAD deixava de ser
  # ancestral de origin/HEAD e o ff-only falhava mesmo com árvore limpa e zero
  # commits locais — empurrando todo update para o caminho stash + reset --hard.
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git" work="$MOCKDIR/work"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet
  create_dummy_repo "$work"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin main --quiet
  # história com profundidade > 1, para o clone raso realmente truncar
  echo "v2" >> "$work/file.txt"
  git -C "$work" commit -am "v2" --quiet
  git -C "$work" push origin main --quiet

  mkdir -p "$DMS_PLUGINS_DIR"
  git clone --quiet --depth=1 "file://${bare}" "$DMS_PLUGINS_DIR/myplugin"
  configure_test_git_repo "$DMS_PLUGINS_DIR/myplugin"
  [ -f "$(git -C "$DMS_PLUGINS_DIR/myplugin" rev-parse --absolute-git-dir)/shallow" ]

  # remoto avança
  echo "v3" >> "$work/file.txt"
  git -C "$work" commit -am "v3" --quiet
  git -C "$work" push origin main --quiet

  QUIET=0
  run update_dms_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"myplugin"* ]]
  [ "$(git -C "$DMS_PLUGINS_DIR/myplugin" rev-list HEAD..origin/HEAD --count)" -eq 0 ]
  # e o caminho de divergência (stash) não foi acionado
  [ -z "$(git -C "$DMS_PLUGINS_DIR/myplugin" stash list)" ]
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

@test "update_dms_plugins: monorepo em branch sem upstream é recuperado, não fail" {
  # Caso real (.repos/dankmail): HEAD num branch local sem upstream configurado
  # — o `git pull origin` recusa por não saber o que mergear. Antes da
  # recuperação de paridade isto era fail duro do step; agora o monorepo é
  # realinhado ao HEAD do origin (conteúdo já mergeado upstream) como o loop
  # de plugins faz.
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git" work="$MOCKDIR/work"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet
  create_dummy_repo "$work"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin main --quiet

  mkdir -p "$DMS_PLUGINS_DIR/.repos"
  git clone --quiet "$bare" "$DMS_PLUGINS_DIR/.repos/dankmail"
  # branch local sem upstream, como o 'local' do dankmail real
  git -C "$DMS_PLUGINS_DIR/.repos/dankmail" switch -c local --quiet
  # avança o remoto (o conteúdo do branch local já foi mergeado upstream)
  echo "v2" >> "$work/file.txt"
  git -C "$work" commit -am "update" --quiet
  git -C "$work" push origin main --quiet

  QUIET=0
  run update_dms_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"reset --hard"* ]]
  # realinhado ao HEAD do origin
  [ "$(git -C "$DMS_PLUGINS_DIR/.repos/dankmail" rev-list HEAD..origin/HEAD --count)" -eq 0 ]
  # tree limpa após a recuperação
  [ -z "$(git -C "$DMS_PLUGINS_DIR/.repos/dankmail" status --porcelain)" ]
}

@test "update_dms_plugins: monorepo com mudanças locais sujas preserva-as via stash" {
  DMS_PLUGINS_DIR="$MOCKDIR/plugins"
  local bare="$MOCKDIR/bare.git" work="$MOCKDIR/work"
  mkdir -p "$bare"
  git init --bare -b main "$bare" --quiet
  create_dummy_repo "$work"
  git -C "$work" remote add origin "$bare"
  git -C "$work" push -u origin main --quiet

  mkdir -p "$DMS_PLUGINS_DIR/.repos"
  git clone --quiet "$bare" "$DMS_PLUGINS_DIR/.repos/dankmail"
  git -C "$DMS_PLUGINS_DIR/.repos/dankmail" switch -c local --quiet
  echo "v2" >> "$work/file.txt"
  git -C "$work" commit -am "update" --quiet
  git -C "$work" push origin main --quiet
  # mudança não-commitada em arquivo não-conflitante: stash + realinha + pop
  echo "ajuste local" > "$DMS_PLUGINS_DIR/.repos/dankmail/local.txt"

  QUIET=0
  run update_dms_plugins
  [ "$status" -eq 0 ]
  [ "$(git -C "$DMS_PLUGINS_DIR/.repos/dankmail" rev-list HEAD..origin/HEAD --count)" -eq 0 ]
  [ -f "$DMS_PLUGINS_DIR/.repos/dankmail/local.txt" ]
  grep -q "ajuste local" "$DMS_PLUGINS_DIR/.repos/dankmail/local.txt"
}
