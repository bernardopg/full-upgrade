# TO-DO — Roadmap full-upgrade

Roadmap vivo de **correções, melhorias e ampliações** derivadas de runs reais.
Este arquivo mantém apenas o backlog acionável atual; itens concluídos antigos
foram removidos daqui e ficam rastreáveis pelo `CHANGELOG.md`, tags e PRs.

Base deste ciclo:

- Run ativo: `20260702-145413-2524263` (`full-upgrade`, alias `update`).
- Resultado: `102 ok · 1 warn · 1 todo · 1 fail · 0 skip` em `4m47s`.
- Fail: `Atualizar pacotes do sistema e AUR` — RPC do AUR caiu
  (`error sending request ... channel closed`) e bloqueou até os repos oficiais.
- Log: `/home/bitter/.cache/system-upgrade/full-upgrade-20260702-145413-2524263.log`.
- Série O (run 2026-07-01): mesclada na `main` via PR #107.

Convenções obrigatórias em todos os itens:

- Steps retornam via RC contract (`0`, `RC_WARN`, `RC_TODO`, fail); nunca `exit` dentro de step.
- Mudanças validam com `bash -n`, `shellcheck -S warning -x`, `bats tests/`, smoke flags, `--dry-run` e build quando estrutural.
- Comentários e strings de usuário ficam em PT-BR.
- Nome de step é byte-idêntico entre catálogo, `main.sh`, relatório e argumentos `--skip`/`--explain-step`.
- Preferir a menor mudança correta; sem backward compatibility nova sem necessidade concreta.
- Achado não acionável localmente não deve virar `warn`/`todo` recorrente.

Legenda de prioridade: 🔴 alta · 🟡 média · 🟢 baixa.
Status: ☐ pendente · ◐ em andamento · ☑ concluído.
Esforço: P/M/G.

---

## Série P — Resiliência de rede e auto-remediação (Run 2026-07-02)

Objetivo: nenhum soluço transitório de rede pode derrubar o run ou bloquear os
repos oficiais; pendências detectáveis no fim do run se resolvem sozinhas
quando o usuário optar por isso.

Status do ciclo: P1–P6 implementados na branch `fix/network-transient-resilience`.

### P1 — 🔴 P ☑ Regex central de rede transitória + erro reqwest do paru

`NETWORK_TRANSIENT_RE` em `lib/globals.sh` como fonte única para
`run_network_cmd`/`_retry`/retry AUR; cobre `error sending request`/`channel
closed` (reqwest do paru contra `https://aur.archlinux.org/rpc`), causa do fail
do run-base. Regressão em `tests/core.bats`.

### P2 — 🔴 M ☑ Retry + fallback pacman no step de sistema/AUR

`update_system_aur`: 3 tentativas com backoff; AUR persistindo fora →
`pacman -Syu` aplica os repos oficiais e o step vira `warn` com motivo.

### P3 — 🔴 M ☑ Auto-remediação de pendências finais

Novo step mutating "Auto-remediar pendências finais" (`AUTO_FIX_FINAL_PENDING`,
default 0): aplica `pacman -Syu` (+ retry `paru -Sua`/`yay -Sua`) para
pendências acionáveis. Roda ANTES da "Verificação final de pendências" para o
resumo não registrar `todo` obsoleto após remediação bem-sucedida.

### P4 — 🟡 P ☑ Contrato RC em Oh My Zsh / plugins Zsh / plugins DMS

GitHub inacessível virava `fail` nesses 3 steps (run 2026-07-01 23:34); agora
falha de rede classifica como `RC_WARN`.

### P5 — 🟡 M ☑ Monorepos do registry DMS

Plugins instalados via `dms plugins install` (symlinks para
`plugins/.repos/<hash>/`) nunca eram atualizados; o step agora faz fetch+pull
ff-only dos monorepos e reporta os plugins como gerenciados via registry.

### P6 — 🟡 M ☑ Steps OBS (update de plugins user-scope + doctor de módulos)

