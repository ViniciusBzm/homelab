# ADR-008 — HomeLab Control: API read-only e painel num único contêiner

**Data:** 27/11/2026 · **Estado:** Proposta (M4.0, em revisão)

## Contexto
O M4 inaugura o desenvolvimento de aplicações no HomeLab. O primeiro produto é o **HomeLab Control**, que mostra o estado do servidor e que no futuro será consumido pelo WristOps.

Restrições do ambiente:
- CPU fraco (AMD GX-420CA) e cerca de 5 GiB de RAM úteis;
- teto de cerca de 2 GiB para todos os contêineres;
- PC sem Docker;
- nada exposto à internet;
- sudo com senha;
- infraestrutura do M3 congelada.

## Decisão
1. **Stack:**
   - TypeScript em tudo;
   - **Fastify + Zod** na API;
   - **React + Vite + Tailwind** na interface;
   - **Vitest** e **Playwright** nos testes;
   - **npm workspaces** no repositório existente.
2. **Contratos:** schemas Zod em `packages/contracts`, usados pela API, pela interface e exportados como JSON Schema para clientes externos. `/api/v1` só recebe mudanças aditivas.
3. **Somente leitura:** apenas rotas `GET`. As fontes são arquivos `:ro`, o socket-proxy que já existe (sem POST) e o `/metrics` do Kuma, com chave de API.
4. **Um contêiner** serve a API e o front-end estático. Ele não é root, roda com sistema de arquivos `read_only` e `cap_drop ALL`, e publica só em `127.0.0.1`.
5. **Sem porta na LAN até haver autenticação por token** (M4.5). Até lá, o acesso é por túnel SSH.
6. **Adiados:** SQLite, PostgreSQL, Caddy, CI/CD e qualquer ação de escrita. Cada um entra com o incremento que precisar dele, e as ações de escrita exigem um ADR próprio.

## Alternativas descartadas
- **Ler o `docker.sock` diretamente:** daria à API controle total do Docker. O socket-proxy já existe e bloqueia escrita.
- **Pegar as métricas do host pelo Beszel:** exigiria mais uma credencial. `/proc` e `/sys` dão o mesmo dado "agora" sem segredo, e o histórico continua no Beszel.
- **Front-end num contêiner separado (Nginx) ou atrás do Caddy agora:** seria mais memória e configuração sem ganho enquanto o acesso é local. O Caddy entra com TLS e LAN.
- **pnpm ou Turborepo:** ferramenta extra sem ganho nesta escala; npm workspaces bastam.
- **Build da imagem no PC:** impossível sem Docker (SVM desligada na BIOS). O build é no Wyse, fora da janela do backup.

## Consequências
- **Riscos baixos:** um só processo Node (cerca de 100 MiB) e nenhuma porta nova até o M4.5.
- **Contratos estáveis:** permitem desenvolver o WristOps em paralelo, usando os JSON Schemas e as *fixtures*.
- **Build no Wyse:** é lento (minutos), mas raro.
- **Cuidado ao mudar os scripts de backup:** a fonte "backup" depende de os arquivos de status serem regravados no mesmo inode. Se isso mudar, a montagem precisa mudar para o diretório.
