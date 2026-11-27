# Scripts do HomeLab

Scripts usados no [M2](../docs/marcos/M2-rede-seguranca-automacao.md). Leia antes de rodar, porque eles mudam a configuração do sistema. Todos podem ser reexecutados.

| Script | Onde | Como rodar | Função |
|---|---|---|---|
| [`windows/setup-ics-persistent.ps1`](windows/setup-ics-persistent.ps1) | PC Windows | PowerShell **como administrador**, uma vez: `.\setup-ics-persistent.ps1 -LogPath .\setup-ics.log` | ICS persistente (Registro + serviço) e cria a tarefa do watchdog |
| [`windows/ics-watchdog.ps1`](windows/ics-watchdog.ps1) | PC Windows | Pela tarefa `\HomeLab\HomeLab ICS Watchdog` (SYSTEM, no boot e a cada 5 min) | Reaplica o ICS Wi-Fi → Ethernet quando ele some ou para de responder. Não mexe nos adaptadores `vEthernet` (Hyper-V/WSL) |
| [`server/homelab-apply.sh`](server/homelab-apply.sh) | Servidor (Debian 12) | `sudo bash homelab-apply.sh <usuario-admin> [--guard-minutes N] [--skip-upgrade]` | Hora, atualizações, SSH só por chave, firewall nftables (entrada + portas do Docker) e limites de log |
| [`server/homelab-postboot-check.sh`](server/homelab-postboot-check.sh) | Servidor | `sudo bash homelab-postboot-check.sh <usuario-admin>` | Testa o rollback de verdade, reaplica a configuração e testa Docker, Compose e o bloqueio de portas publicadas |
| [`server/homelab-m3-deploy.sh`](server/homelab-m3-deploy.sh) | Servidor | `sudo bash homelab-m3-deploy.sh <usuario-admin> <clone-do-repo>` | M3: restic, smartmontools, stack `stacks/monitoring`, portas na LAN, backup, timers, primeiro backup e teste de restauração |
| [`server/homelab-backup.sh`](server/homelab-backup.sh) | Servidor | `homelab-backup.timer` (03:30) ou `sudo systemctl start homelab-backup` | Backup restic com retenção, `check` e permissões para a cópia pull |
| [`server/homelab-restore-test.sh`](server/homelab-restore-test.sh) | Servidor | `homelab-restore-test.timer` (mensal) | Restaura num diretório temporário e compara byte a byte |
| [`server/homelab-external-restore-test.sh`](server/homelab-external-restore-test.sh) | Servidor | `sudo bash homelab-external-restore-test.sh <copia-do-repo>` | Abre uma **cópia externa** com a senha digitada pela pessoa, roda `check --read-data`, restaura e compara |
| [`windows/pull-homelab-backup.ps1`](windows/pull-homelab-backup.ps1) + [`register-backup-pull.ps1`](windows/register-backup-pull.ps1) | PC Windows | `.\register-backup-pull.ps1` (usuário, sem admin) | Tarefa diária que copia o repositório restic (atual + anterior) |

| [`server/homelab-guard-rollback.sh`](server/homelab-guard-rollback.sh) | Servidor | Pelo timer transitório do guard | Mantém as mudanças se confirmadas; senão restaura o snapshot (com o mesmo lock do apply) |
| [`server/lib/`](server/lib/) | Servidor | Usadas pelos scripts (`/usr/local/lib/homelab`) | `common` (log seguro, config sem `source`, lock, códigos de saída), `guard`, `firewall`, `restore` |
| [`windows/HomeLabBackup.psm1`](windows/HomeLabBackup.psm1) | PC Windows | Usado pelo pull | Validação do manifesto e rotação (testável) |

Testes: [`../tests/`](../tests/). Logs de root ficam em `/var/log/homelab/` (grupo do administrador).

## Proteções do `homelab-apply.sh`

> A revisão do PR #2 (ADR-007) acrescentou: lock contra execuções simultâneas, recusa com guard pendente (código 5), validação completa antes de tocar em qualquer coisa, reversão **imediata** em falha parcial e snapshot do estado **em memória**.

- **Aborta** se o administrador não tiver `authorized_keys`, porque desligar a senha trancaria o acesso.
- **Guard com snapshot:** antes de mexer em SSH e firewall, salva o estado **atual** em `/var/lib/homelab-guard/snapshot`. Se `touch ~/.homelab-guard-confirm` não for feito em N minutos, restaura esse snapshot (arquivos **e** regras carregadas). Numa reexecução, isso volta para a última configuração boa, e não para o padrão do Debian.
- Se o guard não armar, SSH e firewall **não são alterados**.
- `sshd -t` e `nft -c` validam a configuração antes de aplicar. Se reprovar, a configuração anterior é mantida.
- O script termina com código de saída diferente de zero se qualquer etapa falhar, e cada etapa aparece como `[OK]` ou `[FALHA]` no log.

## Portas publicadas do Docker

O Docker encaminha as portas publicadas por fora da cadeia `input`. A cadeia `forward` da tabela `homelab_fw` roda **antes** das regras do Docker e descarta conexões novas para containers, exceto as portas do host listadas em `docker_lan_tcp`/`docker_lan_udp`, e só vindas da rede local. Para liberar uma porta:

```bash
# temporário (até o próximo boot)
sudo nft add element inet homelab_fw docker_lan_tcp '{ 8080 }'
# permanente: editar "set docker_lan_tcp" em /etc/nftables.conf e recarregar
sudo nft -c -f /etc/nftables.conf && sudo nft -f /etc/nftables.conf
```

Os nomes de adaptador (`Wi-Fi`, `Ethernet`) e o endereço padrão do ICS ficam no topo do `ics-watchdog.ps1`.
