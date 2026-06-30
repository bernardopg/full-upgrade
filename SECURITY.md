# Política de Segurança

## Versões suportadas

Apenas a série `3.x` mais recente recebe correções. Sempre use a última release
publicada em [Releases](https://github.com/bernardopg/full-upgrade/releases).

| Versão | Suporte |
| --- | --- |
| `3.x` (última) | ✅ |
| `< 3.0` | ❌ |

## Reportar uma vulnerabilidade

`full-upgrade` executa comandos privilegiados (`sudo`, `pacman`, `fwupdmgr`) na
máquina do usuário, então levamos segurança a sério.

- **Não** abra uma issue pública para vulnerabilidades.
- Use o canal privado **Security Advisories** do GitHub:
  [Report a vulnerability](https://github.com/bernardopg/full-upgrade/security/advisories/new).
- Inclua: versão (`full-upgrade --version`), passos de reprodução, impacto
  esperado e, se possível, um trecho de log (`~/.cache/system-upgrade/latest.log`)
  com dados sensíveis removidos.

Você receberá uma confirmação inicial em até 7 dias.

## Considerações de segurança do projeto

- O arquivo de config (`~/.config/full-upgrade/config`) e os hooks em `steps.d/`
  são carregados via `source` — trate-os como código executável e nunca importe
  arquivos de origem não confiável.
- Ferramentas customizadas em `steps.d/` ficam desabilitadas por padrão
  (`ENABLE_CUSTOM_TOOLS=0`).
- O standalone publicado nas releases acompanha um `.sha256`; verifique-o antes de
  executar.

## Riscos aceitos (OpenSSF Scorecard)

O [Scorecard](https://github.com/bernardopg/full-upgrade/security/code-scanning?query=tool%3AScorecard)
roda semanalmente e expõe alguns achados que **não fazem sentido corrigir** dado
o propósito do projeto. Documentados aqui em vez de deixar alerts abertos sem
explicação:

- **Fuzzing** — `full-upgrade` é um orquestrador Bash que chama ferramentas de
  sistema (`pacman`, `npm`, `pip`, `cargo`, ...); não há parser de input externo
  complexo que justifique integração com OSS-Fuzz/ClusterFuzzLite (que, além
  disso, não têm suporte nativo a Bash). Construir um harness artificial em
  C/Python só para o score seria baixo valor e alto esforço de manutenção.
- **Pinned-Dependencies em `lib/steps/lang_js.sh`** (`npm install -g
  npm@<latest>`, `npm install -g <pkg>@<latest>`, `npm install -g
  corepack@<latest>`) — atualizar essas ferramentas para a versão mais recente
  **é a função do step**. Pinar por hash uma instalação cujo objetivo é "sempre
  a última versão" contradiz o propósito da feature. O risco residual (supply
  chain do registro npm) é o mesmo que qualquer `npm install -g` manual do
  usuário.

Esses alerts ficam com `dismissed_reason` preenchido no Code Scanning,
referenciando esta seção.
