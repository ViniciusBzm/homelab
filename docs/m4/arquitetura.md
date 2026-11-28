# M4 — Arquitetura do HomeLab Control

## Visão geral

```
 PC (navegador) ──ssh -L──►  127.0.0.1:8088  ┌──────────── contêiner homelab-control ────────────┐
 WristOps (M4.5+) ─token──►  (LAN só no M4.5) │ Fastify  /api/*  +  front-end estático (React)    │
                                              │  ├─ fonte host    ← /proc, /sys (ro), statfs       │
                                              │  ├─ fonte backup  ← /var/backups/homelab-*.status:ro│
                                              │  ├─ fonte docker  → http://socket-proxy:2375 (GET)  │
                                              │  └─ fonte monitors→ http://uptime-kuma:3001/metrics │
                                              └───────── rede Docker "monitoring" (externa) ───────┘
```

## API

- **Respostas validadas** pelo schema Zod antes do envio. Uma resposta fora do contrato vira 500 genérico, e o detalhe só aparece no log.
- **Somente `GET`.** Um teste garante que não existe rota de outro método.
- **Rotas:**
  - `GET /api/health`: liveness. Não consulta nenhuma fonte e não exige autenticação.
  - `GET /api/v1/summary`: estado geral (`ok`, `degraded` ou `down`) e o estado de cada fonte.
  - `GET /api/v1/host`: carga, CPU (contagem e load), memória, disco do `/`, temperaturas e uptime.
  - `GET /api/v1/containers`: nome, imagem, estado, saúde e "desde". **Só** a lista do `/containers/json`; nunca `inspect`, variáveis de ambiente, labels ou montagens.
  - `GET /api/v1/monitors`: nome, tipo e estado de cada monitor (UP, DOWN, PENDING ou MAINTENANCE).
  - `GET /api/v1/backup`: último backup (estado, data, snapshot, tamanho) e último teste de restauração.
- **Envelope único:**
  ```json
  { "data": { … },
    "meta": { "apiVersion": "1", "generatedAt": "2026-11-27T21:00:00Z",
              "sources": [ { "name": "backup", "ok": true, "ageSeconds": 4, "error": null } ] } }
  ```
- **Falhas:**
  - uma fonte com problema responde **200** com `data: null` e `sources[].ok=false`;
  - a API só responde 5xx para erro interno;
  - os erros usam um formato único: `{ "error": { "code", "message" } }`, sem stack trace nem caminho interno.
- **Proteção do CPU fraco:**
  - cada fonte tem cache em memória (TTL de 10 s para host e contêineres, 30 s para monitores e backup);
  - timeout de 3 s por fonte;
  - deduplicação de chamadas simultâneas.
- **Versionamento:**
  - `/api/v1` só recebe campos novos e opcionais;
  - uma mudança que quebre clientes cria `/api/v2`;
  - os JSON Schemas ficam em `packages/contracts/dist/schemas/`.

## Integração com os serviços existentes

| Fonte | Como | Por que é segura |
|---|---|---|
| Host | `/proc/loadavg`, `/proc/meminfo` e `/proc/uptime` (mostram os valores do host); `/sys/class/hwmon/*/temp*_input` (sysfs já é `ro` no contêiner); `statfs` num arquivo montado do `/` | Nenhum privilégio e nenhum *bind* do `/` inteiro |
| Backup | *Bind* `:ro` **só** de `/var/backups/homelab-backup.status` e `homelab-restore-test.status` (0644, regravados no mesmo inode) | Não monta o repositório restic, a senha nem o export. Se os scripts passarem a usar troca atômica, montar o diretório de status |
| Contêineres | `http://socket-proxy:2375/containers/json` pela rede `monitoring` (externa) | O proxy já recusa escrita (`POST: 0`). A API filtra os campos numa lista permitida e não usa `inspect` |
| Monitores | `GET http://uptime-kuma:3001/metrics` com uma chave de API do Kuma (Basic, senha = chave) | A chave fica em arquivo de segredo (fora do Git, `0600`). O `/metrics` é só leitura. A pessoa cria a chave na interface do Kuma (M4.2/M4.4) |
| Beszel | Não usado no M4 inicial | Evita uma credencial a mais; o histórico continua no Beszel |

## Interface (M4.3)

- **Tecnologia:** React, Vite, TypeScript e Tailwind.
- **Painel único:** um cartão por fonte (host, contêineres, monitores e backup), com indicador de "dados de X s atrás" e de fonte indisponível.
- **Dados:** `fetch` com os tipos de `contracts`, atualizando a cada 15 s. Sem biblioteca de estado e sem roteador enquanto houver uma única página.
- **Entrega:** o build estático é servido pela API (`@fastify/static`), sem CDN e sem recursos externos.

## Organização do repositório

```
apps/control-api/      src/{server.ts,config.ts,routes/v1/*.ts,sources/*.ts}  test/  fixtures/
apps/control-web/      src/  e2e/ (Playwright)
packages/contracts/    src/*.ts (Zod) → dist/ (tipos + JSON Schema)
stacks/control/        compose.yaml  .env.example  (M4.4)
scripts/server/        homelab-control-deploy.sh (M4.4)
docs/m4/               este planejamento e os registros de cada incremento
```

- **Dependências:** versões fixadas no `package-lock.json`, `npm ci` em todo lugar e Node 22 LTS (`.nvmrc`).
- **Tipos:** TypeScript `strict`; `tsc --noEmit` na raiz.

## Segurança

- **Contêiner:**
  - usuário não-root (`node`);
  - sistema de arquivos `read_only: true` com `tmpfs` em `/tmp`;
  - `cap_drop: [ALL]` e `no-new-privileges`;
  - sem `docker.sock`: só o socket-proxy.
- **Rede:**
  - publica só `127.0.0.1:8088` até o M4.5;
  - a liberação na LAN passa pelo `firewall.conf` e pelo `homelab-apply` (com guard), e exige autenticação por token ativa.
- **Autenticação (M4.5):**
  - token *bearer* por cliente, guardado como hash, com escopo `read`;
  - limite de requisições (`@fastify/rate-limit`);
  - a interface local continua acessível pelo túnel.
- **Sem dados sensíveis:**
  - as respostas nunca trazem IP, MAC, usuário, tokens ou URLs de push;
  - o hostname fica num campo `label` configurável.
- **Logs:**
  - o *logger* (pino) redige `authorization` e `cookie`;
  - não registra corpo de resposta;
  - usa a rotação do Docker que já existe (10 MB × 3).
- **Cabeçalhos:** CSP restrita (`default-src 'self'`), `X-Content-Type-Options` e `Referrer-Policy`.
- **Supply chain:**
  - `npm audit` no fluxo de testes;
  - imagem base com tag fixa (`node:22-alpine` com versão exata);
  - build multi-stage, com a imagem final só com as dependências de produção.

## Orçamento de recursos

**Situação atual:** os contêineres usam cerca de 210 MiB, com limites que somam 832 MiB. O teto do projeto é de cerca de 2 GiB para todos os contêineres, e o `/` deve ficar abaixo de 70% (hoje está em 28%).

| Item | Orçamento |
|---|---|
| Contêiner `homelab-control` | `mem_limit: 160m`, `cpus: 0.5`; alvo de menos de 100 MiB de RSS em repouso |
| Imagem | Menos de 250 MB (alpine, só dependências de produção) |
| CPU em repouso | Menos de 2% (cache + front-end com *polling* de 15 s) |
| Build no Wyse (M4.4) | Pontual; feito fora do horário do backup (03:30–03:40) |
