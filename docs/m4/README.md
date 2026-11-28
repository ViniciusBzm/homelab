# M4 — HomeLab Development Platform

**Estado:** M4.0 **APROVADO** (ADR-008 aceita) · M4.1 **APROVADO** · M4.2 **APROVADO** · M4.3 **APROVADO** · M4.4 **IMPLANTADO E APROVADO** em 27/11/2026 (commit `d27f73b`; evidências em `7054280`) · **Data:** 27/11/2026 · Branch `feat/m4-development-platform`

O M4 transforma o HomeLab numa plataforma de desenvolvimento. O primeiro produto é o **HomeLab Control**: uma API própria, **somente leitura** no início, e uma interface web que mostram o estado do servidor (host, contêineres, monitores e backup). A API nasce com contratos versionados, pensando no **WristOps**, um cliente futuro que vai consumi-la.

| Documento | Conteúdo |
|---|---|
| [arquitetura.md](arquitetura.md) | API, interface, contratos, integração com os serviços, organização do código, segurança e recursos |
| [qualidade-e-operacao.md](qualidade-e-operacao.md) | Testes, implantação e recuperação |
| [ADR-008](../decisoes/ADR-008-homelab-control.md) | Decisões técnicas e alternativas descartadas |

## Decisões principais

1. **Monorepo no próprio repositório:**
   - `apps/control-api` (Fastify);
   - `apps/control-web` (React, Vite e Tailwind);
   - `packages/contracts` (schemas Zod compartilhados).

   Usa **npm workspaces**, sem ferramenta extra.
2. **Uma única imagem e um único contêiner em produção.** A API também serve o front-end já compilado. Assim há uma só origem (sem CORS), um só processo e cerca de 100 MiB.
3. **Somente leitura, por construção:**
   - a API só tem rotas `GET`;
   - as fontes são arquivos montados `:ro`, o `socket-proxy` que já existe (que recusa POST) e o `/metrics` do Kuma, com chave de API.
4. **Sem porta na LAN até o M4.5.** O contêiner publica só em `127.0.0.1` e é acessado por túnel SSH. Nenhuma regra de firewall muda até lá.
5. **Contratos primeiro:**
   - todo endpoint responde num envelope padrão, validado por Zod;
   - os schemas são exportados como JSON Schema para o WristOps;
   - `/api/v1` só recebe mudanças **aditivas**.
6. **Adiados até haver necessidade:** SQLite (histórico), PostgreSQL, Caddy/TLS, CI/CD e autenticação por token. O token entra junto com a exposição na LAN.

## Backlog incremental

Cada incremento termina com testes verdes e evidência. Os que mudam o servidor exigem autorização específica.

| Inc. | Entrega | Muda o servidor? |
|---|---|---|
| **M4.1** | Esqueleto do monorepo, `contracts`, API com `/api/health`, `/api/v1/host` e `/api/v1/backup` (só arquivos locais), modo *fixtures*, testes Vitest | Não |
| M4.2 | Fontes de rede: `/api/v1/containers` (pelo socket-proxy) e `/api/v1/monitors` (pelo `/metrics` do Kuma), com timeout, cache e degradação por fonte; `/api/v1/summary` | Não |
| M4.3 | Interface web (painel read-only) servida pela API; teste ponta a ponta com Playwright em modo *fixtures* | Não |
| M4.4 | Imagem Docker e `stacks/control/compose.yaml` (127.0.0.1, limites, healthcheck), script de deploy, monitor no Kuma, prova de persistência após reboot | **Sim** (sudo; autorização) |
| M4.5 | Token de leitura para clientes (WristOps), publicação do JSON Schema, liberação na LAN via `firewall.conf` | **Sim** (firewall; autorização) |
| Depois | Histórico em SQLite, Caddy/TLS, CI no GitHub Actions, ações de escrita (só com novo ADR) | — |

## Primeiro incremento implementável: M4.1

**Objetivo:** ter código executável e testado no PC, sem tocar no servidor.

**Escopo:**
- **Raiz:**
  - `package.json` com workspaces;
  - `tsconfig.base.json`;
  - `.nvmrc` (Node 22 LTS);
  - scripts `typecheck`, `test` e `dev`.
- **`packages/contracts`:**
  - Zod para `Envelope`, `HostSnapshot` e `BackupStatus`;
  - os tipos inferidos;
  - o script `schemas:export`, que gera o JSON Schema.
- **`apps/control-api`:**
  - Fastify, com cada resposta validada pelo schema Zod antes do envio. Uma resposta fora do contrato vira 500 genérico. Isso dispensa o `fastify-type-provider-zod`;
  - configuração por variáveis validadas com Zod;
  - fontes `host` (lê `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime`, `statfs` e `/sys/class/hwmon`) e `backup` (lê os arquivos `homelab-*.status`);
  - `HL_CONTROL_ROOT`, um prefixo de caminho que permite apontar para *fixtures* no Windows.