`steps.d/85-obs.sh`: "Atualizar OBS (plugins e extensões)" e "Doctor: módulos
OBS" (log da última sessão → módulo com load falho = `todo`; crash recente =
`warn`). Testes em `tests/obs.bats`.

### Backlog P — próximos itens

#### P7 — 🟡 P ☐ Paridade de retry/fallback para yay/pikaur no update principal

`update_system_aur` só tem retry+fallback no caminho paru; os caminhos
yay/pikaur ainda são `run_logged` direto. Extrair o loop para helper e reusar.
Arquivos: `lib/steps/pacman.sh`, `tests/pacman_pure.bats`.

#### P8 — 🟡 M ☐ Doctor journal: classificar coredumps com hint de coredumpctl

Coredumps recorrentes (ex.: `antigravity-ide` NodeService) aparecem como
assinatura crua. Adicionar hint com `coredumpctl info <pid>` e classificação
`app-crash` (warn com hint apontando o app, não o sistema).
Arquivos: `lib/steps/doctor.sh`, `tests/doctor*.bats`.

#### P9 — 🟢 P ☐ Doctor módulos OBS: suporte a OBS Flatpak

`_obs_install_kind` já detecta Flatpak, mas `OBS_CONFIG_DIR` default só cobre o
nativo; Flatpak usa `~/.var/app/com.obsproject.Studio/config/obs-studio`.
Arquivos: `steps.d/85-obs.sh`, `tests/obs.bats`.

#### P10 — 🟢 P ☐ ZapZap upstream

Bug reportado em rafatosta/zapzap#767 (ThemeContext + spam de console.error);
mitigação local no launcher. Quando o upstream corrigir, remover o patch de
`~/.local/share/zapzap-patch/launch.py`.

---

## Série O — Achados do Run 2026-07-01

Objetivo: reduzir ruído recorrente, alinhar severidade entre `--audit` e run
normal, e transformar sinais informativos em recomendações claras sem mascarar
falhas reais.

Status do ciclo: O1–O7 implementados nesta branch; manter os detalhes abaixo como
registro de escopo/aceite até o PR ser mesclado.

### O1 — 🔴 P ☑ Alinhar `--audit` com CVEs Rust não acionáveis

**Problema:** o run normal já classifica CVEs restritas ao `rustup` atualizado
como informativas, mas `--audit` ainda mostra o mesmo caso como `[ALTA] CVEs em
binários cargo` com remediação genérica.

**Evidência:**

- `Auditar binários cargo (CVEs)` retorna `ok` quando só `rustup` está afetado e
  `rustup check` indica última versão.
- `Auto-remediar CVEs de toolchain Rust` também retorna `ok` após confirmar que o
  remanescente vive em crates vendorizadas upstream.
- `./full-upgrade.sh --audit` ainda reporta `1 alta` por `rustup`.

**Arquivos:**

- `lib/steps/audit.sh`
- `lib/steps/lang_rust.sh` se for necessário extrair helper reutilizável
- `tests/` (`audit`/`lang_rust` conforme padrão existente)

**O quê:**

- Atualizar `_audit_probe_cargo` para separar binários `toolchain` de binários
  `cargo-installed`, usando a mesma classificação de `audit_cargo_bins`.
- Quando todos os binários vulneráveis forem `rustup`/toolchain e `rustup` já
  estiver atualizado, registrar achado `info`, não `high`.
- Manter `high` para binários `cargo-installed` com CVE e para toolchain quando
  houver update disponível.
- Ajustar a remediação exibida para refletir origem: `cargo install-update -a`
  só para bins instalados via cargo; `rustup self update && rustup update` só
  para toolchain acionável.

**Critério de aceite:**

- Caso `rustup` atualizado com CVE vendorizada aparece como `INFO` ou nota
  informativa em `--audit`.
- CVE em binário cargo-installed continua `ALTA`.
- Falha de rede no cargo-audit continua informativa/não fatal.
- Bats cobre pelo menos: só toolchain irreparável, cargo-installed acionável,
  mistura toolchain + cargo-installed.

