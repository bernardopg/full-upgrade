# Fechamento das pendências — v3.48.8

## Correções implementadas

- **Rust:** CVEs e advisories unsound entram no diagnóstico; riscos persistentes conservam WARN mesmo quando o memo dispensa novo rebuild. Falhas operacionais e cobertura parcial não aparecem como auditoria limpa. A advisory DB nova invalida o memo anterior. Rebuild auditable copia a fonte, resolve um lock fresco e compila com --locked e instala os executáveis atomicamente para alinhar compilação/metadados sem trocar a origem registrada no cargo. Contagens nomeiam binários, não CVEs.
- **Cobertura Rust:** teto nativo de leitura de 512 MiB inclui o TokenSave instalado, antes excluído pelo teto de 100 MiB. Resultados continuam indicando recuperação parcial de dependências quando faltam metadados auditable.
- **Tray:** lock adquirido/liberado publica início/fim de qualquer execução, incluindo shell e saída antecipada. A publicação usa apenas cache e último resumo, sem rede. Gio observa o diretório porque o JSON é substituído atomicamente; menu e ícone são atualizados sem nova consulta. Fallback local cobre filesystems sem monitor. A data da última consulta de updates não é falsificada pela publicação do run.
- **Hermes:** wrapper temporário registra o stderr completo do Git, inclusive quando a CLI imprime só a primeira linha; retries usam o diagnóstico real e não tratam todo fetch falhado como erro transitório. O wrapper é removido após a etapa e a instalação upstream permanece intacta.
- **Logs:** printf %s conserva escapes JSON; retiradas gravações duplicadas após helpers de rede/retry em Deno, fwupd, gcloud, pnpm e jcode.
- **Progresso:** skips dinâmicos descontam o denominador; skips pedidos não são descontados duas vezes.
- **Inventário:** updater e Doctor compartilham descoberta de módulos Go; payloads Muse são reconhecidos como cobertos. Candidatos restantes exigem verificação de origem, sem presumir atualização automática.
- **9router:** versão consultada em package.json sem inicializar SQLite/tray. Serviços continuam desabilitados.
- **Headroom/Bluetooth:** upstream local ausente vira TODO com orientação de revisar rota; não há restart do serviço nem reativação do 9router. Bluetooth recomenda correlação de dispositivo/perfil, multipoint, alcance e firmware, sem restart automático indiscriminado.

Incluídas também as mudanças locais anteriores: menu com ícones e textos completos, recuperação de timeout, pi OAuth TODO, Codex manifesto WARN, atualização real de tools Mason, classificação HSI/tracker e proteção dos runtimes de containers.

## Validação

- `scripts/preflight.sh`: bash -n, ShellCheck 0.11.0, build standalone e **1.526 testes Bats passaram** na validação completa mais recente.
- Checks Python do tray e Mason integrados ao Bats. A regressão adicional de concorrência do probe eleva a suíte final a **1.527 testes**, reexecutados pelo hook de push. Checks específicos de propriedade do cargo, metadados, cache e concorrência passaram.
- Auditoria real Rust antes do rebuild direcionado: **RC_WARN=10**, cinco binários com achados: cargo-audit, cargo-install-update, cargo-outdated, rustup e tokensave. Não houve falsa conclusão verde.
- O TokenSave revelou três vulnerabilidades: crossbeam-epoch 0.9.18 / RUSTSEC-2026-0204 (fix >=0.9.20), h2 0.3.27 / RUSTSEC-2026-0258 (fix >=0.4.16), rustls 0.23.41 / RUSTSEC-2026-0285 (fix >=0.23.45), além de unsound em anyhow e faster-hex. Atualizar h2 para outra série exige compatibilidade na cadeia upstream; a presença das dependências não prova exploração.
- A tentativa real do Hermes preservou o erro Git antes truncado: `RPC falhou; curl 28 Operation too slow` e `fatal: esperado 'packfile'`. As três tentativas terminaram RC_WARN=10 por rede, incluindo falha de fetch de objeto promisor. O diagnóstico completo ficou disponível, sem reset/clean destrutivo.

Logs desta validação permanecem em `/tmp/full-upgrade-final-validation`; logs do run anterior permanecem no cache e em cópias locais, ignorados pelo Git conforme a política existente. Relatórios de análise e hashes são versionados. Não foi iniciado outro full-upgrade completo.

## Pendências que não têm correção automática universal

- pi: o titular precisa executar `/login` para renovar OAuth.
- Secure Boot, lockdown e swap: exigem decisão e planejamento da configuração de boot/criptografia.
- Vulnerabilidades sem release/dependência compatível: permanecem WARN; não há promessa de cura com reinstall repetido.
- Bluetooth: causa física/perfil/multipoint não foi determinada pelos logs disponíveis.
- Tracker Arch: ausência de fixed cadastrado exige validação por advisory/versão; não autoriza isenção global de pacote.
- Headroom: a rota OpenAI apontando para 127.0.0.1:20128 continua sem upstream. A escolha de substituto depende da rota/provedor realmente usado; o diagnóstico agora torna a dependência visível.

Método: exploração inicial via TokenSave economizou aproximadamente 1.456 tokens; patches foram baseados no fluxo real dos chamadores e verificados por regressões reproduzíveis.

## Resultado do rebuild direcionado

O primeiro `cargo auditable install --force cargo-audit` compilou dependências novas, mas sua seção .dep-v0 registrou versões do Cargo.lock original do registry. A reauditoria então mostrou quatro CVEs e dois unsound daquele inventário antigo, demonstrando que não bastava adicionar cargo-auditable ao comando.

A correção resolve o lock em fonte isolada, compila com esse lock e instala apenas os binários já pertencentes ao crate, preservando o registro crates.io. O rebuild real corrigido de cargo-audit 0.22.2 concluiu em **3m02s**. A auditoria subsequente identificou **332 dependências via metadados cargo-auditable e retornou 0, sem vulnerabilidades nem avisos**. Faster-hex 0.10.1 e as demais versões corrigidas compatíveis foram incorporadas. O registro de origem do cargo-audit foi conferido como crates.io, sem caminho temporário; não há impacto no acompanhamento por cargo-install-update.

Este resultado corrige o cargo-audit local e o caminho de remediação no código. Não declara corrigidos rustup, cargo-outdated, cargo-install-update ou TokenSave. Esses achados persistentes seguem sujeitos a WARN e às restrições de suas dependências/releases.

A revisão final também protege o tray contra uma consulta de rede que atravesse o início/fim de outro run: resumo e lock são lidos após a consulta, impedindo que um resultado antigo sobrescreva uma conclusão nova.
