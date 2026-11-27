# CLAUDE.md — contexto permanente do HomeLab

Este arquivo orienta agentes (Claude Code) e pessoas que mantêm este repositório.

## O que é

Laboratório doméstico de estudo: um **Dell Wyse 7020** (AMD GX-420CA, 6 GB nominais / ~5,2 GiB úteis, **pendrive SATA de 32 GB** como disco) com **Debian 12**, administrado a partir de um PC **Windows 11**. Não é produção.

## Topologia (não muda sem decisão registrada)

- Internet do servidor = **ICS do Windows** (Wi-Fi → Ethernet). Sem o PC ligado, o servidor fica sem internet.
- Administração: SSH do PowerShell com o alias `homelab` (`~/.ssh/config` do PC) e **só chave**.
- Recuperação: console local (monitor + teclado, login com senha no `tty1`), kernel anterior no GRUB e uma chave SSH de recuperação guardada fora do PC.

## Regras invioláveis

1. **Nunca** publicar neste repositório: IPs internos, nomes de usuário, hostname, MACs, impressões digitais de chave, tokens, senhas, tópicos ntfy ou URLs de push. Use placeholders (`<usuario-admin>`, `<ip-do-servidor-na-lan>`).
2. **Sudo continua exigindo senha.** Não criar `NOPASSWD`, não estender o ticket do sudo e não pôr o administrador no grupo `docker`. Tarefas de root são agrupadas num script revisado e executadas com `ssh -t homelab sudo bash <script>` numa janela visível, onde a pessoa digita a senha.
3. Mudanças em **SSH ou firewall** só pelo `scripts/server/homelab-apply.sh`, que arma o guard de reversão. Confirmar com `touch ~/.homelab-guard-confirm` **só depois** de testar um login novo por chave.
4. **Não expor nada à internet.** As portas publicadas pelo Docker ficam bloqueadas por padrão; liberar uma porta para a LAN é editar `/etc/homelab/docker-lan-tcp` e reaplicar o `homelab-apply.sh`.
5. Não reiniciar o **PC Windows** sem autorização explícita. O Wyse pode ser reiniciado quando a tarefa pedir, desde que o console local esteja disponível.
6. Não remover o GNOME (ambiente gráfico de recuperação). Não instalar serviços além dos registrados em `stacks/`.
7. Orçamento zero: nada pago. Limites: RAM < ~2 GiB para todos os containers; disco: manter `/` abaixo de 70%.
8. Nada é **CONFIRMADO** sem evidência (comando, saída e data) num registro de marco em `docs/marcos/`.

## Onde está o quê

| Caminho no repo | No servidor / PC |
|---|---|
| `scripts/server/homelab-apply.sh` | `/usr/local/sbin/homelab-apply` — hora, atualizações, SSH, firewall, logs |
| `scripts/server/homelab-backup.sh` | `/usr/local/sbin/homelab-backup` + `homelab-backup.timer` (03:30) |
| `scripts/server/homelab-restore-test.sh` | `/usr/local/sbin/homelab-restore-test` + timer mensal |
| `scripts/server/homelab-m3-deploy.sh` | Implanta o M3 a partir de um clone do repositório |
| `stacks/monitoring/compose.yaml` | `/opt/homelab/stacks/monitoring/` (Beszel, Uptime Kuma, socket-proxy) |
| `scripts/windows/ics-watchdog.ps1` | `C:\ProgramData\HomeLab\` + tarefa `\HomeLab\HomeLab ICS Watchdog` (SYSTEM) |
| `scripts/windows/pull-homelab-backup.ps1` | `%USERPROFILE%\.homelab\` + tarefa `\HomeLab\HomeLab Backup Pull` (usuário); cópias em `%USERPROFILE%\HomeLab-Backups\` |

> **Atenção (Windows):** agentes que rodam dentro de apps empacotados (MSIX) veem `%LOCALAPPDATA%` virtualizado. Arquivos gravados ali não existem para tarefas agendadas. Use `%USERPROFILE%` ou `C:\ProgramData`.

Configuração local, fora do Git: `/etc/homelab/` (`backup.conf`, `restic.pass` 0600, `docker-lan-tcp`), `stacks/monitoring/.env` e `stacks/monitoring/secrets/` (chave e token do agente Beszel).

## Procedimentos

- **Saúde rápida:** abrir o Beszel (`:8090`) e o Uptime Kuma (`:3001`) na LAN. Pelo terminal: `ssh homelab 'systemctl --failed; cat /var/backups/homelab-*.status'`.
- **Atualizar uma stack:** mudar a tag da imagem em `stacks/<nome>/compose.yaml` (sempre com versão fixa), commitar e rodar o deploy com sudo.
- **Backup manual:** `sudo systemctl start homelab-backup.service`. **Teste de restauração:** `sudo systemctl start homelab-restore-test.service`.
- **Recuperação:** ver [`docs/recuperacao.md`](docs/recuperacao.md).
- **Depois de qualquer mudança:** validar, registrar a evidência no marco e atualizar o roadmap.

## Estilo da documentação

Português do Brasil. Estados: **CONFIRMADO**, **PENDENTE DE VALIDAÇÃO**, **PLANEJADO**, **ADIADO**, **DESCARTADO**. Medições sempre com data. Decisões em `docs/decisoes/` no formato ADR.
