#!/bin/bash
# HomeLab - implanta o M3 (observabilidade + backup). Idempotente.
#
# Uso: sudo bash homelab-m3-deploy.sh <usuario-admin> <diretorio-do-repositorio>
#
# 1. Pacotes: restic, smartmontools        5. Backup restic + timers systemd
# 2. Saude do disco (S.M.A.R.T.)           6. Primeiro backup + teste REAL de restauracao
# 3. Stack Compose em /opt/homelab         7. Resumo de recursos
# 4. Firewall: libera 8090/3001 so na LAN (via homelab-apply.sh, com guard)
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
ADMIN_USER="${1:?uso: sudo bash $0 <usuario-admin> <repo>}"
REPO="$(readlink -f "${2:?uso: sudo bash $0 <usuario-admin> <repo>}")"
[ "$(id -u)" -eq 0 ] || { echo "Execute com sudo."; exit 1; }
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
STACKS_DIR=/opt/homelab/stacks
RESTIC_REPOSITORY=/var/backups/homelab-restic
RESTIC_PASSWORD_FILE=/etc/homelab/restic.pass
LOG="$ADMIN_HOME/homelab-m3-deploy.log"
install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /dev/null "$LOG"
exec > >(tee -a "$LOG") 2>&1

FAILS=0
section() { echo; echo "===== $* ====="; }
ok()   { echo "[OK]    $*"; }
fail() { echo "[FALHA] $*"; FAILS=$((FAILS+1)); }
mark() { echo "@@MARK $1 $(date +%T)"; }
echo "Inicio: $(date -Is)"

# ------------------------------------------------------------------ 1
section "1. Pacotes"
apt-get update -q >/dev/null && apt-get -y -q install restic smartmontools >/dev/null \
  && ok "restic $(restic version | awk '{print $2}'), smartmontools $(smartctl -V | awk 'NR==1{print $2}')" \
  || fail "instalar restic/smartmontools"

# ------------------------------------------------------------------ 2
section "2. Saude do armazenamento"
smartctl -i /dev/sda | grep -E 'Model|Capacity|SMART support' || true
if smartctl -H /dev/sda >/tmp/smart.$$ 2>&1; then ok "S.M.A.R.T.: $(grep -E 'result|Status' /tmp/smart.$$ | head -1)"
else echo "S.M.A.R.T. indisponivel ou parcial neste dispositivo (rc=$?):"; tail -3 /tmp/smart.$$; fi
rm -f /tmp/smart.$$
echo "vida util/escrita (se suportado):"; smartctl -A /dev/sda 2>/dev/null | grep -Ei 'wear|lifetime|written|reallocated|pending|power_on' || echo "  atributos nao expostos pelo controlador"

# ------------------------------------------------------------------ 3
section "3. Stack de monitoramento (Docker Compose)"
install -d -m 755 /opt/homelab "$STACKS_DIR"
install -d -m 750 -o root -g "$ADMIN_USER" "$STACKS_DIR/monitoring"
install -m 640 -o root -g "$ADMIN_USER" "$REPO/stacks/monitoring/compose.yaml" "$STACKS_DIR/monitoring/compose.yaml"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$STACKS_DIR/monitoring/secrets"   # chave/token do agente
for d in beszel beszel_socket beszel_agent uptime-kuma; do install -d -m 750 "$STACKS_DIR/monitoring/data/$d"; done
LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
printf 'BESZEL_APP_URL=http://%s:8090\n' "$LAN_IP" > "$STACKS_DIR/monitoring/.env"; chmod 640 "$STACKS_DIR/monitoring/.env"
cd "$STACKS_DIR/monitoring"
docker compose config -q && ok "compose valido" || fail "compose invalido"
docker compose pull -q && ok "imagens baixadas" || fail "pull"
docker compose up -d --remove-orphans && ok "stack no ar" || fail "compose up"
for _ in $(seq 1 30); do
  h=$(docker inspect -f '{{.State.Health.Status}}' beszel 2>/dev/null)
  curl -fs -o /dev/null http://127.0.0.1:3001 && [ "$h" = healthy ] && break; sleep 4
done
echo "beszel: $(docker inspect -f '{{.State.Health.Status}}' beszel 2>/dev/null)"
curl -fs -o /dev/null http://127.0.0.1:3001 && ok "uptime-kuma responde" || fail "uptime-kuma nao responde"
docker inspect -f '{{if .Config.Healthcheck}}{{.Config.Healthcheck.Test}}{{else}}sem healthcheck{{end}}' uptime-kuma | sed 's/^/uptime-kuma healthcheck: /'
cd - >/dev/null

