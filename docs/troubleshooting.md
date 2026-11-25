# Solução de problemas

Comece pelo log e pelos steps que não fecharam `ok`:

```bash
tail -n 120 ~/.cache/system-upgrade/latest.log
jq -r 'select(.event == "step" and .status != "ok" and .status != "skip") | [.status, .step, .reason] | @tsv' \
  ~/.cache/system-upgrade/latest.jsonl
full-upgrade --explain-step "NOME DO STEP"
```

| Sintoma | Causa provável | O que fazer |
| --- | --- | --- |
| `diretório lib/ não encontrado` | O symlink não aponta para uma instalação modular válida. | Rode `./install.sh` de novo ou use o standalone (`./build.sh`). |
| Muitos steps `skip` por sudo | Sem TTY, sem sudo ou credencial indisponível. | Rode em terminal interativo; para automação, configure sudo não interativo. |
| `--only` ou `--skip-category` rejeita o token | Categoria, tag ou nome inexistente. | Copie o valor de `full-upgrade --list-steps`. |
| Step termina em `warn` por tempo | O timeout do catálogo foi atingido. | Veja o log e `--explain-step` (timeout e dependências). |
| Steps de rede em `warn` “sem conectividade” | A rede caiu durante o run. | Rode `full-upgrade --resume` com a rede de volta. |
| JSONL sem `summary` | O run foi interrompido. | Confira `run_start`, os `step` e o `run_end` em `latest.jsonl`. |
| Doctor em `todo` | Ação manual necessária, não falha. | Leia o motivo no resumo ou no log e aplique a remediação. |
| Plugin com “conflito pendente” | O clone tem arquivos unmerged; o git recusa `fetch`/`pull`/`stash`. | `git -C <plugin> status` e resolva, ou descarte com `git -C <plugin> checkout -f HEAD -- .`. |
| Plugin restaurado após `stash pop` conflitado | Suas mudanças divergiram do upstream; elas ficaram no stash. | `git -C <plugin> stash list` e `stash pop` quando quiser reconciliar. |
| `Doctor: ambiente Python` acusa `X requires Y, which is not installed` num pacote do pacman | O PKGBUILD não declarou a dependência (ex.: `python-dateutil` 4.0.0-1 sem `python-tzdata`). `pacman -Syu` não resolve. | `sudo pacman -S python-<dep>` (explícito: com `--asdeps` a limpeza de órfãos o remove), ou `AUTO_FIX_PIP_DEPS=1` para o FU fazer isso. |
| Pacote listado na verificação final como “publicado depois do upgrade deste run” | A versão saiu no repositório depois do sync do início do run (comum em repos de terceiros com vários builds por dia). Não é pendência. | Nada: entra no próximo run. |
| Pacote AUR pendente run após run | PKGBUILD quebrado upstream; o retry é pulado de propósito. | Acompanhe o pacote ou use `FULL_UPGRADE_AUR_IGNORE` até a correção. |
| Applet sem ícone no GNOME | O GNOME Shell não tem systray nativo. | Instale a extensão “AppIndicator and KStatusNotifierItem Support”. |
| Applet com comportamento antigo após atualizar | O processo antigo continua rodando. | `full-upgrade --tray --restart`. |

Para relatar um bug, anexe o resultado de `full-upgrade --report` e
`full-upgrade --healthcheck --json`.
