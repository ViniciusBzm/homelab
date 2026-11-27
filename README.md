# HomeLab — Debian, rede e Docker em hardware de baixo custo

Uso um Dell Wyse 7020 com Debian 12 para praticar administração Linux, acesso remoto, diagnóstico de rede e containers. O repositório registra comandos, decisões e resultados de cada marco.

## Estado atual

| Marco | Resultado observado | Registro |
|---|---|---|
| M0 — base Debian e SSH | Sistema atualizado; acesso SSH a partir do Windows validado após reinício | [Passos e diagnóstico](docs/marcos/M0-base-debian-ssh.md) |
| M1 — Docker | Engine instalado e ativo; `hello-world` e Alpine executados; containers encerrados e removidos | [Comandos e medições](docs/marcos/M1-primeiro-experimento-docker.md) |
| M2 — rede, hora e segurança | Causa-raiz do ICS identificada e corrigida com um watchdog; hora sincronizada; SSH só por chave; firewall nftables; atualizações automáticas de segurança | [Diagnóstico e validação](docs/marcos/M2-rede-seguranca-automacao.md) |
| Próxima verificação | Reiniciar o PC e o Wyse e conferir ICS, firewall, SSH e Docker depois do boot | [Critérios pendentes](docs/proximos-passos.md) |

O laboratório ainda usa o compartilhamento de internet do Windows pela Ethernet. A falha "SSH funciona, internet não" tinha duas causas: o ICS não persistia após reiniciar (KB4055559) e às vezes ficava marcado como ativo sem funcionar. Agora uma tarefa agendada detecta e reaplica o compartilhamento sozinha. A validação após reiniciar o PC ainda está pendente.

## Ambiente e arquitetura

- **Hardware:** Dell Wyse 7020, adquirido por R$ 350; 6 GB de RAM e 32 GB de armazenamento nominais.
- **Sistema:** Debian 12 (`amd64`), administrado por SSH no PowerShell do Windows.
- **Containers:** Docker Engine 29.9.1 e Docker Compose v5.6.0 nas sessões documentadas.
- **Rede:** PC Windows compartilha a conexão por Ethernet com o servidor; topologia provisória.

```mermaid
flowchart LR
    INTERNET["Internet"] --> PC["PC Windows"]
    PC -->|"Ethernet com ICS<br/>e SSH"| WYSE["Wyse 7020<br/>Debian 12"]
    WYSE --> DOCKER["Docker Engine"]
    DOCKER --> TESTES["Containers temporários<br/>finalizados"]
```

[Arquitetura detalhada e limites da rede](docs/arquitetura.md)

## Decisões e resultados

- Mantive o hardware disponível e medi os recursos antes de planejar upgrades. Após instalar o Docker, o Debian reportou **5,2 GiB** de RAM utilizável; a medição pontual mostrou **642 MiB** usados e **21 GB** livres na partição raiz.
- Separei problemas de SSH e de acesso externo durante o diagnóstico de reinicialização. A correção de permissões no NetworkManager permitiu recuperar o acesso remoto. Em novembro, a falha intermitente do compartilhamento de internet foi rastreada até o ICS do Windows ([M2](docs/marcos/M2-rede-seguranca-automacao.md)).
- Fechei o servidor sem perder o acesso: SSH só por chave, root bloqueado e firewall com política drop. Essas mudanças entraram protegidas por uma reversão automática de 10 minutos, desarmada só depois de validar o login.
- Validei o ciclo de vida de containers com `hello-world` e Alpine Linux 3.22. Na medição registrada, o container Alpine consumiu **328 KiB de RAM** e **0,00% de CPU**. Nenhum container de teste permaneceu criado.

Os números acima são das sessões documentadas em outubro de 2026, não métricas contínuas. Ainda não há aplicação hospedada nem serviço permanente neste laboratório.

## Próximo passo

Reiniciar o Wyse no kernel novo e o PC Windows, e conferir ICS, firewall, SSH e Docker depois do boot. Em seguida, decidir uma topologia de rede menos dependente do PC Windows. Os marcos de observabilidade, recuperação e hospedagem estão no [roadmap](docs/proximos-passos.md).

**Registros completos:** [M0 — Debian e SSH](docs/marcos/M0-base-debian-ssh.md) · [M1 — Docker](docs/marcos/M1-primeiro-experimento-docker.md) · [M2 — Rede, hora e segurança](docs/marcos/M2-rede-seguranca-automacao.md) · [Arquitetura](docs/arquitetura.md) · [Scripts](scripts/)