# ------------------------------------------------------------------ 4
section "4. Firewall: Beszel (8090) e Uptime Kuma (3001) so na LAN"
install -d -m 755 /etc/homelab
echo "8090,3001" > /etc/homelab/docker-lan-tcp
bash "$REPO/scripts/server/homelab-apply.sh" "$ADMIN_USER" --skip-upgrade >/dev/null 2>&1 \
  && ok "homelab-apply.sh reaplicado (guard 10 min)" || fail "homelab-apply.sh"
grep -E '^\[FALHA\]|portas Docker' "$ADMIN_HOME/homelab-apply.log" || true
mark APPLY_DONE

# ------------------------------------------------------------------ 5
section "5. Backup (restic)"
install -m 755 "$REPO/scripts/server/homelab-backup.sh"       /usr/local/sbin/homelab-backup
install -m 755 "$REPO/scripts/server/homelab-restore-test.sh" /usr/local/sbin/homelab-restore-test
install -m 755 "$REPO/scripts/server/homelab-apply.sh"        /usr/local/sbin/homelab-apply
cat > /etc/homelab/backup.conf <<EOF
ADMIN_USER=$ADMIN_USER
RESTIC_REPOSITORY=$RESTIC_REPOSITORY
RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE
STACKS_DIR=$STACKS_DIR
EOF
chmod 644 /etc/homelab/backup.conf
if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  echo
  echo ">>> Crie a SENHA DO BACKUP (minimo 12 caracteres). Guarde-a no seu gerenciador de senhas:"
  echo ">>> sem ela, nenhuma copia do backup pode ser restaurada."
  for _ in 1 2 3; do
    read -rsp "Senha do backup: " p1 </dev/tty; echo >/dev/tty
    read -rsp "Repita a senha:  " p2 </dev/tty; echo >/dev/tty
    if [ "$p1" = "$p2" ] && [ ${#p1} -ge 12 ]; then break; fi
    echo "As senhas nao conferem ou tem menos de 12 caracteres. Tente de novo." >/dev/tty; p1=""
  done
  if [ -n "${p1:-}" ]; then
    umask 077; printf '%s' "$p1" > "$RESTIC_PASSWORD_FILE"; umask 022; unset p1 p2
    ok "senha do backup salva em $RESTIC_PASSWORD_FILE (0600, root)"
  else
    fail "senha do backup nao definida"
  fi
fi
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
if [ -s "$RESTIC_PASSWORD_FILE" ]; then
  if restic cat config >/dev/null 2>&1; then ok "repositorio restic ja existe"
  else install -d -m 2750 -o root -g "$ADMIN_USER" "$RESTIC_REPOSITORY" && restic init >/dev/null && ok "repositorio restic criado" || fail "restic init"; fi
fi
install -m 644 "$REPO"/scripts/server/systemd/homelab-*.{service,timer} /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now homelab-backup.timer homelab-restore-test.timer >/dev/null 2>&1 \
  && ok "timers: backup diario 03:30, teste de restauracao mensal" || fail "timers"

# ------------------------------------------------------------------ 6
section "6. Primeiro backup + teste real de restauracao"
if systemctl start homelab-backup.service; then ok "backup: $(cat /var/backups/homelab-backup.status)"
else fail "backup: $(cat /var/backups/homelab-backup.status 2>/dev/null)"; journalctl -u homelab-backup -n 15 --no-pager; fi
restic snapshots --tag homelab --compact 2>/dev/null | tail -4
if systemctl start homelab-restore-test.service; then ok "restauracao: $(cat /var/backups/homelab-restore-test.status)"
else fail "restauracao: $(cat /var/backups/homelab-restore-test.status 2>/dev/null)"; journalctl -u homelab-restore-test -n 15 --no-pager; fi
sudo -u "$ADMIN_USER" test -r "$RESTIC_REPOSITORY/config" && ok "repositorio legivel pelo administrador (copia pull)" || fail "repositorio nao legivel pelo administrador"

# ------------------------------------------------------------------ 7
section "7. Recursos apos o M3"
docker compose -f "$STACKS_DIR/monitoring/compose.yaml" ps --format 'table {{.Name}}\t{{.Status}}'
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
free -m | head -2; df -h / | tail -1; du -sh /var/lib/docker "$STACKS_DIR" "$RESTIC_REPOSITORY" 2>/dev/null
systemctl --failed --no-legend | grep . || echo "nenhuma unidade com falha"
echo "Fim: $(date -Is)  falhas=$FAILS"
mark DEPLOY_DONE
