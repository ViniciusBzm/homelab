# Roadmap do HomeLab

**Revisão:** 27/11/2026  
**Princípio:** pequenos marcos, evidências antes de conclusões e nenhum upgrade prematuro.

## Marcos

| Marco | Escopo | Estado |
|---|---|---|
| **M0 — Base Linux e SSH** | Debian, boot texto, acesso SSH e medições | **CONFIRMADO** (a falha de internet pós-boot foi resolvida no M2) |
| **M1 — Docker e containers** | Docker Engine, Compose, teste, métricas e limpeza | **CONFIRMADO**, inclusive o retorno após reboot (27/11) |
| **M2 — Rede previsível e segurança base** | ICS, hora, SSH só por chave, firewall + portas do Docker, rollback, atualizações automáticas ([registro](marcos/M2-rede-seguranca-automacao.md)) | **CONFIRMADO**, inclusive após o reboot do Wyse; **PENDENTE** só a validação após reiniciar o **PC Windows** |
| **M3 — Observabilidade e recuperação** | Beszel, Uptime Kuma, alertas, backup restic, restauração, chave de recuperação ([registro](marcos/M3-observabilidade-backup.md), [plano](plano-monitoramento-automacao-backup.md)) | **EM ANDAMENTO**: stack e backup **CONFIRMADOS**; painéis, alertas e reboot **PENDENTES** |
| **M4 — Aplicações e automação** | API/serviço pequeno, deployment controlado e diagnóstico | **PLANEJADO** |
| **M5 — WristOps** | Prova de conceito de consulta de dados do lab por relógio | **PLANEJADO** |
| **2027 — Revisão de capacidade** | Considerar troca de hardware somente mediante medições e necessidade real | **ADIADO** |

> A ordem é orientativa e poderá mudar conforme os riscos de rede, armazenamento e acesso.

## Próxima sessão — sequência prudente

**Ponto de retomada (27/11/2026):** concluir o M3. Ao ligar o Wyse, conferir primeiro SSH, internet e os dois painéis (`:8090` e `:3001`).

1. Criar as contas de administrador do **Beszel** e do **Uptime Kuma** (feito pela pessoa).
2. No Beszel: "Add System" pelo socket `/beszel_socket/beszel.sock`; gravar a chave e o token em `stacks/monitoring/secrets/`; confirmar o agente conectado, o histórico, os containers e o S.M.A.R.T.
3. No Uptime Kuma: monitores HTTP (Beszel, Kuma), TCP 22 do host, DNS, internet, containers via socket-proxy e um monitor **push** do backup.
4. Alertas por ntfy (tópico aleatório, fora do Git) no Beszel e no Kuma; disparar um alerta de teste.
5. Testar o login com a **chave de recuperação** e guardá-la fora do PC.
6. Restaurar a partir da **cópia externa** (`HomeLab-Backups` no PC) e comparar.
7. Reiniciar o Wyse e provar que a stack volta sozinha.
8. Abrir o pull request consolidado para a `main`.

**Pendências sem prazo:** validar o ICS após reiniciar o PC Windows; trocar a senha antiga do administrador; trocar a bateria CMOS; habilitar a virtualização (SVM) na BIOS do PC, se quiser usar WSL2 ou Docker Desktop.

## Decisões vigentes

- **CONFIRMADO:** Dell Wyse 7020 adquirido por R$ 350 e usado como servidor inicial até o fim de 2026, sujeito a reavaliação baseada em dados.
- **CONFIRMADO:** Debian 12 e Docker Engine/Compose são a base atual.
- **DESCARTADO/ADIADO:** instalar CasaOS apenas para adicionar interface visual; não é requisito para aprender Docker.
- **ADIADO:** NAS e servidor Minecraft, sem capacidade nem estratégia de armazenamento comprovadas para esses casos.
- **PLANEJADO:** integração por API e eventual projeto WristOps, sem implementação atual.
- **ADIADO:** compra de switch ou outro servidor até que necessidade e topologia estejam justificadas.

## Critérios de segurança e aprendizado

- Um comando ou mudança por vez, sempre conferindo a saída.
- Nunca considerar **PLANEJADO** como **CONFIRMADO**.
- Para rede, SSH, usuários, firewall, boot ou disco: ter recuperação local.
- Não expor containers à internet por padrão.
- Não publicar credenciais, endereços internos ou capturas contendo informações privadas.
- Não caracterizar o laboratório como ambiente de produção ou prometer disponibilidade permanente.

## Referências

- [Debian Bookworm](https://www.debian.org/releases/bookworm/)
- [Instalação oficial do Docker no Debian](https://docs.docker.com/engine/install/debian/)
- [Documentação do Docker Compose](https://docs.docker.com/compose/)

---

**Documentação da execução:** [M0](marcos/M0-base-debian-ssh.md) e [M1](marcos/M1-primeiro-experimento-docker.md). O estado é um registro das sessões, não coleta contínua.