- **Rotas:** `GET /api/health`, `GET /api/v1/host` e `GET /api/v1/backup`.

**Critérios de aceite:**
1. `npm ci && npm run typecheck && npm test` passa no PC (Node 22).
2. **Testes:**
   - parsers com casos válidos, vazios e corrompidos;
   - status `ok` e `fail`;
   - arquivo ausente, que deve virar fonte indisponível sem derrubar a API;
   - respostas validadas pelos schemas;
   - verificação de que não existe rota de escrita.
3. `npm run dev` sobe a API em `127.0.0.1` lendo *fixtures*, e as respostas obedecem ao envelope.
4. Nenhum dado real nas *fixtures*: sem IP, hostname ou usuário.
5. Nenhuma mudança no servidor, nenhuma porta aberta, nada de Docker.

**Fora do M4.1:** contêineres, monitores, interface web e deploy.

## M4.1: como rodar (27/11/2026)

```
npm ci
npm test               # typecheck + Vitest (71 testes, sem servidor; HTTP só contra servidores simulados em 127.0.0.1)
npm run dev            # painel em http://127.0.0.1:5173 (hot reload) + API simulada em 127.0.0.1:8088
npm run e2e            # build + Playwright (Edge do Windows; nenhum navegador baixado)
npm run schemas:export # JSON Schema em packages/contracts/dist/schemas/
```

**Estados de cada fonte:**
- `ok`;
- `missing`: arquivo ausente;
- `invalid`: conteúdo ilegível, data no futuro ou arquivo grande demais;
- `stale`: válido, mas mais antigo que o limite (backup: 26 h; restauração: 35 dias). O dado continua na resposta;
- `error`: falha real (permissão, E/S ou timeout).

**Sem dados internos na resposta:**
- as mensagens de erro são fixas;
- dos arquivos de status saem só campos validados (`snapshot`, `repo`, `itens`, `falhas`, `dbs_ok`);
- o texto livre, que pode conter caminhos, é descartado.


## M4.2: contêineres, monitores e resumo (27/11/2026)

**Rotas novas:** `GET /api/v1/containers`, `/api/v1/monitors` e `/api/v1/summary`. Os contratos existentes não mudaram; as mudanças são aditivas, incluindo os códigos de erro `not_configured`, `unreachable`, `unauthorized` e `bad_status`.

**Fontes HTTP:**
- `AbortSignal` cancela a requisição no timeout (testado: o servidor vê a conexão fechar);
- sem redirecionamentos;
- limite de 2 MiB por resposta.

**Filtragem:**
- **Docker:** `/containers/json` só fornece nome, imagem, estado, saúde (derivada do `Status`) e criação. *Labels*, montagens, rede, comando e ID são descartados.
- **Kuma:** do `/metrics` sai só `monitor_status`, com nome e tipo. `monitor_url` (que contém o token de push), `monitor_hostname` e `monitor_port` são descartados.
- A chave do Kuma é lida de um arquivo e nunca é registrada nem devolvida.

**Resumo:**
- `source_unavailable`: a API não obteve o dado;
- `stale_data`: dado desatualizado;
- `service_failure`: a fonte relata uma falha (monitor DOWN, contêiner parado ou *unhealthy*, backup com falha);
- status geral: `down` quando há falha operacional; `degraded` quando há fonte indisponível ou desatualizada; `ok` nos outros casos.

**Correções do M4.1:**
- disco sintético no modo *fixtures*;
- a idade do dado agora soma o tempo em cache;
- temperatura vazia não vira 0 °C;
- datas impossíveis (30/02, 24:00, fuso acima de 14 h) são recusadas.

## M4.3: interface web (27/11/2026)

**Stack:** React 19, Vite 8 e Tailwind 4, em `apps/control-web`. Tema escuro (grafite), azul discreto e cores semânticas. Consome **só** os seis endpoints GET; não há ações administrativas.

**Sem falso estado operacional:**
- toda resposta é validada pelo contrato Zod no navegador; resposta inválida nunca vira dado;
- o estado geral só fica "Operacional" se o resumo da **última** tentativa for válido e `ok`. Se a atualização falha, aparece "Estado não confirmado", com a última leitura apenas como referência;
- monitores pendentes, em manutenção ou desconhecidos nunca aparecem como saudáveis.

**Ajustes na API:**
- o resumo ganhou o tipo `service_warning`, usado para monitor não confirmado, contêiner iniciando, lista vazia e dados incompletos (`skipped`);
- as listas ganharam o campo `notUp`.

