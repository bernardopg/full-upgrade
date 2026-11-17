# Systray

Applet opcional de bandeja que mostra o estado da máquina, lista o que há para
atualizar ou revisar e dispara o full-upgrade sem abrir um terminal.

```bash
sudo pacman -S python-gobject libayatana-appindicator yad libnotify pacman-contrib
full-upgrade --tray --check     # calcula o primeiro estado
full-upgrade --tray             # inicia o applet
full-upgrade --tray --enable    # autostart (XDG + unit systemd do usuário)
```

| Comando | Efeito |
| --- | --- |
| `--tray` | Inicia o applet. |
| `--tray --enable` / `--disable` | Liga ou desliga o autostart em `graphical-session.target`. |
| `--tray --restart` | Reinicia o applet (necessário depois de atualizar o full-upgrade). |
| `--tray --status` | Último estado em cache, sem rede. |
| `--tray --check` | Recalcula o estado agora (`checkupdates` e AUR, faz rede) e sai. |

## Backends

| Sessão | Backend |
| --- | --- |
| Wayland (Hyprland/DankMaterialShell, KDE, barras StatusNotifier) | AppIndicator via Python/GI. |
| X11 | `yad --notification --listen`: clique esquerdo roda o full-upgrade; sem badge, realce nem ícones no menu. |
| GNOME Shell | Precisa da extensão “AppIndicator and KStatusNotifierItem Support”. |

## Estados

| Estado | Prioridade | Significado |
| --- | --- | --- |
| `running` | 1 | Há um full-upgrade em execução (lock ativo). |
| `error` | 2 | O último run registrou `fail`. |
| `attention` | 3 | O último run deixou `todo` ou pendência do Doctor (reboot, ação manual). |
| `updates` | 4 | Há atualizações de repositório, AUR, Flatpak ou Artcraft. |
| `idle` | 5 | Nada pendente. |

O estado fica em `~/.cache/system-upgrade/tray-state.json`. Uma fonte que
falha (por exemplo, rate limit do GitHub na consulta Artcraft) mantém a
contagem anterior e não congela as demais.

## Menu

```text
full-upgrade
  [estado]  2 atualizações
  [relógio] Verificado há 5 min
  [log]     Último run há 2 h
  [reboot]  Reinicialização pendente ›
  ─────
  Pacotes oficiais (2) ›      linux
                                 7.3.4-arch1-2 → 7.3.5-arch1-1
  Pacotes AUR (1) ›
  Aplicativos Flatpak ›
  Suíte Artcraft ›
  Avisos e pendências ›
  ─────
  Atualizar › Sistema completo | Somente pacotes
  Diagnosticar (Doctor)
  Executar reparos
  ─────
  Verificar agora
  Logs e relatórios › Último log | Último relatório | Pasta de logs
  ─────
  Sair do applet
```

- O cabeçalho é sempre “full-upgrade”; o estado aparece na primeira linha, no
  ícone do painel e no badge.
- Os textos “há N min” são atualizados a cada minuto sem recriar o menu, e o
  menu só é reconstruído quando o conteúdo muda, sem perder a navegação.
- As linhas são quebradas em 28 caracteres, a largura do menu do DMS. Versões
  longas (pacotes `-git`) ocupam duas linhas: a atual e `→ nova`.
- As ações de execução ficam desabilitadas enquanto um run está em andamento.
- O scroll sobre o ícone dispara “Verificar agora” sem abrir o menu.

## Painel e notificações

- **Badge:** contador ao lado do ícone com os itens acionáveis do estado atual
  (atualizações, `todo`s ou falhas). Desligue com `TRAY_BADGE=0`.
- **Realce:** `error` e `attention` usam `IndicatorStatus.ATTENTION`, que barras
  compatíveis destacam.
- **Notificações:** transições úteis (`updates`, `attention`, `error`, volta a
  `idle`). Desligue com `TRAY_NOTIFICATIONS=0`.

## Ícones

Monocromáticos, do Material Symbols Rounded (a mesma fonte do `DankIcon` do
DankMaterialShell). Os estados formam uma família em torno de `deployed_code`:
o ícone base em `idle`, com seta em `updates`, relógio em `running` e alerta em
`attention`; `error` usa o glifo `error`.

Os SVGs saem na cor neutra `#bebebe`. O applet troca essa cor pela cor de texto
do tema GTK (no DMS, a mesma do matugen) ou por `TRAY_ICON_COLOR`, numa cópia em
`~/.cache/full-upgrade/tray-icons/<cor>/`. Os ícones do menu vão como imagem
(pixbuf), porque hosts como o Quickshell não conhecem os nomes próprios do
full-upgrade.

Para mudar um ícone, edite os mapas `TRAY`/`MENU` em `scripts/gen-icons.py` e
regenere a partir da fonte; não edite os SVGs à mão:

```bash
python3 -I scripts/gen-icons.py "MaterialSymbolsRounded[FILL,GRAD,opsz,wght].ttf"
```

## Configuração

`TRAY_CHECK_INTERVAL_M`, `TRAY_TERMINAL`, `TRAY_NOTIFICATIONS`, `TRAY_BADGE` e
`TRAY_ICON_COLOR` estão em [Configuração](configuration.md#systray). Se o
terminal não for detectado, defina `TRAY_TERMINAL`; `xdg-terminal-exec` é a
opção mais confiável quando disponível.
