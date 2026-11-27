# Arquitetura atual do HomeLab

> **Registro de 16/10/2026.** A topologia a seguir mostra a conexão utilizada nos testes, não uma infraestrutura de produção.

## Topologia em uso

```mermaid
flowchart TD
  WAN["Internet / provedor"] --> R["Roteador doméstico / Wi-Fi"]
  R --> PC["PC Windows - administração"]
  PC -->|"ICS via Ethernet"| WYSE["Dell Wyse 7020 - Debian 12"]
  PC -.->|"SSH pela rede privada"| WYSE
  WYSE --> D["Docker Engine e Compose"]
  D --> T["Containers temporários de teste - removidos"]
```

**Leitura correta:** o PC recebe internet pela rede doméstica e a compartilha com o Wyse pela Ethernet. O SSH utilizado parte do próprio PC. O Wi-Fi do Wyse não é o caminho de conectividade empregado. O fluxo é **provisório** e depende do Windows.

## Componentes confirmados

| Camada | Implementação observada | Situação |
|---|---|---|
| Hardware | Dell Wyse 7020, 6 GB RAM nominais, 32 GB de armazenamento nominal | **CONFIRMADO** |
| Sistema | Debian 12 Bookworm, modo texto por padrão, GNOME ainda instalado | **CONFIRMADO** |
| Acesso | SSH a partir do PowerShell no Windows | **CONFIRMADO**, inclusive em teste de reboot sem login local |
| Rede | Ethernet com ICS do Windows | **CONFIRMADO** na sessão |
| Containers | Docker Engine e Compose instalados e testados | **CONFIRMADO** |
| Segurança | SSH só por chave; nftables drop + bloqueio de portas do Docker; guard de reversão | **CONFIRMADO** (M2, após reboot) |
| Observabilidade | Beszel 0.21.2 + Uptime Kuma 2.5.12 + socket-proxy (`stacks/monitoring`), só na LAN | **IMPLANTADO**; configuração dos painéis **PENDENTE** (M3) |
| Backup | restic diário + restauração mensal testada + cópia pull no PC | **CONFIRMADO** (primeiro ciclo, 27/11) |
| Aplicações permanentes | Apenas a stack de monitoramento | — |

O diagrama da stack de observabilidade e do fluxo de backup está no [M3](marcos/M3-observabilidade-backup.md#arquitetura-implantada). As decisões estão em [decisões (ADRs)](decisoes/).

### Como a rede foi diagnosticada

- O compartilhamento pelo Windows permitiu acesso ao Wyse e download de pacotes/imagens.
- Em reinicializações do Wyse, houve episódios de SSH funcional, mas **sem internet externa** no servidor.
- O serviço de compartilhamento do Windows continuava ativo; reiniciá-lo pelo PowerShell não solucionou o problema.
- **Solução temporária observada:** desligar e religar a opção de compartilhamento na interface Wi-Fi do Windows, restaurando a navegação do Wyse nas ocasiões testadas.
- **CONFIRMADO (26/11/2026):** a causa-raiz é o ICS não persistir após reiniciar (falta de `EnableRebootPersistConnection`, KB4055559) somado a um estado "configurado mas sem NAT/DNS". A correção foi o valor no Registro, o serviço em Automático e um watchdog agendado que testa o DNS do ICS e reaplica o compartilhamento. Detalhes no [M2](marcos/M2-rede-seguranca-automacao.md).
- **PENDENTE DE VALIDAÇÃO:** recuperação automática depois de reiniciar o PC Windows.

O problema de internet do ICS não deve ser confundido com o estado do daemon SSH ou com falha do Docker. O repositório não publica endereços internos, nomes de usuário, MACs nem credenciais.

## Segurança e limites

- Nenhuma porta de container foi publicada nos experimentos.
- Nenhum encaminhamento de porta da internet foi configurado para este projeto.
- A administração é feita por SSH em rede privada, com monitor e teclado locais disponíveis durante mudanças arriscadas.
- **Desde o M2:** SSH só por chave pública e root bloqueado; firewall `nftables` com política drop na entrada (SSH aceito só de faixas privadas); atualizações automáticas de segurança.
- Não foi comprovada disponibilidade contínua ou retorno automático da internet após cada reinício.
- As versões e medições são específicas das sessões; não são monitoramento em tempo real.

## Arquitetura desejada — ainda não implementada

```mermaid
flowchart TD
  R["Rede doméstica / roteador"] -->|"Conexão cabeada a definir"| W["Wyse 7020"]
  A["PC ou dispositivo autorizado"] -.->|"SSH na rede local"| W
  W --> C["Serviços leves com recursos e backup definidos - planejados"]
```

O plano é retirar a dependência do compartilhamento de internet do Windows quando houver uma conexão física adequada, sem comprar hardware antes de demonstrar a necessidade.

**Não confundir intenção com implantação:** VPN, NAS, DNS doméstico, monitoramento contínuo e Minecraft não operam neste laboratório conforme as evidências atuais.

## Documentos relacionados

- [M0 — Base Debian e SSH](marcos/M0-base-debian-ssh.md)
- [M1 — Primeiro experimento com Docker](marcos/M1-primeiro-experimento-docker.md)
- [Próximos passos](proximos-passos.md)
