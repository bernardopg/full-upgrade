# Investigação: serviços, Bluetooth e crashes de FFmpeg — 30/09/2026

Evidência: `/home/bitter/.cache/system-upgrade/full-upgrade-20260930-214434-40104.log`; journal local; inspeção somente leitura de systemd, Docker e PipeWire. Horários em UTC−03. Nenhum serviço reiniciado, configuração alterada ou dump de memória aberto nesta investigação.

## 1. WARN: reinício de docker.service excedeu 120 segundos

**Resolúvel: sim. Severidade alta: o reinício interrompeu workloads reais, e o aviso não representa corretamente todo o período de indisponibilidade.**

O output nas linhas 2669–2673 mostra um serviço a reiniciar, `docker.service`, seguido de falha. O resumo, linha 3032, esclarece que houve timeout do catálogo de 120 segundos. Isso não foi somente lentidão de `checkservices`: o journal confirma um desligamento forçado do daemon e restauração lenta.

| Horário | Evidência confirmada no journal |
|---|---|
| 22:01:06 | `sudo checkservices -P -L -F -R` começa; termina aproximadamente um segundo depois. |
| 22:01:07 | O script executa `sudo systemctl restart docker.service`. Dockerd recebe SIGTERM e systemd inicia a parada. |
| 22:01:17 | GitLab Runner não termina em dez segundos após SIGQUIT; Docker força sua parada. |
| 22:02:37 | Após 90 segundos, `docker.service: State 'stop-sigterm' timed out. Killing.` Systemd envia SIGKILL ao dockerd; resultado `timeout`. |
| 22:02:37 | Novo dockerd inicia e entra em `Restoring containers: start.` |
| 22:03:06 | O limite de 120 segundos do full-upgrade termina; cliente sudo/systemctl desaparece. O job de reinício continua no systemd. |
| 22:04:37 | Na restauração, o novo daemon informa que `streamworks-pipeline-runner-1` não terminou em dois minutos de SIGTERM e força sua parada. |
| 22:04:39 | Docker termina a inicialização, publica a API e fica active. |

**Tempo real: cerca de 212 segundos entre início da parada e Docker ativo; o full-upgrade continuou outros steps enquanto o Docker ainda restaurava seus containers.** O aviso foi emitido aproximadamente 93 segundos antes da recuperação do daemon.

### Causa raiz

Há três orçamentos incompatíveis:

- A unit Docker tem `TimeoutStopUSec=1min 30s`, e `TimeoutStartUSec=infinity`.
- Os containers Streamworks scheduler e pipeline-runner têm `stop_grace_period: 2m`, confirmado em Docker inspect como StopTimeout=120.
- O full-upgrade limita o step de reinício a 120 segundos para a operação inteira.

O daemon foi morto antes de dar ao pipeline-runner seus 120 segundos de encerramento. O novo daemon encontrou esse container em condição residual e gastou mais 120 segundos encerrando-o durante a restauração.

O código atual do Streamworks explica por que o encerramento pode permanecer pendente: `/home/bitter/iptv/tools/ci/pipeline_runner.py:119` instala um handler de SIGTERM que apenas define `stopping=True`; `/home/bitter/iptv/tools/ci/pipeline_runner.py:98` permanece bloqueado em `subprocess.run(...)` até o job pesado terminar. A flag impede o próximo job, mas não encerra o job em execução nem encaminha a solicitação de parada aos filhos. Isso é causa estrutural confirmada no código atual; não foi extraído o conteúdo da imagem do container para provar que a revisão instalada era idêntica.

O GitLab Runner também estava executando jobs: containers `runner-...` nas redes Docker aparecem imediatamente antes da parada. Sua imagem especifica SIGQUIT, que é parada graciosa e pode aguardar jobs; o Docker permitiu somente dez segundos antes de forçar sua parada. Assim, restart de infraestrutura não era uma operação inofensiva.

