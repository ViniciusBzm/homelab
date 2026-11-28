# Migração da instalação existente para as correções do PR #2

**Estado:** **fases 1, 2 (reduzida), 4 e 5 executadas em 27/11/2026 e fase 3 (SSH/firewall/guard) executada no mesmo dia às 20:51, com o guard confirmado (CONFIRMADO).** Evidências nas seções [Execução parcial](#execução-parcial-27112026) e [Fase 3 executada](#fase-3-executada-27112026).
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
- **Correção (commit `dc8170a`), aprovada na revisão e IMPLANTADA em 27/11/2026 (CONFIRMADO, ver abaixo):** `push()` do `homelab-backup.sh` agora repete **só a notificação** (nunca o backup) a cada 10 s, com limite total de 180 s, e para na primeira confirmação do Kuma (`{"ok":true}`). A validação da URL não mudou. O log registra apenas o número da tentativa e o código do curl (stderr descartado, sem token). Esgotado o limite, o log diz `NOTIFICACAO ao Uptime Kuma falhou ... (resultado do backup inalterado: up|down)`, e o status e o código de saída do backup não mudam.
- **Testes (27/11/2026, sandbox no Wyse):** 63/63 aprovados (58 anteriores + 5 novos: sucesso imediato, Kuma indisponível nas 2 primeiras tentativas, esgotamento do limite, resposta sem `"ok":true` e falha do backup com falha da notificação). Os 5 novos **falham** com o script do commit `71fddc8` (regressão comprovada). Evidência: [`tests/evidencias/push-retry-2026-11-27.txt`](../tests/evidencias/push-retry-2026-11-27.txt).
- **Implantação (27/11/2026, 18:14–18:16), só o `homelab-backup`:**
  - O script anterior foi preservado em `/var/backups/homelab-backup.pre-dc8170a` (0700 root).
  - Instalado com o sha256 conferido (`c59a7266…`, igual ao do `dc8170a`).
  - **1ª execução:** backup `54d1b8b6` OK e push confirmado no log, mas a **verificação** do script de implantação falhou por um erro dele: o log é recriado a cada execução e as linhas foram procuradas a partir da contagem antiga. O script novo foi **revertido automaticamente**, como previsto, e o backup foi preservado.
  - **2ª execução:** depois de corrigida a verificação, `ok 2026-11-27T18:16:14-03:00 snapshot=b6d9e6f2`.
    - Log: `tentativa 1 sem confirmacao (curl=56)` (Kuma iniciando) e depois `recebida pelo Uptime Kuma (tentativa 2)`, com resposta `{"ok":true}`.
    - O banco do Kuma, lido em modo somente leitura, tem a batida UP do monitor push com `snapshot=b6d9e6f2`.
    - Os **9/9 monitores** estão UP. O token não aparece no log.
    - O manifesto confere (13 arquivos, geração `b6d9e6f2`).
    - Os **4 contêineres** estão no ar (beszel, beszel-agent, uptime-kuma, socket-proxy).
    - Os timers de backup e de restauração estão ativos, sem units com falha.
    - SSH e firewall estão intocados (md5 de referência iguais).


### Pendências
- ~~Fase 3~~: executada (abaixo).
- ~~Correção do push~~: implantada (acima).
- ~~Remover `/etc/homelab/docker-lan-tcp`~~: feito às 21:10 (abaixo).

## Fase 3 executada (27/11/2026)

**Pré-requisitos confirmados antes da execução:**
- **Chave de recuperação**, às 18:38. O teste usou uma conexão independente, com configuração própria, sem agente e sem a chave do dia a dia; sem a frase-senha, a conexão foi recusada. Resultado: `RECOVERY_KEY_OK`. Atenção: o `LoginGraceTime 30` exige digitar a frase-senha em até 30 s.
- **Console físico:** login com a senha nova no `tty1` OK.

**Execução (20:51), com sudo numa janela visível:**
- **Instalação:** o código de SSH/firewall que tinha sido adiado da fase 2 (`homelab-apply`, `homelab-guard-rollback`, `lib/guard.sh` e `lib/firewall.sh`) foi instalado com o sha256 conferido contra o pacote do `11a372e`. Esses arquivos não mudaram até o `dc8170a`. As versões anteriores foram preservadas em `/var/backups/homelab-pre-fase3-*`.
- **Sub-rede:** o gateway e o PC foram conferidos dentro da sub-rede do ICS. Foi gerado `/etc/homelab/firewall.conf` com `ALLOWED_V4=<sub-rede-do-ICS>/24`, `ALLOWED_V6=fe80::/10` e `DOCKER_LAN_TCP=8090,3001`, e a prévia foi validada com `nft -c`.
- **Aplicação:** `homelab-apply <usuario-admin> --only-ssh-firewall` terminou com `falhas=0`:
  - `[OK] snapshot do estado atual`;
  - `[OK] guard armado (21:01:23)`;
  - `[OK] sshd validado e recarregado`;
  - `[OK] firewall carregado e habilitado no boot`;
  - `[OK] regras do Docker preservadas`.

**Validação com o guard armado (20:51–20:52):**

| Verificação | Resultado |
|---|---|
| Nova conexão SSH independente (sem multiplexação) | OK |
| Login por senha | Recusado (`Permission denied (publickey)`) |
| Regras efetivas | `allowed4` = sub-rede do ICS; `allowed6` = `fe80::/10`; `docker_lan_tcp` = {3001, 8090}; política `drop` |
| Beszel `/api/health` e Uptime Kuma, a partir do PC | HTTP 200 e HTTP 200 |
| Portas a partir do PC | 22, 8090 e 3001 abertas; 2375, 45876, 631, 80, 443, 8080 e 9000 bloqueadas |
| Portas em escuta no servidor | 22, 3001 e 8090; socket-proxy só em `127.0.0.1:2375` |
| Internet a partir do servidor | DNS OK; HTTPS 200 (deb.debian.org) |
| Contêineres | 4 no ar: beszel, beszel-agent, uptime-kuma e socket-proxy |
| Monitores do Kuma (banco lido sem alterar) | **9/9 UP**, com verificações posteriores à aplicação |

**Confirmação:** `touch ~/.homelab-guard-confirm` às 20:52:09. Às 21:01:54, depois do prazo do guard:
- o timer do guard tinha disparado e não existia mais;
- o `nftables.conf` estava na versão **nova** (não voltou à referência `9feefadd…`);
- o drop-in do SSH estava igual (`5f6a9ef3…`);
- um SSH novo funcionou, e a nova checagem pelo PC deu o mesmo resultado.

Ou seja, as mudanças foram **mantidas**. Equipamentos não foram reiniciados.

## Remoção do arquivo legado `docker-lan-tcp` (27/11/2026, 21:10)

- **Dependências.** No sistema instalado, só o `lib/firewall.sh` cita o arquivo, e só como reserva quando o `firewall.conf` não existe. O `homelab-m3-deploy.sh` do repositório também só o usa nesse caso, para gerar o `firewall.conf`. O `firewall.conf` existe (root, 0644) com `DOCKER_LAN_TCP=8090,3001`, o mesmo conteúdo do legado. Não há referências em units ou cron.
- **Cópia preservada** em `/var/backups/homelab-legado/docker-lan-tcp.20261127-211055`: arquivo `0600 root:root`, em diretório `0700`.
- **Firewall inalterado.** Os três valores foram iguais antes e depois da remoção:

  | Verificação | Valor |
  |---|---|
  | Regras geradas (`fw_render_from_conf`) | `32eead5a…` |
  | Regras ativas (`nft list table inet homelab_fw`) | `996e541b…` |
  | `nftables.conf` (md5) | `01e1b6c1…` |

  Resultado: `FIREWALL_INALTERADO`.
- **Serviços.** `ssh` e `nftables` ativos; SSH novo a partir do PC OK; 4 contêineres no ar; **9/9 monitores UP**.
- **Log do guard (evidência que faltava na fase 3):** `2026-11-27T21:01:25-03:00 guard: acesso confirmado; mudancas mantidas`, registrado no `guard.log` e no journal. As entradas da madrugada de 27/11 são do teste de reversão anterior, feito de propósito.
- O comentário do `stacks/monitoring/compose.yaml` que citava o arquivo antigo foi corrigido depois (só documentação; contêineres não recriados).

## Validação final de persistência: reboot do Wyse (27/11/2026)

Só o Wyse foi reiniciado; o Windows não. O reboot foi agendado pelo próprio script (`systemd-run`, +5 s) depois da linha de base, que exigiu ausência de backup, restauração ou `restic` em execução.

**Linha de base (21:27):**
- tudo OK, 9/9 monitores, nenhuma unit com falha;
- regras sem estado (`nft -s list table inet homelab_fw`) = `9e7a3082…`.

Na 1ª tentativa, a linha de base barrou o reboot por erro meu: comparei o hash da listagem **completa** das regras, que inclui contadores de pacotes e muda a cada pacote. Passei a usar a listagem sem estado (`nft -s`).

**Tempo de retorno:**
- comando de reboot às 21:27:13;
- SSH caiu às 21:27:26 e voltou às 21:28:10, **44 s depois da queda** (57 s desde o comando);
- boot do kernel às 21:27:40.

**Depois do reboot:**

| Verificação | Resultado |
|---|---|
| Drop-in do SSH e `nftables.conf` | md5 iguais (`5f6a9ef3…` e `01e1b6c1…`) |
| Regras ativas sem estado | `REGRAS_IGUAIS_A_LINHA_DE_BASE (9e7a3082…)` |
| `sshd -T` | `passwordauthentication no`, `permitrootlogin no`, `maxauthtries 3`, `logingracetime 30` |
| Serviços de acesso | `ssh` ativo; `nftables` ativo e habilitado; guard sem nada armado |
| Pelo PC | SSH por chave OK; senha recusada; Beszel e Kuma com HTTP 200; só as portas 22, 8090 e 3001 abertas (2375, 45876, 631, 80, 443, 8080 e 9000 bloqueadas) |
| Internet e DNS | DNS OK; HTTPS 200 |
| Hora | `NTPSynchronized=yes`, servidor NTP.br, stratum 1, offset −3,3 ms |
| Contêineres | 4 no ar, voltaram sozinhos; beszel, beszel-agent e uptime-kuma `healthy` |
| Monitores | **9/9 UP com batidas posteriores ao boot** (00:32–00:33 UTC; boot às 00:27:40 UTC). O push do backup segue UP dentro da janela de 26 h |
| Agendamentos | backup em 28/11 03:35; restauração em 01/12 04:30 |
| Último backup | `b6d9e6f2`; `restic check --read-data`: sem erros; manifesto do export OK |
| Recursos logo após o boot | load 3,14 (inicialização); RAM 892 MiB usados de 5368; `/` em 28%; temperaturas 58–60 °C; contêineres somando cerca de 210 MiB (o Kuma usa 41% de CPU só na partida) |
| Units com falha | 0 |

A primeira leitura dos monitores, logo após o boot, ainda mostrava batidas anteriores ao reboot. Por isso ela foi refeita com 6 min de uptime, exigindo batidas pós-boot (resultado acima).

**Resultado: persistência CONFIRMADA.**

