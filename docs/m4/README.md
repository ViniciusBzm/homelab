# M4 — HomeLab Development Platform

**Estado:** M4.0 **APROVADO** (ADR-008 aceita) · M4.1 **APROVADO** · M4.2 **IMPLEMENTADO**, em revisão · **Data:** 27/11/2026 · Branch `feat/m4-development-platform`

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
npm run dev            # API em 127.0.0.1:8088 com fixtures e Docker/Kuma SIMULADOS (nada real)
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