---

### O2 — 🔴 M ☑ Melhorar classificação do `Doctor: journal erros críticos`

**Problema:** o único warn do run foi o journal. As assinaturas remanescentes são
majoritariamente ruído de sessão gráfica/app e Bluetooth/PipeWire, mas ainda
entram como `RC_WARN` genérico.

**Evidência do run:**

- `7x` `Uncaught (in promise) DisconnectedError`.
- `5x` `[ZapZap WAWeb Theme Controller] Unable to find WhatsApp Web ThemeContext`.
- `2x` `Uncaught (in promise) CustomError: fh`.
- `1x` `Uncaught (in promise) cancel`.
- `1x` PipeWire/BlueZ `pw.node ... running -> error`.
- `2x` Bluetooth AVDTP (`No reply to Start request`, `Connection refused`).
- `1x` `ftdi_sio ttyUSB0: error from flowcontrol urb`.

**Arquivos:**

- `lib/steps/doctor.sh`
- `tests/doctor*.bats` ou arquivo novo focado em journal helpers

**O quê:**

- Preservar melhor a origem antes de agrupar mensagens: unit, comm/syslog
  identifier ou prefixo bruto suficiente para diferenciar app, kernel, bluetooth,
  pipewire e serviço.
- Expandir `journal_hint_for` para padrões conhecidos:
  - ZapZap/WhatsApp Web ThemeContext.
  - Promise errors genéricos de Electron/Chromium quando sem unit crítica.
  - PipeWire/BlueZ output node em erro transitório.
  - Bluetooth AVDTP connect/start sem resposta.
  - `ftdi_sio ttyUSB0` flowcontrol URB.
- Adicionar classificação pura para assinatura: `noise`, `known-benign`,
  `actionable`, `unknown`.
- Se todas as assinaturas pós-filtro forem conhecidas benignas, retornar `0` com
  nota informativa e lista no log.
- Manter `RC_WARN` quando houver assinatura desconhecida, erro de serviço crítico,
  I/O/storage, kernel panic/oops, falha de autenticação relevante ou systemd unit
  problemática.

**Critério de aceite:**

- O conjunto do run de 2026-07-01 deixa de gerar `warn` se composto apenas pelos
  padrões benignos acima.
- Erro desconhecido ainda gera `warn`.
- Hints aparecem no terminal para padrões conhecidos.
- Últimas linhas brutas continuam gravadas no log para auditoria.
- Helpers de classificação são cobertos por Bats sem depender de journal real.

---

### O3 — 🟡 M ☑ Separar apps manuais reais de backups/remanescentes

**Problema:** `Doctor: apps manuais` detectou 25 itens fora de gerenciador, com
12 “sem step”. Parte da lista são backups, binários auxiliares ou remanescentes
que não deveriam ser tratados como candidatos de update.

**Evidência do run:**

- Backups/remanescentes: `dumpcap.manual.*`, `wireshark.manual.*`,
  `antigravity.manual-backup-*`, `nomacs-original`.
- Apps/candidatos reais sem step: `codexbar`, `kimchi`, `purple`, `idea-*`,
  `resolve`, `vscode-*`, `sharkd`, `tshark`.

**Arquivos:**

- `lib/steps/manual_apps.sh`
- `tests/manual_apps.bats` ou equivalente
- Opcional: `lib/config.sh` para lista de ignore configurável

**O quê:**

- Classificar inventário em categorias:
  - `coberto` por step.
  - `sem step` candidato real.
  - `backup/remanescente`.
  - `auxiliar`/binário de pacote manual conhecido.
  - `ignorado por config`.
- Ignorar ou rebaixar padrões como `*.manual.*`, `*.manual-backup-*`,
  `*-original`, diretórios versionados antigos quando houver symlink/instalação
  atual equivalente.
- Adicionar recomendação segura para limpeza manual de backups antigos, sem
  remover automaticamente.
- Adicionar configuração opcional para allowlist/ignore local de nomes conhecidos.