O full-upgrade protege login e conectividade em `lib/core.sh:662`, mas não protege da mesma forma os runtimes de containers com workloads ativos. Em `lib/steps/doctor/system.sh:1098`, `restart_stale_services` executa `systemctl restart` diretamente. O timeout mata a árvore de clientes de linha de comando (`_kill_tree`, `lib/core.sh:65`), porém a operação enviada ao PID 1 continua independente desses processos. Matar o cliente não cancela a transação de systemd.

### Melhor solução

1. **No full-upgrade, tratar Docker/containerd com workloads ativos como infraestrutura protegida:** deixar TODO explícito para uma janela de manutenção. Checar workloads reais antes de decidir reiniciar. Para esta máquina, essa abordagem tem menor risco que ampliar timeout e continuar interrompendo pipelines.
2. **No Streamworks, implementar encerramento cooperativo do pipeline-runner:** o SIGTERM deve interromper ou concluir o filho dentro do prazo, registrar o job interrompido na fila durável e permitir recuperação. O atual handler é suficiente somente quando o worker está ocioso. Não reduzir abruptamente o prazo sem preservar o estado do job.
3. **Se um reinício for realmente solicitado**, configurar TimeoutStopSec do daemon para comportar o maior stop_grace_period dos containers, mais margem. Por exemplo, 180 segundos de parada para grace=120; o orçamento do cliente precisa incluir também restauração/inicialização. Aumentar apenas o limite do catálogo não corrige o SIGKILL aos 90 segundos.
4. Ao atingir timeout, registrar `ActiveState`, `SubState`, job systemd pendente e serviço envolvido. Não afirmar simplesmente que o reinício falhou nem disparar outro restart. A recuperação pode ainda estar em curso.
5. Validar saúde de workloads depois de o daemon ficar ativo: **`docker.service active` não implica que todos os containers voltaram**. Na inspeção, `streamworks-pipeline-runner-1` estava `exited`, apesar da política `unless-stopped`.

`LiveRestoreEnabled=false` foi confirmado. Live restore pode preservar containers durante indisponibilidade do daemon e diminuir interrupções, mas é uma opção complementar que precisa de manutenção consciente: Docker documenta limites de compatibilidade entre upgrades e mudanças de configuração. Não é solução universal para grandes mudanças de daemon ou para este worker que não encerra corretamente.

### Erros adicionais gerados/observados após o restart

O novo daemon registrou remoção de sandbox residual, aviso de `service host entries` ausentes e tentativas de remover tabelas nftables inexistentes. As mensagens nftables estavam em nível info e parecem limpeza de estado, não prova isolada de firewall quebrado. O aviso de sandbox é compatível com a parada forçada.

Às 22:04:43–22:04:55, Docker registrou timeout/connection refused consultando o DNS `172.28.0.53:53` para serviços dos containers. Compose usa um container Unbound nesse endereço, e serviços Streamworks dependem dele via `condition: service_healthy`. Essas condições ajudam no startup via Compose; não constituem orquestração completa de recuperação quando o daemon restaura containers diretamente. O DNS indisponível por alguns segundos após o restart é confirmado; não há evidência suficiente nesta janela para declarar falha permanente de rede. A correção deve garantir readiness/retry das aplicações e saúde do Unbound ao recuperar o stack.

Fontes oficiais verificadas:

- https://docs.docker.com/engine/daemon/live-restore/ — daemon normalmente encerra containers; live restore tem restrições de upgrade/configuração.
- https://docs.docker.com/reference/compose-file/services/ — `stop_grace_period` e `stop_signal`.
- https://docs.docker.com/reference/cli/docker/container/stop/ — sinal inicial e escalada de parada.
- https://www.freedesktop.org/software/systemd/man/latest/systemctl.html — transações/jobs de systemd. O site retornou HTTP 403 na tentativa de leitura, portanto os fatos sobre continuidade da operação foram confirmados diretamente pelo journal, e não usados como citação de conteúdo remoto.

## 2. Erro histórico: PipeWire Bluetooth `running -> error`

