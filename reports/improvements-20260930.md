# Correções e revisão do applet — 30/09/2026

## Resultado aplicado

O código foi alterado neste repositório, compilado como standalone e instalado em `/usr/bin/full-upgrade`. O serviço `full-upgrade-tray.service` foi reiniciado. A versão declarada permanece 3.48.7: estas alterações são locais, ainda sem release publicado. Uma futura atualização do pacote poderá substituir o executável; os fontes modificados permanecem neste repositório.

Backup do executável anterior: `/home/bitter/.cache/system-upgrade/backups/full-upgrade-before-tray-20260930`.

## 9router

- `9router.service` e `9router-api.service`: parados e desabilitados.
- Autostart XDG mantido desativado (`Hidden=true`, `X-GNOME-Autostart-enabled=false`).
- 9router removido das referências selecionadas/fixadas do AI Overview no DMS. O painel foi reiniciado porque recarregar apenas o plugin preservava os valores antigos em memória e regravava a configuração.
- Pacote, dados, credenciais e arquivos de serviço preservados.
- A porta 20128 deixou de escutar. Os listeners 443 do Tailscale foram preservados.

## Applet: causa e correção

| Problema | Causa | Correção |
|---|---|---|
| Frases incompletas | Motivo limitado a 60 caracteres e detalhe limitado a 96 | Motivo inteiro no estado; detalhes distribuídos em linhas curtas no submenu |
| Itens desapareciam | Limite artificial de 30 entradas | Todas as entradas disponíveis no menu |
| Menu pouco organizado | Ações e informações repetidas no mesmo nível | Atualizar, diagnósticos, reparos e logs agrupados; ícones GTK nativos |
| Avisos de IA/serviço chamados “Doctor” | Rótulo histórico apesar de coleta de várias categorias | “Avisos e pendências” e cabeçalho “itens para revisar” |
| Flatpak sem detalhamento | Apenas contador gravado | Lista de aplicativos no JSON e submenu próprio |
| Menu preso após timeout | Worker encerrava sem limpar `checking` | Finalização garantida e aviso de verificação incompleta |
| Resultado falsamente atualizado | Falhas de consulta descartadas | Preserva cache e retorna erro; diferencia códigos normais de ausência de updates |
| Navegação reiniciava | Menu reconstruído mesmo sem mudanças | Reconstrução apenas quando o conteúdo exibido muda |
| Polling prolongado sem execução | Monitor aguardava até 30 minutos mesmo sem início | Encerra após 60 segundos sem observar execução |
| Ações conflitantes | Disponibilidade dependia de estado global anterior | Ações de atualização/diagnóstico/reparo bloqueadas durante execução |
| Lançamento malsucedido anunciava início | `Popen` sem tratamento de falha | Erro explícito, sem aviso de início bem-sucedido |

O menu principal foi conferido visualmente no DMS: ícones aparecem, ações e rótulos ficam legíveis. Os detalhes usam linhas de até 30 caracteres para acomodar a largura fixa do host SNI do DMS; não foi necessário alterar o shell ou criar dependências.

## Correções encontradas no último run

| Área | Correção no código | Limite restante |
|---|---|---|
| pi | `invalid_grant`/refresh token expirado vira TODO com `/login`; preserva sucesso das fases anteriores | Novo login requer interação do usuário |
| Marketplace Codex | Manifesto divergente vira WARN de atualização parcial | Autor upstream precisa corrigir o nome; snapshot local preservado |
| Mason | Compara ferramentas instaladas com o registro e usa `MasonInstall` headless para atualizar as diferentes | Falhas dos instaladores continuam possíveis e agora são propagadas |
| fwupd | `HSI:!` avaliado independentemente do piso; Secure Boot/lockdown desativados deixam de ser chamados de hardware sem suporte | Habilitar essas proteções exige avaliar firmware e configuração local |
| arch-audit | Ausência de versão corrigida no tracker deixa de provar ausência de fix upstream; consultas falhadas são inconclusivas | Dados antigos do tracker exigem conferir advisory e versão instalada |
| Reinício de serviços | Docker/containerd/Podman protegidos do reinício automático genérico | Reinício deve ocorrer numa janela própria para os workloads |

As mensagens do run antigo permanecem no histórico; este trabalho não reescreve evidências passadas. O próximo run usará as classificações corrigidas. Não foi executado outro full-upgrade completo durante esta revisão.

## Verificação

- 430 testes Bats passaram nas suítes tray, CLI, core, pi, plugins, Doctor e arch-audit.
- `python3 tests/tray_appindicator.py`: texto completo, mais de 30 entradas, ícones, estabilidade do menu, bloqueio durante execução e recuperação de timeout.
- `python3 tests/editor_mason.py`: executa a lógica em Neovim real com registro local controlado; atualiza apenas ferramenta defasada e propaga falha de registro.
- ShellCheck nos módulos alterados, validação de sintaxe pelo build standalone e `git diff --check` passaram.
- Checagem real consultou pacotes oficiais, AUR e Flatpak e gravou estado atualizado.
- Serviços 9router inativos/desabilitados; DMS e tray ativos após aplicação.
