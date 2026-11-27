# Decisões arquiteturais (ADR)

| ADR | Decisão | Estado |
|---|---|---|
| [001](ADR-001-ics-watchdog.md) | Manter o ICS do Windows, com persistência + watchdog | Aceita |
| [002](ADR-002-firewall-nftables-docker.md) | nftables com tabela própria e bloqueio das portas publicadas do Docker | Aceita |
| [003](ADR-003-observabilidade-beszel-uptime-kuma.md) | Beszel + Uptime Kuma para observabilidade | Aceita |
| [004](ADR-004-backup-restic-pull.md) | Backup com restic local e cópia "pull" pelo PC | Aceita |
| [005](ADR-005-sem-ansible-por-enquanto.md) | Scripts idempotentes em vez de Ansible (por enquanto) | Aceita |
| [006](ADR-006-sudo-com-senha.md) | Sudo continua exigindo senha; tarefas de root em lote | Aceita |
| [007](ADR-007-guard-concorrencia-falhas-parciais.md) | Guard com lock, recusa com pendência, reversão imediata; logs de root seguros | Proposta (PR #2) |
