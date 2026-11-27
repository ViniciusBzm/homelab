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

A ordem importa: **nunca apague a chave local antes de provar que a cópia externa funciona.**

1. **Faça duas cópias externas** da pasta `%USERPROFILE%\.ssh\homelab-recovery\`, por exemplo um pendrive guardado em outro lugar e um anexo no gerenciador de senhas. A frase-senha vai no gerenciador, **nunca** junto do pendrive.
2. **Teste cada cópia externa, não a local.** Com o pendrive conectado (ex.: `E:`), aponte para o arquivo **da cópia**:
   ```powershell
   ssh -o IdentitiesOnly=yes -o IdentityAgent=none -i E:\homelab-recovery\id_ed25519_homelab_recovery <usuario-admin>@<ip-do-servidor> "echo RECOVERY_KEY_OK"
   ```
   Repita com o arquivo baixado do gerenciador de senhas. Se o OpenSSH reclamar de permissões no pendrive, copie o arquivo para uma pasta temporária, teste e apague a pasta.
3. **Só depois** de as duas cópias imprimirem `RECOVERY_KEY_OK`, apague a chave privada de recuperação do PC (`id_ed25519_homelab_recovery`). Mantenha o `.pub`, que é inofensivo e identifica a chave.
4. Confira que só a cópia externa permite entrar: com o pendrive desconectado, o mesmo comando apontando para o caminho antigo no PC deve falhar.
5. Anote no gerenciador de senhas a data do teste. Repita o teste a cada 6 meses ou ao trocar de pendrive.

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
