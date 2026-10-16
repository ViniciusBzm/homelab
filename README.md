# HomeLab — aprendizado prático com infraestrutura de baixo custo

**Um servidor de R$ 350, problemas reais e documentação de cada etapa.**

Este repositório acompanha a construção de um laboratório doméstico com um **Dell Wyse 7020** e **Debian 12**. A ideia é aprender administração Linux, redes, SSH, containers, segurança e observabilidade com o hardware disponível — **sem tratar experimentos como produção, comprar upgrades sem necessidade ou afirmar que algo funciona antes de testar**.

O projeto começou pela preparação do sistema e pelo desafio de conectar o servidor usando um PC Windows. Em outubro de 2026, avancei até a instalação do Docker e a execução de containers leves, registrando tanto os resultados quanto os problemas que permaneceram abertos.

## Ambiente

| Item | Configuração / evidência |
|---|---|
| Servidor | Dell Wyse 7020, adquirido por R$ 350 |
| Processador | AMD GX-420CA (identificação anterior; reconferência futura opcional) |
| Memória | 6 GB nominais; **5,2 GiB** reportados pelo Debian |
| Armazenamento | 32 GB nominais; raiz com **29 GB** reportados |
| Sistema operacional | Debian 12 (Bookworm), `amd64` |
| Administração | SSH pelo PowerShell do Windows |
| Rede atual | Ethernet com compartilhamento de internet (ICS) do Windows — **provisório** |
| Containers | Docker Engine **29.9.1**, Docker Compose **v5.6.0** |

> **Valores medidos, não especificações prometidas:** na última medição após instalar o Docker, `free -h` mostrou **642 MiB** de RAM usada e **4,6 GiB** disponíveis; `df -h /` mostrou **6,2 GB** usados e **21 GB** livres. As leituras são instantâneas e anteriores ao download final do Alpine.

## Onde chegamos

| Marco | Situação | Evidência |
|---|---|---|
| **M0 — Debian e acesso** | **CONFIRMADO** na configuração testada | Atualizações, inicialização em modo texto e SSH validado após reinício |
| **M1 — Docker e containers** | **Experimentos CONFIRMADOS; marco ainda PENDENTE DE VALIDAÇÃO pós-reboot** | `hello-world`, Alpine, uso de recursos, parada e remoção |
| **M2 — Rede estável** | **PLANEJADO** | ICS ainda exige intervenção em algumas reinicializações |
| **M3 — Observabilidade e recuperação** | **PLANEJADO** | Nenhum monitoramento persistente instalado |
| **M4 — Serviços próprios e automação** | **PLANEJADO** | Sem aplicação implantada |
| **M5 — WristOps** | **PLANEJADO** | Ideia de integração por API; ainda sem protótipo |

### O que já testei de fato

- Atualização dos pacotes Debian e validação do kernel `6.1.0-53-amd64` após reinício.
- Administração por SSH em rede privada, incluindo correção de uma restrição de permissões de conexão do NetworkManager que afetava o acesso pós-boot.
- Instalação do Docker a partir do repositório oficial e serviço `docker` com status `active`.
- Execução de `hello-world`, com download e comunicação cliente–daemon confirmados.
- Execução de Alpine Linux 3.22 com `sleep infinity`; medição pontual de **0,00% de CPU** e **328 KiB de RAM** do container.
- Parada, remoção e conferência final: **nenhum container permaneceu criado**.

**Importante:** não hospedo serviços permanentes nesta etapa. Não publiquei portas dos containers; a rede ainda depende de uma solução provisória.

## Arquitetura atual

```mermaid
flowchart LR
    INTERNET["Internet / Wi-Fi doméstico"] --> PC["PC Windows"]
    PC -->|"ICS por Ethernet<br/>+ acesso SSH"| WYSE["Dell Wyse 7020<br/>Debian 12"]
    WYSE --> DOCKER["Docker Engine<br/>+ Compose"]
    DOCKER --> TESTES["Containers de teste<br/>finalizados e removidos"]
```

O compartilhamento de internet do Windows permitiu avançar sem investimento adicional, mas nem sempre recupera a saída para a internet após reiniciar o Wyse. O SSH e o acesso externo são validados separadamente. **Causa-raiz do ICS: ainda não identificada.**

[Entender a arquitetura e seus limites](docs/arquitetura.md)

## Documentação

| Documento | Conteúdo |
|---|---|
| [M0 — Base Debian, rede e SSH](docs/marcos/M0-base-debian-ssh.md) | Instalação, decisões de boot, atualizações e diagnóstico do acesso remoto |
| [M1 — Primeiro experimento com Docker](docs/marcos/M1-primeiro-experimento-docker.md) | Comandos executados, resultados de teste, consumo e limpeza |
| [Arquitetura atual](docs/arquitetura.md) | Diagrama, dependências, riscos e arquitetura futura proposta |
| [Roadmap e próximos passos](docs/proximos-passos.md) | Marcos verificáveis, pendências e próximos critérios de validação |

## O que estou aprendendo

**Linux e operação:** pacotes, serviços systemd, boot, uso de RAM/disco e diagnóstico.  
**Redes:** Ethernet, compartilhamento de conexão, IP/gateway/DNS, diferenciação entre SSH funcional e acesso à internet.  
**Containers:** imagens versus containers, daemon, ciclo de vida, Compose e monitoramento com `docker stats`.  
**Prática profissional:** reproduzir erros, manter acesso de recuperação, documentar evidências e não mascarar pendências.

## Próximo desafio

Com acesso local disponível, verificar o retorno do **Docker após reboot** e estudar por que a internet do Wyse nem sempre retorna automaticamente pela ponte Windows. Depois, decidir se e quando a topologia deve mudar antes de receber serviços persistentes.

Este laboratório é um ambiente de estudo. **Não é produção nem uma promessa de disponibilidade 24/7.** O objetivo é crescer tecnicamente com decisões justificadas e resultados que outras pessoas possam reproduzir.

---

**Última atualização documental:** 16 de outubro de 2026 · **Estado:** etapas iniciais validadas; conectividade pós-reboot e teste de reinício Docker ainda pendentes.

**Referências oficiais:** [Debian](https://www.debian.org/) · [Docker Engine no Debian](https://docs.docker.com/engine/install/debian/) · [Docker Compose](https://docs.docker.com/compose/)
