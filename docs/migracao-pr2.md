# Migração da instalação existente para as correções do PR #2

**Estado:** **PROPOSTO, aguardando aprovação.** Nada deste procedimento foi executado.
**Escopo:** trocar scripts e configuração de backup/guard/firewall pela versão do PR #2 **sem reinstalar a stack** e sem tocar nos dados dos serviços.

## O que NÃO muda (preservado)
| Item | Onde | Por quê |
|---|---|---|
| Contas, bancos e histórico do Beszel e do Kuma | `/opt/homelab/stacks/monitoring/data/` | O PR não altera o `compose.yaml`. **Sem `pull`, `up` nem recriação de contêineres** |
| Token e chave do agente Beszel | `/opt/homelab/stacks/monitoring/secrets/` | Intocados |
| `compose.yaml` e `.env` da stack | `/opt/homelab/stacks/monitoring/` | Intocados |
| Monitores, notificações e tópico ntfy | Bancos do Kuma e do Beszel | Intocados |
| Repositório restic, snapshots e senha | `/var/backups/homelab-restic`, `/etc/homelab/restic.pass` | Intocados (o export é criado **ao lado**) |
| URL de push do backup | `~/.config/homelab/backup-push-url` | Já está no formato aceito (`http://127.0.0.1:<porta>/api/push/<token>`) |
| Units systemd de backup e restauração | `/etc/systemd/system/homelab-*.{service,timer}` | Iguais no PR (mesmos caminhos em `/usr/local/sbin`) |
| Cópias antigas no PC | `%USERPROFILE%\HomeLab-Backups\` | A primeira rotação nova guarda a cópia antiga como `restic.previous` |

**Não executar `homelab-m3-deploy.sh`** nesta migração. Ele serve para instalação nova: baixa imagens, roda `compose up` e pode pedir a senha do backup.

## Fase 0 — Pré-requisitos (sem root, nada muda)
1. PR #2 aprovado. O pacote enviado ao servidor tem os mesmos hashes (`sha256sum`) dos arquivos do commit aprovado.
2. Monitor e teclado disponíveis no servidor. Janela de cerca de 30 min, longe das 03:30 (backup) e das 12:00 (pull).
3. Estado de referência registrado:
   - hashes de `sshd_config.d/10-homelab-hardening.conf` e `/etc/nftables.conf`;
   - 9/9 monitores UP no Kuma e o sistema "Ligado" no Beszel;
   - `/var/backups/homelab-backup.status` = `ok` e o último `pull.log` = `ok`;
   - nenhuma unidade `homelab-guard*` e `homelab-backup.service` inativo.
4. Nomes dos bancos conferidos (com root, só leitura, na fase 2): `data/beszel/data.db` e `data/uptime-kuma/kuma.db`. Se forem outros, definir `RESTORE_DBS=` no `backup.conf`.

## Fase 1 — Cópia de segurança pré-migração (root)
```bash
systemctl start homelab-backup.service            # script ANTIGO; espera "ok" no status
cat /var/backups/homelab-backup.status
tar -cpf /var/backups/homelab-pre-pr2-$(date +%F).tar \
    /usr/local/sbin/homelab-* /etc/homelab /var/lib/homelab-guard \
    /etc/nftables.conf /etc/ssh/sshd_config.d
