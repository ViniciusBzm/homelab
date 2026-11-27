#!/bin/bash
# HomeLab - teste REAL de restauracao: restaura o ultimo snapshot num diretorio
# temporario e compara byte a byte com os arquivos atuais. Executado pelo
# homelab-restore-test.timer (mensal) e pelo deploy.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
. /etc/homelab/backup.conf
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
OUT=/var/backups/homelab-restore-test.status
T=$(mktemp -d /tmp/homelab-restore.XXXXXX); trap 'rm -rf "$T"' EXIT

# Arquivos estaveis (nao mudam entre o backup e o teste)
CHECK=(/etc/ssh/sshd_config.d /etc/nftables.conf /etc/homelab/backup.conf
       /etc/systemd/timesyncd.conf.d "$STACKS_DIR/monitoring/compose.yaml")
INC=(); for p in "${CHECK[@]}"; do [ -e "$p" ] && INC+=(--include "$p"); done

restic restore latest --tag homelab --target "$T" "${INC[@]}" >/dev/null
ok=0; bad=0
for p in "${CHECK[@]}"; do
  [ -e "$p" ] || continue
  if diff -r "$p" "$T$p" >/dev/null 2>&1; then ok=$((ok+1)); else bad=$((bad+1)); echo "DIFERENTE: $p"; fi
done
n=$(find "$T" -type f | wc -l)
if [ "$bad" -eq 0 ] && [ "$ok" -gt 0 ]; then
  echo "ok $(date -Is) itens=$ok arquivos=$n" | tee "$OUT"; chmod 644 "$OUT"; echo RESTORE_TEST_OK
else
  echo "fail $(date -Is) iguais=$ok diferentes=$bad" | tee "$OUT"; chmod 644 "$OUT"; exit 1
fi