**Resolúvel operacionalmente; causa última do erro remoto não determinada. Evidência atual aponta para episódio de negociação/reconexão, não falha de atualização.**

O Doctor encontrou uma assinatura não filtrada e a classificou corretamente como anterior ao run. O erro real aconteceu às **21:34:50**, cerca de dez minutos antes do início do upgrade.

Contexto:

- 21:34:41: BlueZ remove endpoints de áudio de um cliente D-Bus e registra endpoints de outro cliente.
- 21:34:42–21:34:45: início da sessão Hyprland/UWSM e dos aplicativos.
- 21:34:49: `profiles/audio/a2dp.c:load_remote_sep() Unable to load LastUsed: rseid 9 not found`.
- 21:34:50: WirePlumber tenta `Acquire .../sep11/fd0`, recebe `org.bluez.Error.Failed`, registra falha no transporte Bluetooth; PipeWire registra a transição de erro.
- Na inspeção posterior, PipeWire/WirePlumber estão funcionando e o dispositivo **HUAWEI FreeBuds 6i** está presente como saída padrão. A saída está mutada; isso é estado atual de mixer e não demonstra que o erro de transporte ainda esteja ativo.

O encadeamento é compatível com um endpoint A2DP que mudou entre sessões e um estado LastUsed que já não correspondia ao conjunto remoto. `org.bluez.Error.Failed` é genérico: o journal não prova defeito de firmware, bug específico de codec ou interferência de rádio. Não foi encontrado erro de firmware Bluetooth na janela examinada. Reiniciar Bluetooth automaticamente como primeira medida seria desproporcional e interromperia dispositivos já conectados.

Melhor tratamento: conservar o evento histórico como informação; para recorrência ativa, correlacionar erros recentes do transporte com estado de conexão do dispositivo e saída PipeWire. Primeiro reconectar o fone; se persistir, testar outro perfil/codec e verificar se o endpoint volta. Reparear deve ficar para persistência de estado incompatível, pois apaga o relacionamento existente. Firmware só deve ser priorizado se houver evidência no kernel/adaptador. O Doctor atual `doctor_desktop_health` apenas testa presença dos processos, por isso não demonstra funcionamento de cada transporte.

## 3. 2.192 crashes de FFmpeg ignorados pelo Doctor

**Há problema real de estabilidade dos probes, mas não são 2.192 crashes deste run nem do FFmpeg nativo do host. Parcialmente resolúvel pelo projeto que executa os probes; causa precisa de decoder/alocação ainda não provada.**

O journal confirma exatamente 2.192 entradas dentro da janela consultada pelo Doctor: **2.086 SIGSEGV e 106 SIGABRT**, distribuídas por dez scopes Docker. Todos os eventos observados vêm de containers. O path `/usr/bin/ffmpeg` corresponde ao caminho do executável no contexto do processo do container; não identifica sozinho a instalação pacman do host.

| Data local | Eventos |
|---|---:|
| 25/09 | 111 |
| 26/09 | 140 |
| 27/09 | 1.676 |
| 28/09 | 221 |
| 29/09 | 1 |
| 30/09 | 43 |

Primeiro evento: 25/09 às 15:47:36. Último evento: 30/09 às **17:58:50**. Portanto, havia recorrência no mesmo dia e dentro das últimas 48 horas, mas nenhum desses eventos foi causado pelo run iniciado às 21:44.

Um scope ainda identificável corresponde a `streamworks-scheduler-1`. A command line do último FFmpeg corresponde exatamente ao probe de `/home/bitter/iptv/src/iptv_pipeline.py:5700`: abertura de stream HTTP, teste de dois segundos, uma thread e saída null. URLs dos streams foram deliberadamente omitidas deste documento.

O código do probe tem limites reais:

- `prlimit --core=0` e teto de address space de 640 MiB por padrão;
- `-max_alloc 134217728`, teto de 128 MiB por alocação;
- `-probesize 10000000`, `-analyzeduration 5000000` e uma thread;
- timeout de subprocesso e classificação de término por sinal como `[transient] ffmpeg_signal=...`.