**CSP:**
- a API continua com `default-src 'none'`;
- o front-end recebe `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'`, sem `unsafe-*`;
- as barras de progresso são SVG por atributo, sem estilo inline.

**Testes:**
- 84 de unidade, API e contratos (Vitest);
- 8 ponta a ponta (Playwright), contra a API de produção servindo o build, mais cenários de borda injetados no navegador.

## M4.4: preparação da implantação (27/11/2026). NÃO implantado

**Arquivos:**
- `stacks/control/Dockerfile`: multi-stage, com build do front e empacotamento da API (`dist/server.mjs`, executado com `node`; sem tsx);
- `stacks/control/compose.yaml`: projeto `control`, separado do M3;
- `stacks/control/gateway.conf`;
- `stacks/control/.env.example`;
- `.dockerignore`;
- `scripts/server/homelab-control-deploy.sh` e `scripts/server/lib/control.sh`.

**Imagem final:**
- contém só o runtime do Node, as dependências de produção, `server.mjs` e o front compilado;
- não contém npm/npx/corepack/yarn, tsx, esbuild, vite, vitest, playwright, fixtures nem código-fonte. O deploy confere isso antes de subir.

**Contêiner:**
- usuário 1000, sistema de arquivos somente leitura (`tmpfs /tmp` de 16 MB), `cap_drop: ALL` e `no-new-privileges`;
- limites: 160 MiB de memória, 0,5 CPU e 64 PIDs;
- publica só `127.0.0.1:8088`; o acesso é por túnel: `ssh -L 8088:127.0.0.1:8088 homelab`;
- os dois arquivos de status são montados `:ro`;
- a chave do Kuma fica em `secrets/kuma_api_key`: fora do Git, `0600`, dono uid 1000, nunca exibida.

**Isolamento do socket-proxy:** a inspeção confirmou que o proxy do M3 responde 200 ao `inspect`. A solução mais leve é o **`control-gateway`**: nginx sem privilégios, com 32 MiB e sem portas publicadas. Ele é o único contêiner do projeto na rede `monitoring`.
- O Control fica só nas redes `control_edge` (para a porta local) e `control_internal` (`internal: true`); não alcança `socket-proxy` nem `uptime-kuma` diretamente.
- O gateway libera exatamente:
  - `GET /containers/json?all=1` → socket-proxy;
  - `GET /metrics` → Kuma.
- Todo o resto recebe 403, inclusive `inspect`, `version`, outros métodos e outros caminhos.
- A stack do M3 não é alterada.

**Deploy (`sudo bash homelab-control-deploy.sh <admin> <repo>`):**
1. **Pré-requisitos, sem alterar nada:**
   - M3 íntegro;
   - `.env` com imagens de versão fixa (recusa `latest`);
   - chave protegida e porta 8088 livre.
2. **Arquivos:** guarda os anteriores e valida o gateway com `nginx -t`.
3. **Imagem:** build com a tag do commit e inspeção (usuário, ferramentas, fixtures).
4. **Subida:** `up -d` só do projeto `control`.
5. **Validação:**
   - saúde e fontes;
   - usuário, `read_only`, capabilities, porta só em 127.0.0.1 e redes;
   - provas de dentro do contêiner: `inspect` dá 403, `socket-proxy` e `uptime-kuma` são inalcançáveis;
   - M3 com os mesmos IDs.
6. **Limpeza:** mantém a imagem atual e a anterior.

Qualquer falha nas etapas 4–5 aciona o **rollback automático**: volta à imagem e aos arquivos anteriores ou, sem versão anterior, faz `down` do projeto `control`. Também há `--rollback` manual.

**Inspeção somente leitura do Wyse (27/11, 22:55):**

| Item | Resultado |
|---|---|
| Hardware e sistema | x86_64, 4 núcleos, 4,5 GiB de RAM disponíveis, `/` em 28% |
| Docker | Engine 29.10.1, Compose 5.8.0, cgroup v2 (limites funcionam) |
| M3 | 4 contêineres em execução; rede `monitoring` existe |
| Imagens | sem `node` nem nginx locais: o deploy baixa (registro acessível) |
| Proxy atual | `inspect` = 200, o que confirma a necessidade do gateway; `networks` e POST = 403 |
| Kuma `/metrics` sem chave | 401 (a chave precisa ser criada) |
| Porta 8088 | livre |
| Arquivos de status | 0644 root |
| Usuário administrador | uid 1000, igual ao do contêiner |
| Sensores (`hwmon`) | 2 |

