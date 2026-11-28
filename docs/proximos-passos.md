# Roadmap do HomeLab

**Revisão:** 27/11/2026  
**Princípio:** pequenos marcos, evidências antes de conclusões e nenhum upgrade prematuro.

## Marcos

| Marco | Escopo | Estado |
|---|---|---|
| **M0 — Base Linux e SSH** | Debian, boot texto, acesso SSH e medições | **CONFIRMADO** (a falha de internet pós-boot foi resolvida no M2) |
| **M1 — Docker e containers** | Docker Engine, Compose, teste, métricas e limpeza | **CONFIRMADO**, inclusive o retorno após reboot (27/11) |
| **M2 — Rede previsível e segurança base** | ICS, hora, SSH só por chave, firewall + portas do Docker, rollback, atualizações automáticas ([registro](marcos/M2-rede-seguranca-automacao.md)) | **CONFIRMADO**, inclusive após o reboot do Wyse e o boot do **PC Windows** (27/11) |
| **M3 — Observabilidade e recuperação** | Beszel, Uptime Kuma, alertas, backup restic, restauração local e externa, chave de recuperação, troca de senha ([registro](marcos/M3-observabilidade-backup.md), [plano](plano-monitoramento-automacao-backup.md)) | **CONFIRMADO** (27/11); restam ações físicas |
| **M4 — HomeLab Development Platform** | HomeLab Control: API read-only e painel, contratos para o WristOps, deploy controlado ([planejamento](m4/README.md)) | **M4.0 EM REVISÃO** (arquitetura) |
| **M5 — WristOps** | Prova de conceito de consulta de dados do lab por relógio | **PLANEJADO** |
| **2027 — Revisão de capacidade** | Considerar troca de hardware somente mediante medições e necessidade real | **ADIADO** |

> A ordem é orientativa e poderá mudar conforme os riscos de rede, armazenamento e acesso.

## Próxima sessão — sequência prudente

**M3 concluído em 27/11/2026.** Próximo marco: **M4**, o primeiro serviço útil, já nascendo com Compose, versão fixa, limites, healthcheck, backup, monitor no Kuma e porta liberada só na LAN.

**Ações físicas da pessoa:**
- guardar a chave de recuperação num pendrive ou gerenciador de senhas e apagá-la do PC;
- assinar o tópico ntfy no celular;
- trocar a bateria CMOS (CR2032) do Wyse.

**Sem prazo:**
- imagem completa do pendrive com Clonezilla;
- habilitar a SVM na BIOS do PC (para WSL2 ou Docker Desktop);
- avaliar ligar o Wyse direto no roteador, eliminando o ICS.

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
