# Procedimentos de recuperação

Ordem: do mais simples para o mais drástico. Antes de qualquer mudança arriscada, confirme que você tem pelo menos **dois** destes caminhos.

## Camadas de acesso

| # | Caminho | Depende de | Onde fica |
|---|---|---|---|
| 1 | SSH com a chave de administração | PC Windows + rede | `~/.ssh/id_ed25519_homelab` no PC (sem frase-senha, protegida pelas permissões do Windows) |
| 2 | SSH com a **chave de recuperação** | Qualquer computador com OpenSSH + rede | Arquivo `id_ed25519_homelab_recovery`, **com frase-senha**, guardado fora do PC (pendrive e/ou gerenciador de senhas) |
| 3 | **Console local** (monitor + teclado, `tty1`) | Acesso físico | Login com a senha do administrador; o SSH só por chave não afeta o console |
| 4 | GRUB → "Opções avançadas" → kernel anterior ou modo de recuperação | Acesso físico | Kernel anterior mantido pelo `apt` |
| 5 | Restaurar o backup restic num Debian novo | Senha do backup + uma cópia do repositório | Servidor (`/var/backups/homelab-restic`) e PC (`%USERPROFILE%\HomeLab-Backups\restic`) |

## Guarda da chave de recuperação (uma vez)

1. Copie a pasta `%USERPROFILE%\.ssh\homelab-recovery\` para um pendrive guardado em outro lugar e/ou anexe o arquivo ao gerenciador de senhas, junto com a frase-senha.
2. Depois de confirmar a cópia, **apague** a chave privada de recuperação do PC. Ela só faz sentido guardada fora dele; a chave pública já está no servidor.
3. Teste uma vez de qualquer máquina: `ssh -i id_ed25519_homelab_recovery <usuario-admin>@<ip-do-servidor>`.

Para revogar uma chave, apague a linha correspondente em `~/.ssh/authorized_keys` no servidor (identificável pelo comentário).

## Cenários

### SSH recusa ou expira depois de uma mudança
- Se a mudança foi feita pelo `homelab-apply.sh`, **espere o guard** (10 min): ele restaura o estado anterior sozinho.
- Caso contrário, entre pelo console e rode `sudo rm /etc/ssh/sshd_config.d/10-homelab-hardening.conf && sudo systemctl reload ssh` (isso devolve o login por senha) ou `sudo nft delete table inet homelab_fw` (remove o firewall).

### Servidor sem internet, mas SSH funciona
É o ICS do Windows. A tarefa `\HomeLab\HomeLab ICS Watchdog` corrige em até 5 min. Para forçar, numa janela de PowerShell como administrador:
```powershell
Start-ScheduledTask -TaskPath '\HomeLab\' -TaskName 'HomeLab ICS Watchdog'
Get-Content C:\ProgramData\HomeLab\ics-watchdog.log -Tail 20
```

### Kernel novo não sobe
GRUB → "Opções avançadas para Debian" → o kernel anterior. Depois: `sudo apt-get install --reinstall linux-image-amd64` ou abra um chamado no marco.

### Senha do administrador perdida
Pelo console: GRUB → `e` na entrada → acrescente `init=/bin/bash` à linha `linux` → `mount -o remount,rw /` → `passwd <usuario-admin>` → `exec /sbin/init`. Exige acesso físico.

### Troca planejada da senha do administrador
1. Abra uma sessão interativa: `ssh -t homelab passwd`. A senha atual e a nova são digitadas só ali.
2. **Sem fechar essa sessão**, abra outra e teste `ssh -t homelab sudo -v` com a senha nova.
3. Guarde a nova senha no gerenciador de senhas. A senha nunca entra em arquivos, scripts ou conversas.

### Pendrive morreu (perda total)
1. Instale o Debian 12 num disco novo, com o mesmo usuário administrador.
2. `sudo apt install restic` e copie o repositório do PC (`HomeLab-Backups\restic`) para o servidor, por exemplo com `scp -r`.
3. `restic -r <repo> snapshots` e depois `restic -r <repo> restore latest --target /tmp/r` (pede a **senha do backup**).
4. Reponha `/etc/ssh/sshd_config.d`, `/etc/nftables.conf`, `/etc/homelab` e `/opt/homelab` a partir de `/tmp/r`. Reinstale os pacotes com `dpkg --set-selections < /tmp/r/var/backups/homelab-meta/dpkg-selections.txt && apt-get dselect-upgrade`.
5. Clone este repositório e rode `homelab-apply.sh` e `homelab-m3-deploy.sh`.

### Restaurar só um serviço (ex.: Uptime Kuma)
```bash
cd /opt/homelab/stacks/monitoring && sudo docker compose stop uptime-kuma
sudo restic -r /var/backups/homelab-restic --password-file /etc/homelab/restic.pass \
  restore latest --target / --include /opt/homelab/stacks/monitoring/data/uptime-kuma
sudo docker compose start uptime-kuma
```