O último registro confirma `COREDUMP_RLIMIT=0`, e `coredumpctl` marca os últimos eventos como `none`, sem arquivo de core. **Desabilitar arquivo de core não suprime o metadado de crash no journal** neste sistema. Não há dump de memória disponível para concluir stack trace, decoder ou versão causadora a partir desses metadados. O limite de memória ou streams malformados podem ser gatilhos; SIGSEGV continua sendo bug/erro do executável ou dependência, não uma saída normal garantida por stream inválido. O comentário do código que chama esses crashes de esperados documenta a decisão operacional, não prova a causa técnica.

O full-upgrade executou exatamente sua política configurada: `COREDUMP_IGNORE_EXE` ignora FFmpeg por basename antes de avaliar recorrência. Em `lib/steps/doctor/system.sh:665`, após ignorá-lo, o Doctor escreve “Nenhum programa com crash recorrente ativo.” Essa frase significa **nenhum programa elegível não ignorado**, e pode passar uma impressão equivocada de saúde. O código já dispõe de ack temporal (`--doctor-ack-coredumps`), que preserva alerta para regressões futuras, porém o ignore global é permanente e também ocultaria um FFmpeg de outra aplicação.

Melhor solução:

1. Investigar e corrigir o FFmpeg **dentro da imagem Streamworks**: confirmar versão/build, comparar com release atualizado e repetir de maneira isolada um probe que falhe. Alterar pacote FFmpeg do host pode não afetar esses containers.
2. Se a falha for reproduzível, variar controladamente o teto address space/max_alloc para distinguir falta de memória de falha de decoder, preservando contenção para evitar OOM. A documentação FFmpeg alerta que `max_alloc` deve ser alterado com cuidado. Não desativar limites globalmente.
3. Registrar no pipeline o número de probes terminados por sinal por host/codec e versão de FFmpeg. SIGSEGV classificado apenas como “transient” pode disparar retries repetitivos; circuit breaker por origem e cooldown já existentes devem cobrir também essa condição, se não cobrirem.
4. Manter isolamento, ausência de arquivo core e timeout; essas contenções já existem e são úteis, mas não corrigem a causa do crash.
5. Afinar a exceção no Doctor para o contexto conhecido (container/workload de probe), ou usar ack de histórico depois de corrigir a causa. Diferenciar “recorrente ignorado” de “sem recorrência” no resumo. A exceção global por basename resolve ruído, mas cega outras utilizações de FFmpeg.

Fonte oficial: https://ffmpeg.org/ffmpeg.html (`max_alloc`, opções de probe). A leitura dos metadados e do código não permite determinar uma CVE ou bug específico; atribuir essas 2.192 ocorrências a uma vulnerabilidade concreta sem versão/backtrace/reprodução seria especulação.

## 4. Falha oculta no journal: loop de restart do 9Router

Apesar de o Doctor de units falhadas anunciar nenhuma unit falhada, o journal da janela 22:01–22:03 mostra `9router.service` iniciando e falhando a cada aproximadamente cinco segundos por **`[MITM] Port 443 already in use`**, com contador de restart chegando a 336 às 22:03:06. Isso pode escapar de `list-units --state=failed`, pois uma unit com Restart=always fica frequentemente em `activating/auto-restart` entre falhas.

Inspeção read-only de sockets: `tailscaled` escuta a porta 443 nos endereços do tailnet IPv4/IPv6, e não em todas as interfaces. Confirmado o conflito de porta reportado pelo 9Router e confirmado um listener atual em 443; não se conclui, apenas com isso, se o bind desejado é wildcard ou se o precheck verifica a porta sem considerar endereço. A análise do 9Router deve decidir entre bind em loopback, mudança do listener desejado ou correção do precheck. Parar Tailscale para satisfazer o proxy não é a escolha recomendada.

O Doctor deve consultar também NRestarts, Result/ExecMainStatus e `SubState=auto-restart`, correlacionados com falhas recentes. Uma janela de saúde sem esses sinais pode indicar OK durante um crash loop.

