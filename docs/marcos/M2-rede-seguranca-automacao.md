# M2 — Rede persistente, hora, segurança e automação

**Data da sessão:** 26/11/2026
**Ambiente:** Dell Wyse 7020 · Debian 12 · PC Windows 11 com ICS
**Status:** ver a [tabela de resultados](#resultado). Itens marcados **PENDENTE DE VALIDAÇÃO** dependem de um reinício que ainda não foi feito.

> Registro do que foi observado nesta sessão, não configuração de produção. Endereços internos, nomes de usuário, MACs, impressões digitais de chaves e credenciais não são publicados.

## Ponto de partida

A auditoria inicial, só com comandos de leitura, encontrou quatro problemas ligados entre si:

| Sintoma | Evidência |
|---|---|
| Servidor sem internet | Sem resposta do gateway, DNS falhando, `apt update` travado em "Falha temporária resolvendo" |
| Relógio 41 dias atrasado | Sistema em 16/10 com a data real em 26/11; `System clock synchronized: no`; NTP com `Packet count: 0` |
| RTC (relógio da placa) em 2013 | `RTC time: 2013-01-01`, sinal provável de bateria CMOS gasta |
| Sem firewall e SSH aceitando senha | `INPUT ACCEPT`; `passwordauthentication yes`; `x11forwarding yes` |

O relógio atrasado era **consequência** da falta de internet: o `systemd-timesyncd` estava ativo, mas não alcançava nenhum servidor NTP. Sem sincronizar, o sistema retomava a última hora salva em disco, e o RTC sem bateria não ajudava.

## 1. Causa-raiz do ICS

### O que foi verificado no Windows

| Verificação | Resultado |
|---|---|
| `HKLM\...\SharedAccess\EnableRebootPersistConnection` | **Ausente** |
| Serviço `SharedAccess` (ICS) | Em execução, mas com inicialização **Manual** |
| Configuração ICS lida como administrador | Wi-Fi (pública) e Ethernet (privada) **marcadas como compartilhadas** |
| Proxy DNS do ICS na Ethernet | **Não respondia** |
| Hyper-V (`hns`, `WinNat`, *Default Switch*) | Ativos; também usam a infraestrutura de NAT/ICS do Windows |
| Adaptador Wi-Fi | USB (Realtek 8811CU) com número de série genérico |

### Conclusão

1. **Causa principal (documentada pela Microsoft, KB4055559):** desde o Windows 10 1709, o ICS **não é restaurado após reiniciar** a menos que `EnableRebootPersistConnection = 1` e o serviço `SharedAccess` inicie automaticamente. Nenhuma das duas condições era atendida.
2. **Estado "zumbi":** o compartilhamento aparecia como ativo, mas o NAT/DNS não funcionava. Por isso o sintoma era "SSH funciona, internet não", e desligar e religar o compartilhamento resolvia. Reiniciar só o serviço não recompõe a ligação entre os adaptadores.
3. **Fatores agravantes (não comprovados como causa):**
   - O HNS do Hyper-V recria o *Default Switch* a cada boot usando o mesmo mecanismo.
   - Um adaptador Wi-Fi USB com série genérica pode ser reenumerado com outra identidade se mudar de porta, e isso desfaz o vínculo do ICS.

### Correção persistente (gratuita)

Script: [`scripts/windows/setup-ics-persistent.ps1`](../../scripts/windows/setup-ics-persistent.ps1), executado uma vez como administrador.

1. Grava `EnableRebootPersistConnection = 1`.
2. Passa o serviço `SharedAccess` para **Automático**.
3. Cria a tarefa agendada `\HomeLab\HomeLab ICS Watchdog`, que roda como SYSTEM no boot (com 1 min de atraso) e a cada 5 min. Ela executa [`scripts/windows/ics-watchdog.ps1`](../../scripts/windows/ics-watchdog.ps1), que:
   - só age se o próprio PC tiver internet, para não "consertar" uma queda do Wi-Fi;
   - verifica se o ICS está Wi-Fi → Ethernet **e se o DNS do ICS responde** (3 tentativas);
   - quando falha, desliga todos os compartilhamentos e reaplica Wi-Fi → Ethernet, fazendo automaticamente o que antes era feito à mão;
   - registra cada ação em `C:\ProgramData\HomeLab\ics-watchdog.log`, numa pasta onde só SYSTEM e Administradores têm escrita.

**Resultado na sessão — CONFIRMADO:**

```text
Reaplicando ICS: ICS configurado mas DNS em <gateway ICS> nao responde
ICS reaplicado. DNS ICS ok: True
```

Logo depois, no servidor: DNS resolvido, `HTTP 200` no espelho Debian e NTP sincronizado com desvio de cerca de 1 ms.

**PENDENTE DE VALIDAÇÃO:** o comportamento após reiniciar o **PC Windows**. O reinício não foi feito nesta sessão (o PC não é reiniciado sem autorização).

### Recuperação manual (se o watchdog falhar)

```powershell
Start-ScheduledTask -TaskPath '\HomeLab\' -TaskName 'HomeLab ICS Watchdog'
Get-Content C:\ProgramData\HomeLab\ics-watchdog.log -Tail 20
```

Para desfazer: apagar a tarefa `\HomeLab\HomeLab ICS Watchdog`, remover o valor do Registro e voltar o serviço para Manual.

## 2. Acesso administrativo por chave SSH

- Uma chave **Ed25519 dedicada** ao HomeLab foi gerada no Windows, com alias no `~/.ssh/config` (`IdentitiesOnly yes`, `StrictHostKeyChecking yes`).
- A chave de host do servidor foi **conferida** contra o `known_hosts` existente antes do primeiro uso.
- A chave pública foi instalada no `authorized_keys` do usuário administrador. A senha foi digitada só no terminal interativo, sem ser gravada em arquivos.
- O login **só com chave** foi validado (senha e keyboard-interactive desligados no cliente) **antes** de desligar a senha no servidor.
- O `sudo` **continua exigindo senha**. Tarefas de root são agrupadas num script revisado e executadas numa janela visível, onde a senha é digitada.

## 3. Configuração do servidor

Script: [`scripts/server/homelab-apply.sh`](../../scripts/server/homelab-apply.sh). Uso: `sudo bash homelab-apply.sh <usuario-admin>`. Pode ser reexecutado.

| Área | O que foi feito |
|---|---|
| **Hora** | `timesyncd` com NTP.br (`a/b/c.st1.ntp.br`) e o pool Debian como reserva; `hwclock --systohc` gravou a hora certa no RTC |
| **Pacotes** | `apt update` + `full-upgrade` (incluiu o kernel **6.1.0-56**) + `autoremove` |
| **Atualizações automáticas** | `unattended-upgrades` só para segurança, **sem reboot automático** |
| **SSH** | Drop-in `sshd_config.d/10-homelab-hardening.conf`: só chave pública, root bloqueado, `AllowUsers` no administrador, sem X11, `MaxAuthTries 3` |
| **Firewall** | `nftables` com tabela própria `inet homelab_fw`, política **drop** na entrada. Libera: loopback, conexões estabelecidas, ICMP, SSH **só de faixas privadas** (RFC 1918 e link-local), mDNS, DHCP e as interfaces do Docker. **Sem `flush ruleset`**, para não apagar as regras do Docker |
| **Serviços** | Desativados `cups`, `cups-browsed`, `ModemManager` e `bluetooth`, desnecessários num servidor e reversíveis com `systemctl enable --now` |
| **Pendrive** | `journald` limitado a 200 MB / 1 mês; Docker com rotação de logs (10 MB × 3) |

### Proteção contra perder o acesso

SSH e firewall são as mudanças que podem trancar o administrador fora. Antes de aplicá-las, o script arma um *guard* (`systemd-run --on-active=10min`): se ninguém criar `~/.homelab-guard-confirm` em até 10 minutos, ele **remove o drop-in do SSH, apaga a tabela do firewall e restaura o `nftables.conf` original**. O acesso foi validado e confirmado dentro do prazo.

### Validação (CONFIRMADO)

| Teste | Resultado |
|---|---|
| Login por chave em conexão nova | OK |
| Login por senha | `Permission denied (publickey)` |
| Login como root | `Permission denied (publickey)` |
| Porta fechada (TCP 8080) vista do PC | Sem resposta: **descartada** pelo firewall, em vez de recusada |
| Ping, DNS e HTTPS a partir do servidor com o firewall ativo | OK |
| `System clock synchronized` | `yes`, desvio de cerca de 1 ms |
| RTC | Igual à hora UTC do sistema |
| Docker, SSH e timesyncd | `active`; nenhuma unidade com falha |
| Pacotes pendentes | 0 |

## 4. Validação após reiniciar o Wyse e revisão dos scripts (27/11/2026)

### Caminho de recuperação conferido antes do reboot
- Console `tty1` com login por senha ativo; boot em `multi-user.target`.
- Kernel anterior (6.1.0-53) ainda instalado; GRUB com 5 s de espera.
- Perfil Ethernet do NetworkManager com conexão automática e sem restrição de usuário.

### Reboot (CONFIRMADO)
O servidor caiu às 23:58:16 e o SSH voltou às 23:58:49 (33 s), com um `boot_id` novo e boot em 17,6 s.

| Verificação pós-boot | Resultado |
|---|---|
| Kernel | `6.1.0-56-amd64` |
| SSH | Chave OK; senha e root: `Permission denied (publickey)` |
| Firewall | `nftables` active/enabled; portas 8080, 631 e 2375 **descartadas** quando testadas pelo PC |
| Internet, DNS e HTTPS | OK (HTTPS 200 em 0,22 s) |
| NTP | Sincronizado com `c.st1.ntp.br`; RTC igual ao UTC |
| Docker / Compose | Engine 29.10.1 / Compose v5.8.0 |
| Unidades com falha | Nenhuma |
| Recursos | RAM usada 600 MiB de 5,2 GiB; load 0,96 logo após o boot; `/` 24%; 54 °C |

### Pontos levantados numa revisão externa dos scripts

| Ponto | O que foi feito | Evidência |
|---|---|---|
| Watchdog do ICS × Hyper-V/WSL | O watchdog não desliga mais compartilhamentos de adaptadores `vEthernet*` | *Default Switch* `Up` com o IP intacto. O WSL2 e o Docker Desktop **não iniciam neste PC porque a virtualização (SVM) está desligada na BIOS** (`VirtualizationFirmwareEnabled: False`). A causa é anterior e não tem relação com o ICS |
| Portas publicadas pelo Docker | Cadeia `forward` antes do Docker com a lista de liberação `docker_lan_tcp`, que vem de `/etc/homelab/docker-lan-tcp` | Porta 18080 vista do PC: **bloqueada → liberada (`porttest-ok`) → bloqueada** |
| Falhas e idempotência | Log criado com o dono certo antes do `tee`; `[OK]`/`[FALHA]` e código de saída; aborta sem `authorized_keys`; SSH e firewall só mudam se o guard armar | Duas reexecuções seguidas sem falhas |
| Rollback em reexecuções | O guard agora guarda um **snapshot do estado atual** e o restaura (arquivos **e** regras carregadas). Antes, voltaria ao padrão do Debian | Teste deliberado com guard de 2 min sem confirmação: hash `6236…` → `d700…` → **`6236…`** e a cadeia nova removida da memória |
| Hostname em arquivos públicos | Removido | `git grep` sem ocorrências |
| Troca da senha antiga | Procedimento seguro documentado em [recuperação](../recuperacao.md) | **PENDENTE**: precisa ser feita pela pessoa |

### Containers (CONFIRMADO)
`hello-world` OK; Alpine 3.22.6 com acesso à internet (`wget` no espelho Debian); Compose `up`/`down` OK; container ocioso com CPU de 0,00% e 348 KiB de RAM; nenhum container de teste restante.

## Resultado

| Item | Estado |
|---|---|
| Causa-raiz do ICS identificada (KB4055559 + estado "zumbi") | **CONFIRMADO** |
| ICS restaurado sem intervenção manual (watchdog) | **CONFIRMADO** na sessão |
| ICS sobrevive ao reboot do **Wyse** | **CONFIRMADO** (internet ok logo após o boot) |
| ICS após reiniciar o **PC Windows** | **PENDENTE DE VALIDAÇÃO** (reinício não autorizado) |
| Hora e RTC corretos, inclusive após o reboot | **CONFIRMADO** |
| SSH só por chave, root bloqueado, persistente após o reboot | **CONFIRMADO** |
| Firewall drop, persistente, com portas do Docker bloqueadas por padrão | **CONFIRMADO** |
| Rollback automático (teste deliberado) | **CONFIRMADO** |
| Atualizações automáticas de segurança | **CONFIRMADO** (instalado e testado com dry-run) |
| Kernel 6.1.0-56 em execução | **CONFIRMADO** |
| WSL2 / Docker Desktop no PC | **BLOQUEADO** pela BIOS (SVM desligada), sem relação com este marco |
| Bateria CMOS | **PENDENTE**: o RTC voltou para 2013 antes da correção; trocar a CR2032 |

## Lições

1. "Serviço rodando" não é "funcionando": o ICS estava ativo e marcado como compartilhado, mas sem NAT/DNS. O watchdog testa **o efeito** (DNS respondendo), não a configuração.
2. Hora errada costuma ser sintoma, não causa. Aqui ela vinha da falta de rede.
3. Mudanças que podem trancar o acesso precisam de uma **reversão automática**, não só de "cuidado".
4. Em Debian com Docker, o `nftables.conf` padrão (`flush ruleset`) apaga as regras do Docker. Use uma tabela própria.
