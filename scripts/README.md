# Scripts do HomeLab

Scripts usados no [M2](../docs/marcos/M2-rede-seguranca-automacao.md). Leia antes de rodar, porque eles mudam a configuração do sistema.

| Script | Onde | Como rodar | Função |
|---|---|---|---|
| [`windows/setup-ics-persistent.ps1`](windows/setup-ics-persistent.ps1) | PC Windows | PowerShell **como administrador**, uma vez: `.\setup-ics-persistent.ps1 -LogPath .\setup-ics.log` | ICS persistente (Registro + serviço) e cria a tarefa do watchdog |
| [`windows/ics-watchdog.ps1`](windows/ics-watchdog.ps1) | PC Windows | Pela tarefa `\HomeLab\HomeLab ICS Watchdog` (SYSTEM, no boot e a cada 5 min) | Reaplica o ICS Wi-Fi → Ethernet quando ele some ou para de responder |
| [`server/homelab-apply.sh`](server/homelab-apply.sh) | Wyse (Debian 12) | `sudo bash homelab-apply.sh <usuario-admin>` | Hora, atualizações, unattended-upgrades, SSH só por chave, firewall nftables e limites de log |

**Antes de rodar o `homelab-apply.sh`:** confirme que você entra por **chave** SSH. O script desliga o login por senha. Se o acesso não for confirmado com `touch ~/.homelab-guard-confirm` em até 10 minutos, SSH e firewall voltam sozinhos ao estado anterior.

Os nomes de adaptador (`Wi-Fi`, `Ethernet`) e o endereço padrão do ICS ficam no topo do `ics-watchdog.ps1`.
