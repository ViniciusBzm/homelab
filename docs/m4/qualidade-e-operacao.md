# M4 — Testes, implantação e recuperação

## Testes

| Camada | Ferramenta | O que cobre | Onde roda |
|---|---|---|---|
| Tipos | `tsc --noEmit` | Todo o monorepo (strict) | PC |
| Unidade | Vitest | Parsers (`/proc`, hwmon, status do backup, `/metrics` do Kuma, JSON do Docker): casos válidos, vazios, corrompidos e ausentes | PC |
| Contrato | Vitest + Zod | Toda resposta passa pelo schema; os JSON Schemas gerados conferem com o snapshot | PC |
| API | Vitest + `fastify.inject` | Rotas com fontes falsas: envelope, degradação por fonte, timeout, cache, ausência de rotas de escrita, erros sem detalhes internos | PC |
| Ponta a ponta | Playwright (Chromium) | Painel com API em modo *fixtures*: cartões, estado indisponível, atualização periódica | PC (M4.3) |
| Implantação | Script + `curl` | Healthcheck, rotas `v1` no servidor real, limites, contêiner não-root, persistência após reboot | Wyse (M4.4, com autorização) |

**Regras:**
- **Fixtures:** só com dados sintéticos (faixas da RFC 5737, nomes genéricos).
- **Isolamento:** nenhum teste depende do servidor ou da rede.
- **Comando único:** `npm test` roda typecheck, unidade, contrato e API.
- **Antes de cada commit em `apps/` ou `packages/`:** os testes de infraestrutura que já existem (`tests/server`) continuam valendo para `scripts/`.

## Implantação (a partir do M4.4)

1. **Build no Wyse:**
   - a partir de um commit revisado da `main`: `docker compose -f stacks/control/compose.yaml build`;
   - multi-stage: primeiro `npm ci` e o build dos workspaces, depois a imagem final;
   - tag `homelab-control:<commit-curto>`.

   O PC não tem Docker (SVM desligada), então o build é no Wyse.
2. **Script `scripts/server/homelab-control-deploy.sh`,** executado com sudo numa janela visível, como os demais:
   - confere o commit;
   - faz o build;
   - grava a tag em `.env`;
   - roda `docker compose up -d`;
   - espera o healthcheck;
   - valida as rotas;
   - em caso de falha, volta à tag anterior.
3. **Persistência:** stack em `/opt/homelab/stacks/control` com `restart: unless-stopped` e a rede `monitoring` como externa. Não altera a stack de observabilidade.
4. **Monitoramento:** a pessoa cria um monitor HTTP no Kuma para `http://homelab-control:8088/api/health`.
5. **Validação:** a mesma régua do M3 (contêiner saudável, limites, usuário não-root, sem porta na LAN e reboot com retorno sozinho), com as evidências em `docs/m4/`.

## Recuperação

- **Sem estado no início:** a API não guarda dados; tudo é reconstruído a partir do Git.
- **Backup:**
  - a configuração local (`.env` e `secrets/`) fica em `/opt/homelab/stacks/control`, já incluída no `BACKUP_PATHS` do restic;
  - não precisa pausar o serviço durante o backup.
- **Rollback de versão:** voltar à tag anterior da imagem em `.env` e rodar `docker compose up -d`. O deploy mantém as duas últimas imagens.
- **Remoção completa:** `docker compose down` na stack do control. Nada mais no host depende dela.
- **Quando houver SQLite (histórico):** entra no restic, com o mesmo padrão de pausa e de teste de restauração do Kuma e do Beszel. Isso exige um novo ADR.
