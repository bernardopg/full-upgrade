# Contribuindo

Obrigado pelo interesse em melhorar o `full-upgrade`. Este é um orquestrador
Bash puro (4+) para Arch Linux; não há artefatos compilados.

## Validação antes de qualquer commit

O atalho é o `scripts/preflight.sh`, que roda exatamente o que o CI reprova:

```bash
scripts/preflight.sh          # sintaxe + shellcheck + build + bats (~45s)
scripts/preflight.sh --fast   # sem a suíte bats (~13s), p/ iteração rápida
```

A suíte roda em paralelo (`bats --jobs $(nproc)`), o que a leva de ~1m50 para
~35s — por isso ela cabe no portao de pre-push em vez de ficar só no CI.

Como a `main` aceita push direto (sem PR), instale o hook de pre-push uma vez
para que esse portão rode sozinho antes de cada `git push`:

```bash
scripts/install-hooks.sh      # pule pontualmente com: git push --no-verify
```

### Versões das ferramentas

O `shellcheck` e o `bats` são **pinados** — o CI instala exatamente as mesmas
versões do ambiente de desenvolvimento, via `scripts/install-shellcheck.sh`
(0.11.0) e `scripts/install-bats.sh` (1.14.0). Antes disso o CI usava o pacote
do Ubuntu (shellcheck 0.9.0) e reprovava código aprovado localmente. Ao subir
uma versão, altere só o pin no script correspondente.

### Passos individuais

```bash
# Sintaxe
bash -n full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh scripts/*.sh

# Lint
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh scripts/*.sh

# Testes unitários (bats — funções puras, sem mutação)
bats --jobs "$(nproc)" tests/

# Smoke (sem mutação — seguro em qualquer máquina, inclusive CI não-Arch)
./full-upgrade.sh --help
./full-upgrade.sh --list-steps
./full-upgrade.sh --config
./full-upgrade.sh --config-example
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full

# Build single-file (teste após mudanças estruturais)
./build.sh && ./dist/full-upgrade-standalone.sh --list-steps
```

`--dry-run` registra cada step como `skip` sem rodar comandos mutáveis — é a
principal forma de exercitar o fluxo com segurança.

## Adicionar ou alterar um step

O padrão central é `run_step "Nome exato" funcao_impl`. Para um novo step:

1. Implemente a função no `lib/steps/<domínio>.sh` adequado.
2. Adicione uma linha no catálogo (`lib/catalog.sh`) com timeout realista e
   `cmd_deps` declaradas:
   `nome|categoria|tags|efeito|timeout|cmd_deps|func_name|descrição`.
3. Chame o step no ponto correto de `lib/main.sh` (`run_all_steps`).
4. Use o contrato de retorno: `RC_WARN` (não bloqueante/transitório),
   `RC_TODO` (ação manual). Deixe dependência ausente virar `skip`, não `fail`.

> **O nome do step é a chave de junção.** Ele precisa ser byte-idêntico na linha
> do catálogo, na chamada em `main.sh` e em qualquer `--skip`/`--explain-step`.
> Uma divergência quebra silenciosamente a busca de metadados.

Veja [`CLAUDE.md`](CLAUDE.md) para a arquitetura completa.

## Convenções

- Funções de step retornam pelo contrato de RC; nunca `exit` de dentro de um step.
- `set -uo pipefail` está ativo (sem `-e`) — cheque códigos de retorno explicitamente.
- Comentários e textos ao usuário em **PT-BR**.
- Para gravar saída crua de comando no log, use `log_raw` (remove ANSI), não
  `printf ... >> "$LOG_FILE"`.
- A CI instala Bats via `scripts/install-bats.sh` e ShellCheck via
  `scripts/install-shellcheck.sh` (ambos pinados), coleta cobertura dos testes
  com `scripts/coverage-bats.sh` (`kcov`) e publica `coverage/bats/cobertura.xml`
  no Codecov. Não há checagem de formatação automática: siga o estilo do arquivo
  vizinho (indentação de 2 espaços em `lib/`, conforme o `.editorconfig`).

