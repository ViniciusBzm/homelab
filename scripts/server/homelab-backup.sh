#!/bin/bash
# HomeLab - backup das configuracoes essenciais com restic (executado pelo
# homelab-backup.timer). Repositorio local criptografado, legivel pelo grupo do
# administrador, para que o PC Windows puxe uma copia por SSH (modelo "pull").
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CONF=/etc/homelab/backup.conf
# shellcheck source=/dev/null
. "$CONF"   # ADMIN_USER, RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE, STACKS_DIR
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
META=/var/backups/homelab-meta
STATUS=/var/backups/homelab-backup.status
PUSH_URL_FILE="$ADMIN_HOME/.config/homelab/backup-push-url"   # Uptime Kuma (push), opcional

log() { echo "$(date -Is) $*"; }
push() {  # avisa o Uptime Kuma; sem URL configurada, nao faz nada
  [ -s "$PUSH_URL_FILE" ] || return 0
  curl -fsS -m 10 -G --data-urlencode "status=$1" --data-urlencode "msg=$2" "$(head -1 "$PUSH_URL_FILE")" >/dev/null || true
}
fail() { log "FALHA: $*"; echo "fail $(date -Is) $*" > "$STATUS"; push down "backup falhou: $*"; exit 1; }
trap 'fail "erro na linha $LINENO"' ERR

# 1. Metadados para reconstruir o sistema
install -d -m 750 "$META"
dpkg --get-selections            > "$META/dpkg-selections.txt"
apt-mark showmanual              > "$META/apt-manual.txt"
systemctl list-unit-files --state=enabled --no-legend > "$META/enabled-units.txt"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$META/containers.txt" 2>/dev/null || true
uname -a > "$META/uname.txt"

# 2. Pausa os servicos com banco SQLite para uma copia consistente (~10 s)
STOPPED=0
if [ -f "$STACKS_DIR/monitoring/compose.yaml" ]; then
  (cd "$STACKS_DIR/monitoring" && docker compose stop beszel uptime-kuma >/dev/null 2>&1) && STOPPED=1
fi
restart_services() { [ "$STOPPED" -eq 1 ] && (cd "$STACKS_DIR/monitoring" && docker compose start beszel uptime-kuma >/dev/null 2>&1) || true; }
trap 'restart_services' EXIT

# 3. Backup
log "backup iniciado"
restic backup --quiet --tag homelab --exclude-caches \
  --exclude "$ADMIN_HOME/.cache" --exclude "$ADMIN_HOME/Downloads" \
  /etc /opt/homelab "$ADMIN_HOME" /root "$META" /var/lib/homelab-guard
restart_services; STOPPED=0

# 4. Retencao e verificacao
restic forget --quiet --tag homelab --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
if [ "$(date +%u)" = 7 ]; then restic check --read-data-subset=10% >/dev/null; else restic check >/dev/null; fi

# 5. Permissoes para a copia "pull" (somente leitura para o grupo do administrador)
chgrp -R "$ADMIN_USER" "$RESTIC_REPOSITORY"
find "$RESTIC_REPOSITORY" -type d -exec chmod 2750 {} +
find "$RESTIC_REPOSITORY" -type f -exec chmod 440 {} +

SNAP=$(restic snapshots --tag homelab --latest 1 --json | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)
SIZE=$(du -sh "$RESTIC_REPOSITORY" | cut -f1)
echo "ok $(date -Is) snapshot=$SNAP repo=$SIZE" > "$STATUS"; chmod 644 "$STATUS"
log "backup concluido: snapshot $SNAP, repositorio $SIZE"
push up "snapshot $SNAP ($SIZE)"