**Pendências para implantar (exigem autorização):**
1. A pessoa cria a chave de API no Kuma (Configurações → Chaves de API).
2. Definir as versões fixas de `NODE_IMAGE` e `GATEWAY_IMAGE`.
3. Rodar a suíte `tests/server` no sandbox. A inspeção era só leitura, por isso não rodou no Wyse; localmente passaram os testes portáveis de `test_control.sh`.
4. Deploy com sudo numa janela visível.
5. Validar a origem das métricas do host no contêiner (requisito futuro 2 da ADR-008).

## M4.4: primeira implantação real (27/11/2026, 23:30–23:33)

Implantação controlada com `homelab-control-deploy.sh`, terminada com `falhas=0`. Evidência completa em [`tests/evidencias/control-deploy-2026-11-27.txt`](../../tests/evidencias/control-deploy-2026-11-27.txt).

**Antes do deploy:**
- imagens fixas `node:22.23.5-alpine3.24` e `nginxinc/nginx-unprivileged:1.30.6-alpine3.24` (amd64);
- suíte Linux no sandbox: **67/67**;
- chave de API do Kuma criada pela pessoa, digitada sem eco, validada no Kuma (HTTP 200) e gravada com `0600` e uid 1000; nunca foi exibida nem registrada.

**Resultados:**

| Verificação | Resultado |
|---|---|
| Imagem | `homelab-control:d27f73b8e0ff`, 279 MB, não-root, sem ferramentas de dev nem fixtures |
| Seis endpoints com dados reais | 200; fontes host, backup, restore-test, containers e monitors todas `ok`; resumo `ok` |
| Endurecimento | usuário 1000, `read_only`, `cap_drop ALL` |
| Limites e uso em repouso | Control 160 MiB / 0,5 CPU / 64 PIDs (uso: 32 MiB); gateway 32 MiB / 0,25 CPU / 32 PIDs (uso: 5 MiB) |
| Portas | Control sem portas; gateway só em `127.0.0.1:8088` |
| Gateway | só `GET /containers/json?all=1` e `GET /metrics`; demais caminhos, parâmetros e métodos dão 403 |
| Isolamento | de dentro do Control, `socket-proxy` e `uptime-kuma` falham por nome; **34 alvos por IP** inalcançáveis (contêineres do M3, gateways das redes, IP do host na LAN e internet) |
| LAN (do PC) | só 22, 3001 e 8090 abertas (já existiam); 8088, 8080–8082, 2375 e 45876 bloqueadas |
| M3 | os mesmos 4 contêineres (mesmos IDs), em execução |
| Painel pelo túnel | `ssh -L 18088:127.0.0.1:8088 homelab`; a página veio com a CSP restritiva |
| Origem das métricas do host | uptime igual ao do boot do Wyse e memória total igual à do host: refletem o **host** (requisito futuro 2 da ADR-008, validado em parte) |

**Observações:**
- **Monitores:** o painel mostra **8/8**, mas o Kuma tem 9. O monitor push "Backup diário" não aparece no `/metrics` porque o Kuma só publica a métrica de um monitor push depois de receber um push desde o seu último reinício (reboot das 21:27); o próximo push vem com o backup das 03:35.
  - Isso é uma limitação da fonte: a API não tem como saber que existe um monitor que o `/metrics` não lista.
  - **PENDENTE:** confirmar 9/9 depois do backup.
- **Disco:** o painel mostra 33,3% de uso, contra 28% no `df`. O `statfs` conta como usados os 5% de blocos reservados ao root.
- **Bloqueio do painel do navegador:** uma requisição foi bloqueada pelo próprio painel do navegador do app (`ERR_NETWORK_ACCESS_DENIED`), não pela API, que respondeu 200 em 8 ms. A atualização automática seguinte veio completa, e o painel mostrou "API inacessível" só naquele cartão, sem inventar dados.

## Pendências de validação do M4.4 (registradas em 27/11/2026)

| # | Pendência | Estado |
|---|---|---|
| 1 | Próximo backup automático (28/11, ~03:35) e confirmação do push recebido pelo Kuma | PENDENTE DE VALIDAÇÃO |
| 2 | Retorno dos **9** monitores no Control (hoje 8/8: falta o push "Backup diário") | PENDENTE DE VALIDAÇÃO |
| 3 | Tratamento de monitores **esperados** e ausentes no `/metrics` (hoje um monitor ausente não gera alerta) | PLANEJADO |
| 4 | Alinhar o cálculo de disco ao `df` (descontar os blocos reservados ao root) | PLANEJADO |
| 5 | Monitoramento do próprio HomeLab Control (por exemplo, monitor no Kuma para `/api/health`) | PLANEJADO |
| 6 | Persistência do Control após reboot do Wyse (`restart: unless-stopped`) | PENDENTE DE VALIDAÇÃO (exige reboot autorizado) |