## Commits — Conventional Commits

Os commits são validados por `commitlint` (`.commitlintrc.json`). Mensagens devem seguir
`tipo(escopo): descrição`, com `tipo` ∈
`feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert`.
Exemplos: `feat(ai): atualiza Ollama`, `fix(ui): cabeçalho duplicado`,
`ci: adiciona Semgrep`. Isso melhora o changelog gerado automaticamente nas
releases (`generate_release_notes`).

## Enviando mudanças

A `main` **aceita push direto** — PR não é obrigatório. O ruleset ainda proíbe
apagar a branch e force-push (`non_fast_forward`), que são as duas operações
irrecuperáveis.

- Rode `scripts/preflight.sh` antes de empurrar (o hook de pre-push faz isso).
- Commits em **Conventional Commits** (acima).
- Atualize `CHANGELOG.md` em `[Unreleased]` quando o comportamento mudar.
- O CI continua rodando a cada push na `main`: ele não bloqueia mais o merge,
  mas é quem roda a cobertura (Codecov), o smoke test e o build do standalone —
  acompanhe o resultado depois de empurrar.

Abrir um PR continua válido (e recomendado para mudanças grandes ou de terceiros):
ramifique a partir de `main`, um PR por mudança lógica. O **Labeler** rotula o PR
automaticamente por caminho (`.github/labeler.yml`).

## CI / Segurança (automático no GitHub Actions)

- **CI** — sintaxe, shellcheck (pinado), bats, cobertura (Codecov) e build
  standalone.
- **CodeQL** — análise dos próprios workflows (Bash não é suportado pelo CodeQL).
- **Semgrep** — SAST para Bash; achados em *Security > Code scanning* (consultivo).
- **OpenSSF Scorecard** — postura de segurança do repo (badge no README).
- **Stale / Greeting** — fechamento de inativos e boas-vindas a novos contribuidores.
- **Dependabot** — mantém as GitHub Actions atualizadas (pinadas por SHA).

## Release

A release é disparada por `push` de tag `v*` ou por `workflow_dispatch` (input
`tag`). No caminho `workflow_dispatch`, o workflow `release.yml`:

1. **Bump** — sobe `VERSION`, atualiza os fallbacks em `full-upgrade.sh`/`build.sh`
   e fecha a seção `[Unreleased]` do `CHANGELOG`. O commit é empurrado **direto
   no `main`** com o `FU_RELEASE_TOKEN` (o PR de ciclo curto existia só para
   satisfazer os required checks e foi removido junto com eles).
2. **Release** — valida (bash -n + shellcheck + bats), builda o standalone,
   atesta proveniência, empurra a tag e cria a GitHub Release. **É aqui que está
   o portão da release**: um bump quebrado falha nesta etapa e nada é publicado.
3. **AUR** — recalcula o checksum do tarball da tag e publica o `PKGBUILD`.

### Secrets necessários (Settings → Secrets and variables → Actions)

| Secret | Uso |
|---|---|
| `FU_RELEASE_TOKEN` | **PAT fine-grained** do owner (escopo `Contents: Read and write` no repo; `Pull requests` não é mais necessário). Usado no push do commit de bump. **Indispensável**: pushes feitos com o `GITHUB_TOKEN` embutido não disparam workflows (anti-loop) — sem o PAT o commit de bump entraria no `main` sem rodar o CI. |
| `AUR_USERNAME` | Usuário AUR para publicar o pacote. |
| `AUR_EMAIL` | E-mail do committer no AUR. |
| `AUR_SSH_PRIVATE_KEY` | Chave SSH do AUR (par AUR). |

Para criar o `FU_RELEASE_TOKEN`: GitHub → Settings → Developer settings →
Personal access tokens → Fine-grained tokens → Generate new token → selecione
apenas este repositório, permissões *Contents: Read and write* e *Pull requests:
Read and write*. Adicione o valor como secret `FU_RELEASE_TOKEN`.
