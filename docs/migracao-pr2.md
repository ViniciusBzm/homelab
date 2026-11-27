# Migração da instalação existente para as correções do PR #2

**Estado:** **EXECUÇÃO PARCIAL em 27/11/2026: fases 1, 2 (reduzida), 4 e 5 concluídas.** A **fase 3 (SSH/firewall) está PENDENTE**: exige console físico disponível e a chave de recuperação validada, e nenhum dos dois estava confirmado no dia. Evidências na seção [Execução parcial](#execução-parcial-27112026).
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

## Execução parcial (27/11/2026)

**Autorização:** fases 1, 2, 4 e 5. **Restrições:**
- não alterar SSH, firewall, rede, usuários nem chaves;
- na fase 2, **somente** scripts e bibliotecas de backup e restauração;
- preservar a cópia externa validada;
- restauração externa obrigatória;
- reativação garantida dos agendamentos;
- sem reboot.

**Fase 0.** Interrompida na primeira tentativa: console físico indisponível. Na segunda, o teste da chave de recuperação **não foi feito**, porque a janela falhou por um erro de citação de argumentos no lançador (corrigido e validado antes de seguir). Nenhuma etapa havia rodado; isso foi confirmado no servidor antes de continuar.

| Fase | Evidência real |
|---|---|
| Pré | **Cópia externa validada preservada** (snapshot `de8aeee0`, validado pela restauração externa das 12:10) numa pasta à parte que a rotação não toca, somente leitura, com lista SHA256 (9 arquivos). Conferida **intacta** no fim |
| 1 | Rede de segurança `systemd-run` armada (religaria os timers em 4 h se a sessão caísse). Timers de backup e restauração **suspensos** (`inactive`). Backup com o script antigo `ok` (snapshot `5e53678a`). Tar de recuperação criado com `umask 077`: **`600 root:root`**. Bancos presentes. Hashes de SSH/firewall iguais à referência (`ACESSO_INTOCADO_OK`). No PC: tarefa antiga executada uma vez (`0x0`) e então **suspensa** (`Disabled`) |
| 2 (reduzida) | Instalados **só** `lib/common.sh`, `lib/restore.sh`, `homelab-backup`, `homelab-restore-test` e `homelab-external-restore-test`, **com SHA256 idênticos ao commit `11a372e`**. **Mantidos na versão anterior** (adiados para a fase 3): `homelab-apply`, `homelab-guard-rollback`, `lib/guard.sh`, `lib/firewall.sh`. `backup.conf` ganhou só `EXPORT_DIR`/`EXPORT_GROUP` e passou na leitura segura. Logs antigos movidos para `/var/log/homelab/legado` (`0640 root:<grupo-admin>`). `ACESSO_INTOCADO_OK` |
| 4 | Backup novo `ok` (snapshot `cc29ef0f`): pausa/religamento confirmados, forget/prune e check `[OK]`, **export publicado** (10 arquivos, manifesto conferido inclusive pelo administrador sem root; `2750 root:<grupo-admin>`; lock `644`; nenhum temporário). **Restauração local:** `restore --verify`, 5 configurações idênticas, 6/6 arquivos de dados, `integrity_check` OK em `beszel/data.db` e `uptime-kuma/kuma.db`. `ACESSO_INTOCADO_OK` |
| 5 | No PC: script anterior guardado (`.bak-pre-pr2`). Tarefa reinstalada pelo `register-backup-pull.ps1` do commit `11a372e` (script e módulo idênticos ao repositório; mesmos gatilhos: diário e no logon). Execução: `0x0`, *"10 arquivos conferidos pelo manifesto; geracao cc29ef0f"*. **Restauração externa obrigatória** da nova geração (senha do backup digitada pela pessoa): `EXTERNAL_RESTORE_OK`. Cópia temporária removida. **Timers reativados** e rede de segurança desarmada |

### Validação final (após as fases)
| Item | Resultado |
|---|---|
| SSH | Chave OK; senha `Permission denied (publickey)`; hashes de `sshd_config.d` e `nftables.conf` **iguais aos de antes** |
| Firewall (visto do PC) | 8090 `200`, 3001 `302`; 8080 e 2375 descartadas (sem mudança) |
| Contêineres | 4/4 `running`/`healthy`, **criados em 27/11 00:16, ou seja, não recriados** (só pausados/religados pelo backup) |
| Monitores | 9/9 UP no Uptime Kuma |
| Bancos SQLite | `integrity_check` OK nos dois (restauração local e externa) |
| Alertas | Notificação de teste do Kuma **entregue** no ntfy; 5 alertas do Beszel ativos; S.M.A.R.T. `PASSED` |
| Agendamentos | `homelab-backup.timer` (03:36) e `homelab-restore-test.timer` (01/12) ativos; tarefa do PC habilitada (próxima: 12:00) |
| Backups | backup `ok cc29ef0f`; restauração local `ok dbs_ok`; restauração externa `EXTERNAL_RESTORE_OK`; export com manifesto conferido |
| Recursos | RAM 884 MiB; load 0,23; `/` 28%; 51–55 °C; NTP sincronizado; nenhuma unidade com falha |

### Achado durante a validação (aberto, NÃO corrigido no servidor)
**O push do backup para o Uptime Kuma falha sempre.** O backup religa o Kuma e envia o push logo em seguida, enquanto o Kuma ainda está iniciando (log: `aviso: push para o Uptime Kuma falhou`). O mesmo acontecia com o script anterior. Efeito: o monitor "Backup diário" (janela de 26 h) daria um **falso alerta** de backup atrasado mesmo com os backups em dia.
- **Mitigação aplicada (sem código):** reenvio manual do push referente ao backup bem-sucedido `cc29ef0f`, com a mensagem identificando o reenvio. Isso adia o falso alerta por cerca de 26 h, mas o push automático continua falhando.
- **Correção publicada para revisão (PENDENTE DE VALIDAÇÃO, não implantada no Wyse):** `push()` do `homelab-backup.sh` agora repete **só a notificação** (nunca o backup) a cada 10 s, com limite total de 180 s, e para na primeira confirmação do Kuma (`{"ok":true}`). A validação da URL não mudou. O log registra apenas o número da tentativa e o código do curl (stderr descartado, sem token). Esgotado o limite, o log diz `NOTIFICACAO ao Uptime Kuma falhou ... (resultado do backup inalterado: up|down)`, e o status e o código de saída do backup não mudam.
- **Testes (27/11/2026, sandbox no Wyse):** 63/63 aprovados (58 anteriores + 5 novos: sucesso imediato, Kuma indisponível nas 2 primeiras tentativas, esgotamento do limite, resposta sem `"ok":true` e falha do backup com falha da notificação). Os 5 novos **falham** com o script do commit `71fddc8` (regressão comprovada). Evidência: [`tests/evidencias/push-retry-2026-11-27.txt`](../tests/evidencias/push-retry-2026-11-27.txt).

### Pendências
- **Fase 3** (SSH/firewall, apply e guard novos), com console físico e chave de recuperação validada.
- Correção do push (acima).
- Remover `/etc/homelab/docker-lan-tcp` depois da fase 3.
