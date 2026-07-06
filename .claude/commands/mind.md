---
name: mind
description: Varre a máquina em busca de programas/CLIs/plugins atualizáveis não cobertos pelo full-upgrade e (re)gera .mind/features.md (backlog em tabela) + .mind/plan.md (plano de implementação). .mind/ é gitignored.
---

# /mind — mapear features candidatas ao full-upgrade

Objetivo: manter `.mind/features.md` e `.mind/plan.md` atualizados com tudo que a máquina
tem instalado que **pode virar step de atualização** e ainda não é. `.mind/` é gitignored
(rascunho de trabalho, não código do projeto).

## O que fazer

1. **Garantir `.mind/`** existe (é gitignored — criar com Write direto).

2. **Varrer a máquina** (read-only) e cruzar com o catálogo atual (`lib/catalog.sh` + `steps.d/`):
   - Gerenciadores: `pacman -Qm` (AUR), `flatpak list`, `snap list`, `uv tool list`, `pipx list`, `npm ls -g`, `gem list`, `go version -m` dos bins em `~/go/bin`, `cargo install --list`.
   - Bins manuais: `~/.local/bin`, `/usr/local/bin`, `~/bin`, `~/.cargo/bin`.
   - `/opt/*` (quais são AUR-owned via `pacman -Qo` vs self-download).
   - Apps com updater próprio em `~/.*` (ex.: `~/.grok`, `~/.qoder`, `~/.jcode`, `~/.cua-driver`, `~/.hermes`).
   - Version managers (mise/asdf/sdkman/nvm) — se surgirem.
   - **Para não estourar contexto, delegue a varredura pesada a um agente `Explore`** (read-only), pedindo tabela `nome|detecção|comando_update|risco` só do que **não** está coberto.

3. **Classificar cada achado**:
   - `coberto` (já é step / auto-descoberto / pacman-AUR) → não listar, ou listar em "Descartados".
   - `pendente` com updater CLI não-interativo → entra na tabela de features com prioridade.
   - `sem CLI` (só GUI) → "Descartados" com motivo.

4. **(Re)gerar `.mind/features.md`**: tabela extensa por prioridade (self-download CLIs → ecossistemas → monitoramentos), colunas `# | Nome | Categoria | Detecção | Comando update | Check-only | Método | Risco | Doc`. Preservar itens já marcados `wip`/`feito`. Incluir seção de correções pendentes de run real, se houver.

5. **(Re)gerar `.mind/plan.md`**: contrato de "pronto" (DoD), fluxo por item, ordem em lotes, tabela de estado com checkboxes. Não apagar progresso — atualizar a tabela de estado.

6. **Resumo ao usuário**: nº de pendentes novos, top prioridades, e lembrar que cada item é implementável via o agente `upgrade-step-integrator` (um por vez, com doc research + teste + validação).

## Regras
- Varredura é **read-only**. Nunca instala/atualiza nada aqui — só mapeia.
- Não duplicar o que o catálogo já cobre. Cruzar sempre com `lib/catalog.sh` e `steps.d/`.
- Converter datas relativas em absolutas no rodapé ("Última varredura: AAAA-MM-DD").
- Preservar marcações de progresso existentes nos dois docs.