## 5. Outros sete crashes históricos mencionados no output

Todos anteriores ao início do upgrade. Nenhum programa abaixo atingiu o limite de três crashes do Doctor; isso explica a ausência de TODO. Foram consultados sinais, timestamps, scopes e somente frames de stack já publicados no journal, sem abrir memória de core.

| Programa | Data/hora local | Sinal e contexto | Diagnóstico e melhor caminho |
|---|---|---|---|
| crowdin, 2 eventos | 29/09 23:59:21.340 e 23:59:21.468 | SIGBUS, executável temporário `/tmp/aioc-crowdin5.6TTzbo/crowdin`, scope do Orca; PID 2797949 e 2791512. | Frames publicados são iguais no carregador `/usr/lib/ld-linux-x86-64.so.2`, indicando falha durante carregamento/startup; causa específica não provada. Arquivo mapeado truncado/alterado, artefato temporário inconsistente ou incompatibilidade do executável são hipóteses, não diagnóstico. Reproduzir com download íntegro em diretório exclusivo por invocação e verificar hash/tamanho e ambiente de loader. A simultaneidade torna corrida em cache/extraction uma hipótese que merece verificação. Não atribuir à atualização do host sem evidência. |
| node, 2 eventos | 28/09 19:00:55.256 e 19:00:59.525 | SIGABRT; comm `node (vitest)` e `npm exec vitest`; PID 1372233 e 1372211, mesmo scope kitty. | Teste Vitest e seu processo npm terminam com abort. Sem mensagem fatal/backtrace útil nos metadados consultados; OOM de heap, assert de runtime ou abort do teste são hipóteses. Verificar log do teste e repetir o mesmo comando com Node/version/env conhecidos; atualizar runtime ou reduzir concorrência somente quando a reprodução mostrar qual condição falha. Os dois eventos não bastam para indicar Node quebrado globalmente. |
| Discord, 1 evento | 28/09 17:04:01.601 | SIGTRAP; `/home/bitter/.config/discord/app-1.0.159/Discord`, scope da aplicação. | Um frame sem símbolos úteis. SIGTRAP pode ser assertion fatal/Crashpad de Chromium, não confirma qual subsistema. Usar log do Discord e reprodução após atualizar a aplicação; verificar aceleração gráfica somente se log relacionar GPU. Não há evidência de recorrência. |
| quickshell, 1 evento | 30/09 18:34:24.044 | SIGABRT, processo em **scope Docker**, não a unit DMS da sessão; container já removido. | Stack publicada chega a `QMessageLogger::fatal` e `QGuiApplicationPrivate::createEventDispatcher` durante inicialização de QGuiApplication. Forte evidência de falha de startup Qt/plataforma gráfica no container; ausência de display/plugin/sessão é hipótese plausível, sem a mensagem Qt fatal específica. Para checagem de CLI/versão em container, usar modo apropriado sem GUI ou plataforma offscreen quando aplicável. Isso não demonstra crash do shell desktop em execução. |
| WebKitWebProcess, 1 evento | 27/09 17:46:41.897 | SIGABRT; `/usr/lib/webkit2gtk-4.1/WebKitWebProcess`, scope kitty; PID 3568807. | Sem stack/mensagem fatal útil disponível no journal consultado. O subprocesso WebKit foi iniciado em sessão de terminal; não foi identificado seu aplicativo pai. Consultar log do aplicativo que o iniciou e reproduzir no mesmo build WebKit. Não é possível atribuir a bug específico de WebKit, sandbox ou GPU somente pelo sinal. |

Esses eventos são investigáveis, mas não apresentam evidência suficiente para uma correção determinística no full-upgrade. A melhoria útil no relatório é anexar timestamp, sinal e contexto ao agrupamento de crashes, distinguindo testes/processos de containers de aplicações da sessão. Crashes isolados devem permanecer informativos; aumentar cegamente a severidade produziria novos falsos alarmes.
