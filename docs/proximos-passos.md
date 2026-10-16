# Roadmap do HomeLab

**Revisão:** 16/10/2026  
**Princípio:** pequenos marcos, evidências antes de conclusões e nenhum upgrade prematuro.

## Marcos

| Marco | Escopo | Estado |
|---|---|---|
| **M0 — Base Linux e SSH** | Debian, boot texto, acesso SSH e medições | **CONFIRMADO** para a configuração testada; rede externa pós-boot ainda falha intermitentemente |
| **M1 — Docker e containers** | Docker Engine, Compose, teste, métricas e limpeza | **PENDENTE DE VALIDAÇÃO** do retorno do serviço após reboot; primeiros experimentos **CONFIRMADOS** |
| **M2 — Rede previsível** | Eliminar, se viável, dependência do ICS e validar comunicação após boot | **PLANEJADO** |
| **M3 — Observabilidade e recuperação** | Checks úteis, logs, alertas pontuais e backup testado | **PLANEJADO** |
| **M4 — Aplicações e automação** | API/serviço pequeno, deployment controlado e diagnóstico | **PLANEJADO** |
| **M5 — WristOps** | Prova de conceito de consulta de dados do lab por relógio | **PLANEJADO** |
| **2027 — Revisão de capacidade** | Considerar troca de hardware somente mediante medições e necessidade real | **ADIADO** |

> A ordem é orientativa e poderá mudar conforme os riscos de rede, armazenamento e acesso.

## Próxima sessão — sequência prudente

**Primeiro passo:** com monitor e teclado à disposição, ligar/reiniciar o Wyse e testar acesso SSH, internet externa do Debian e serviço Docker **separadamente**. Confirmar os resultados antes de alterar a configuração.

Em seguida:

1. Validar que o Docker inicia após reboot e que o Compose continua acessível.
2. Investigar a recuperação do ICS sem atribuir antecipadamente o problema a um único componente.
3. Registrar medições atualizadas de memória, armazenamento e imagens do Docker.
4. Planejar um serviço leve que resolva problema real, com limite de recursos, registro de logs e critério de remoção.
5. Só então considerar observabilidade, recuperação e persistência.

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