**Critério de aceite:**

- Backups/remanescentes não inflam a contagem de “sem step”.
- Lista de candidatos reais continua visível.
- Nenhum binário desconhecido é executado durante o doctor.
- Bats cobre classificação por nome/path.

---

### O4 — 🟡 M ☑ Doctor informativo para pacotes AUR marcados out-of-date

**Problema:** durante o update, o AUR reportou pacotes marcados como
desatualizados, mas isso aparece apenas no log bruto e não vira diagnóstico
estruturado.

**Evidência do run:**

- `apple-fonts`
- `github-desktop`
- `nomacs`
- `quickshell-git`
- `whitesur-gtk-theme`

**Arquivos:**

- `lib/steps/pacman.sh`
- `lib/catalog.sh`
- `lib/main.sh`
- `tests/pacman*.bats`

**O quê:**

- Adicionar helper puro para extrair `marcado como desatualizado` da saída de
  `paru`/`yay`.
- Persistir a lista em arquivo temporário do run ou `STEP_REASON` estruturado
  quando disponível.
- Criar doctor read-only “Doctor: pacotes AUR marcados desatualizados” ou anexar
  ao `Verificação final de pendências` sem virar pendência de update.
- Classificar como informativo: pacote marcado pelo mantenedor não significa que
  há versão instalável agora.

**Critério de aceite:**

- Pacotes out-of-date aparecem em seção própria do relatório/summary.
- Não gera `warn`/`todo` se não há atualização aplicável.
- Pendência real de AUR continua sendo detectada como hoje.
- Parser cobre saída em PT-BR e, se simples, em EN.

---

### O5 — 🟡 P ☑ Melhorar pendência adiada de MCP quando cache `uv` está em uso

**Problema:** o step `Atualizar servidores MCP` já classifica lock de `uv` como
`ok`, mas a pendência operacional fica apenas no motivo do step e pode passar
despercebida.

**Evidência do run:**

- `Cache uv em uso (server uvx ativo); refresh adiado...`
- Comando sugerido: `uv cache clean serena`.

**Arquivos:**

- `lib/steps/mcp.sh`
- `lib/report.sh` se necessário expor “ações adiadas”
- `tests/mcp.bats`

**O quê:**

- Registrar refresh adiado como nota operacional no relatório, sem alterar status
  para `warn`/`todo`.
- Padronizar `STEP_REASON` para facilitar parse por relatório futuro.
- Opcional: adicionar helper que emite uma seção “Ações adiadas não-fatais”.

**Critério de aceite:**

- Lock de server ativo continua `ok`.
- Relatório `.md` mostra claramente o comando para rodar quando MCP estiver
  ocioso.
- Erro real de `uv cache clean` continua `RC_WARN`.

---

### O6 — 🟢 P ☑ Reduzir ruído de Ruby quando tudo é gerenciado pelo Arch

**Problema:** `Atualizar gems de usuário` lista várias gems desatualizadas, mas
conclui corretamente que todas são gerenciadas pelo Arch e não devem ser
atualizadas via `gem update`. A saída é longa para um caso não acionável.

**Arquivos:**

- `lib/steps/lang_other.sh`
- `tests/lang_other*.bats`

**O quê:**

- Quando `updatable` estiver vazio e todas as outdated forem Arch-managed, mostrar
  no terminal só contagem/resumo.
- Gravar lista completa no log.
- Manter modo verboso atual se houver gems próprias do usuário para atualizar.

**Critério de aceite:**

- Terminal fica conciso no caso “todas Arch-managed”.
- Log mantém auditoria completa.
- Nunca atualiza gems que sombreariam o sistema.

---

### O7 — 🟢 M ☑ Unificar postura de segurança entre doctor e `--audit`

**Problema:** `Doctor: fwupd security` considera HSI:3 aceitável e trata
marcadores `✘` como normais, enquanto `--audit` destaca Secure Boot desabilitado
como média. Ambos estão corretos isoladamente, mas a leitura conjunta pode soar
contraditória.