chmod 0600 /var/backups/homelab-pre-pr2-*.tar
```
No PC, **executar** (sem alterar) a tarefa atual de pull e conferir `ok` no `pull.log`.

## Fase 2 — Código e configuração (root; sem efeito nos serviços)
```bash
R=<clone-do-repositorio-no-commit-aprovado>
install -d -m 0755 /usr/local/lib/homelab
install -m 0644 "$R"/scripts/server/lib/*.sh /usr/local/lib/homelab/
for s in apply backup restore-test external-restore-test guard-rollback; do
  install -m 0755 "$R/scripts/server/homelab-$s.sh" "/usr/local/sbin/homelab-$s"
done
# backup.conf: acrescenta as chaves novas (as atuais continuam validas)
printf '%s\n' "EXPORT_DIR=/var/backups/homelab-restic-export" "EXPORT_GROUP=<grupo-admin>" >> /etc/homelab/backup.conf
# valida a leitura segura (sem executar o arquivo)
bash -c '. /usr/local/lib/homelab/common.sh; hl_read_conf /etc/homelab/backup.conf ADMIN_USER RESTIC_REPOSITORY RESTIC_PASSWORD_FILE STACKS_DIR EXPORT_DIR EXPORT_GROUP BACKUP_PATHS PAUSE_SERVICES RESTORE_STABLE RESTORE_DBS && echo CONF_OK'
ls /opt/homelab/stacks/monitoring/data/beszel /opt/homelab/stacks/monitoring/data/uptime-kuma   # nomes dos bancos
# logs: novo diretorio + historico antigo preservado
install -d -m 0750 -o root -g <grupo-admin> /var/log/homelab /var/log/homelab/legado
mv /home/<usuario-admin>/homelab-*.log /var/log/homelab/legado/
```
**Verificação:** `sha256sum` dos arquivos instalados igual ao do pacote e `bash -n` em todos.

## Fase 3 — Firewall restrito à sub-rede (root, com guard de 10 min)
```bash
NET=$(ip -4 route show dev "$(ip -4 route show default | awk '{print $5; exit}')" scope link | awk '{print $1; exit}')
printf '%s\n' "ALLOWED_V4=$NET" "ALLOWED_V6=fe80::/10" "DOCKER_LAN_TCP=$(cat /etc/homelab/docker-lan-tcp)" "DOCKER_LAN_UDP=" > /etc/homelab/firewall.conf
chmod 0644 /etc/homelab/firewall.conf
# previa: ruleset gerado + validacao, sem aplicar
bash -c '. /usr/local/lib/homelab/firewall.sh; fw_render_from_conf /etc/homelab' > /tmp/fw-previa.nft && nft -c -f /tmp/fw-previa.nft && echo PREVIA_OK
homelab-apply <usuario-admin> --only-ssh-firewall     # NAO mexe em hora/pacotes; arma o guard
```
**Validação externa, sem root, antes de confirmar:**
- login **novo** por chave OK; senha recusada;
- do PC: 8090 e 3001 abrem, 8080 é descartada;
- Kuma 9/9 UP, inclusive "SSH do servidor" e "ICS do Windows".

Só então rodar `touch ~/.homelab-guard-confirm` e conferir, depois do disparo, `acesso confirmado; mudancas mantidas` em `/var/lib/homelab-guard/guard.log`. **Sem confirmação, o guard restaura o estado atual sozinho em 10 min.**

## Fase 4 — Primeiro backup com export (root)
```bash
systemctl start homelab-backup.service && cat /var/backups/homelab-backup.status   # novo script
( cd /var/backups/homelab-restic-export && sha256sum -c --quiet MANIFEST.sha256 && cat GENERATION )
systemctl start homelab-restore-test.service && cat /var/backups/homelab-restore-test.status
sudo -u <usuario-admin> test -r /var/backups/homelab-restic-export/MANIFEST.sha256 && echo EXPORT_LEGIVEL
```
Esperado:
- status `ok`;
- manifesto conferido;
- serviços religados;
- **push recebido** pelo monitor "Backup diário" do Kuma;
- restauração `ok` com `integrity_check` dos dois bancos.

## Fase 5 — Windows (usuário, sem administrador)
> Altera a tarefa agendada `\HomeLab\HomeLab Backup Pull` (mesmo nome e horários). **Requer autorização específica.**
1. Guardar o script atual: `%USERPROFILE%\.homelab\pull-homelab-backup.ps1` → `.bak`.
2. `scripts\windows\register-backup-pull.ps1` (copia o script e o módulo `HomeLabBackup.psm1` e reescreve a tarefa).
3. Executar a tarefa uma vez. Esperado no `pull.log`: `ok: N arquivos conferidos pelo manifesto; geracao <snapshot>`. A cópia antiga (repositório cru) passa a ser `restic.previous`.
4. Opcional, recomendado: restauração externa da cópia nova (`homelab-external-restore-test`, sudo + senha do backup).

## Fase 6 — Encerramento
- Kuma 9/9 UP, Beszel OK, `systemctl --failed` vazio e logs novos em `/var/log/homelab/`.
- Registrar as evidências no M3 e mudar os itens da tabela "sandbox × implantado" para **implantado**.
- `/etc/homelab/docker-lan-tcp` passa a ser ignorado (existe `firewall.conf`); remover na revisão seguinte.

## Reversão
| Fase | Como reverter |
|---|---|
| 3 (firewall/SSH) | Automática pelo guard (sem confirmação em 10 min) ou imediata em falha. Pelo console: `nft -f /var/lib/homelab-guard/restore.nft` |
| 2 e 4 (scripts/config) | `tar -xpf /var/backups/homelab-pre-pr2-<data>.tar -C /`, remover `/usr/local/lib/homelab` e `/var/backups/homelab-restic-export`. O script antigo continua lendo o `backup.conf` (as chaves novas são ignoradas por ele) |
| 5 (Windows) | Restaurar o `.bak` do script de pull. A tarefa continua apontando para o mesmo caminho |
| Dados dos serviços | Não se aplica: nada é alterado |

## Riscos e mitigação
| Risco | Mitigação |
|---|---|
| Perder o SSH ao restringir a sub-rede | Guard (reversão automática e imediata), validação externa antes da confirmação, console local |
| Nome de banco diferente do padrão → restauração reprova | Conferência na fase 2 e `RESTORE_DBS` no `backup.conf` |
| Backup novo falhar | O export **não** é promovido (a cópia externa fica na versão anterior); reverter pela fase 2 |
| Indisponibilidade dos painéis | Cerca de 10 s durante o backup (pausa do SQLite), igual ao atual |