**Arquivos:**

- `lib/steps/audit.sh`
- `lib/steps/doctor.sh`
- `lib/config.sh` se houver política configurável

**O quê:**

- Explicitar no `--audit` que Secure Boot é postura/política, não falha
  operacional.
- Considerar config para severidade de Secure Boot: `info` por default,
  `medium` quando o usuário optar por política estrita.
- Reutilizar texto comum para HSI/Secure Boot entre doctor e audit.

**Critério de aceite:**

- `--audit` deixa claro “não acionável por software”.
- Usuário pode optar por política estrita sem afetar default.
- HSI:3 continua informativo/aceitável.

---

## Ordem de Execução Sugerida

Rodada 1 — limpar severidade enganosa e warn recorrente:

1. **O1** — alinhar `--audit` com CVEs Rust não acionáveis.
2. **O2** — melhorar classificação do journal.

Rodada 2 — melhorar diagnóstico de inventário e updates:

3. **O3** — apps manuais reais vs backups/remanescentes.
4. **O4** — AUR out-of-date informativo.
5. **O5** — ações MCP adiadas no relatório.

Rodada 3 — acabamento/UX:

6. **O6** — saída Ruby concisa.
7. **O7** — postura de segurança unificada.

Cada item deve virar PR isolado quando possível. Atualizar `CHANGELOG.md` em
`Unreleased` a cada PR.

---

## Validação Padrão

Antes de considerar um item concluído:

```bash
bash -n full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
bats tests/
./full-upgrade.sh --help
./full-upgrade.sh --list-steps
./full-upgrade.sh --audit
./full-upgrade.sh --mode doctor
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full
```

Após mudança estrutural ou novo arquivo em `lib/steps`:

```bash
./build.sh
./dist/full-upgrade-standalone.sh --list-steps
```

---

## Achados do Run Real

### Run 2026-07-01 16:33 · v3.19.0-7-gaee842d · `--mode full`

**Resultado:** `101 ok · 1 warn · 0 todo · 0 fail · 3 skip` em `6m14s`.

**Mutação principal:**

- `tmux` atualizado de `3.7-1` para `3.7_a-1`.

**Warn formal:**

- `Doctor: journal erros críticos` com `19` erros pós-filtro, `8` assinaturas.
- Causa dominante: ruído de sessão gráfica/app (`ZapZap`, promises desconectadas)
  e Bluetooth/PipeWire/USB serial transitório.
- Não houve falha em pacman, AUR, disk, boot, SMART, btrfs, systemd units,
  Python, JS ou Ruby shadowing.

**Informativos relevantes:**

- CVEs em `rustup` persistem por crates vendorizadas upstream; `rustup` já está na
  última versão.
- `arch-audit`: `21` pacotes oficiais com CVE conhecida, todos sem correção
  upstream disponível no momento.
- MCP: `serena` uvx com cache `uv` em uso; refresh adiado sem falha.
- Ruby: gems outdated listadas são gerenciadas pelo Arch; corretamente puladas.
- AUR marcou `apple-fonts`, `github-desktop`, `nomacs`, `quickshell-git` e
  `whitesur-gtk-theme` como out-of-date, sem update aplicável no run.

**Skips legítimos:**

- Snap não instalado.
- Bun não instalado.
- Kimi CLI não instalado.

### Audit 2026-07-01 · `--audit`

**Resultado:** `1 alta · 1 média · 0 baixa · 2 info`.

**Achados:**

- `[ALTA] CVEs em binários cargo`: `rustup`.
- `[MÉDIA] Secure Boot desabilitado`.
- `[INFO] 21 pacote(s) oficial(is) com CVE sem correção upstream`.
- `[INFO] fwupd HSI:3`.

**Conclusão de produto:**

- O audit está funcional, mas `rustup` deve seguir a mesma regra do run normal:
  quando a toolchain já está atualizada e o remanescente é vendorizado upstream,
  o achado é informativo, não alta severidade.
