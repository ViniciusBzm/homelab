#!/bin/bash
# HomeLab - implanta o M3 (observabilidade + backup). Idempotente.
# Codigo de saida != 0 se QUALQUER etapa falhar.
#
# Uso: sudo bash homelab-m3-deploy.sh <usuario-admin> <diretorio-do-repositorio>
#
# 1. Pacotes (restic, smartmontools)      5. Backup restic + timers + export
# 2. Saude do disco (S.M.A.R.T.)          6. Primeiro backup + teste real de restauracao
# 3. Stack Compose em /opt/homelab        7. Resumo de recursos
# 4. Scripts/bibliotecas + firewall (homelab-apply --only-ssh-firewall, com guard)
set -uo pipefail
# >>> hl-env: HL_* so valem no sandbox de testes (namespace de usuario). Num root real
# (mapa de uid identidade) toda variavel HL_* herdada e descartada: nada de PATH,
# bibliotecas ou caminhos injetados pelo ambiente em scripts privilegiados.
if grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$' /proc/self/uid_map 2>/dev/null; then
  for _hl_v in $(compgen -v HL_); do unset "$_hl_v"; done; unset _hl_v
fi
# <<< hl-env
export PATH=${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
export DEBIAN_FRONTEND=noninteractive
ADMIN_USER="${1:?uso: sudo bash $0 <usuario-admin> <repo>}"
REPO="$(readlink -f -- "${2:?uso: sudo bash $0 <usuario-admin> <repo>}")"
HL_LIB_DIR="$REPO/scripts/server/lib"
# shellcheck source=lib/common.sh
. "$HL_LIB_DIR/common.sh"
hl_require_root
getent passwd "$ADMIN_USER" >/dev/null || hl_die "usuario inexistente: $ADMIN_USER" 2
ADMIN_GROUP=$(id -gn "$ADMIN_USER")
STACKS_DIR=/opt/homelab/stacks
RESTIC_REPOSITORY=/var/backups/homelab-restic
RESTIC_PASSWORD_FILE=/etc/homelab/restic.pass
LIB_DST=/usr/local/lib/homelab
hl_lock /run/homelab-deploy.lock
HL_LOG_GROUP=$ADMIN_GROUP hl_log_init homelab-m3-deploy
mark() { echo "@@MARK $1 $(date +%T)"; }

# ------------------------------------------------------------------ 1
hl_section "1. Pacotes"
if apt-get update -q >/dev/null && apt-get -y -q install restic smartmontools >/dev/null; then
  hl_ok "restic $(restic version | awk '{print $2}'), smartmontools $(smartctl -V | awk 'NR==1{print $2}')"
else hl_fail "instalar restic/smartmontools"; fi

# ------------------------------------------------------------------ 2
hl_section "2. Saude do armazenamento"
SMART_TMP=$(mktemp); trap 'rm -f -- "$SMART_TMP"' EXIT
smartctl -i /dev/sda | grep -E 'Model|Capacity|SMART support' || true
if smartctl -H /dev/sda > "$SMART_TMP" 2>&1; then hl_ok "S.M.A.R.T.: $(grep -E 'result|Status' "$SMART_TMP" | head -1)"
else echo "S.M.A.R.T. indisponivel ou parcial (nao bloqueia):"; tail -3 "$SMART_TMP"; fi

# ------------------------------------------------------------------ 3
hl_section "3. Stack de monitoramento (Docker Compose)"
install -d -m 0755 /opt/homelab "$STACKS_DIR"
install -d -m 0750 -o root -g "$ADMIN_GROUP" "$STACKS_DIR/monitoring"
install -m 0640 -o root -g "$ADMIN_GROUP" "$REPO/stacks/monitoring/compose.yaml" "$STACKS_DIR/monitoring/compose.yaml"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$STACKS_DIR/monitoring/secrets"
for d in beszel beszel_socket beszel_agent uptime-kuma; do install -d -m 0750 "$STACKS_DIR/monitoring/data/$d"; done
LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
[ -n "$LAN_IP" ] || hl_fail "IP da LAN nao detectado"
printf 'BESZEL_APP_URL=http://%s:8090\n' "$LAN_IP" > "$STACKS_DIR/monitoring/.env"; chmod 0640 "$STACKS_DIR/monitoring/.env"
if ( cd "$STACKS_DIR/monitoring" && docker compose config -q && docker compose pull -q && docker compose up -d --remove-orphans ); then
  hl_ok "stack no ar"
else hl_fail "compose config/pull/up"; fi
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' beszel 2>/dev/null)" = healthy ] && curl -fs -o /dev/null http://127.0.0.1:3001 && break; sleep 4
done
[ "$(docker inspect -f '{{.State.Health.Status}}' beszel 2>/dev/null)" = healthy ] && hl_ok "beszel healthy" || hl_fail "beszel nao ficou healthy"
curl -fs -o /dev/null http://127.0.0.1:3001 && hl_ok "uptime-kuma responde" || hl_fail "uptime-kuma nao responde"

# ------------------------------------------------------------------ 4
hl_section "4. Scripts, bibliotecas e firewall"
install -d -m 0755 "$LIB_DST" /etc/homelab
install -m 0644 "$HL_LIB_DIR"/*.sh "$LIB_DST/"
for s in apply backup restore-test external-restore-test guard-rollback; do
  install -m 0755 "$REPO/scripts/server/homelab-$s.sh" "/usr/local/sbin/homelab-$s"
done
if [ ! -f /etc/homelab/firewall.conf ]; then
  # Sub-rede da interface da rota padrao (ex.: a sub-rede do ICS). Sem ela, nao restringe.
  DEF_IF=$(ip -4 route show default | awk '{print $5; exit}')
  NET=$(ip -4 route show dev "$DEF_IF" scope link 2>/dev/null | awk '{print $1; exit}')
  LAN_TCP=$(tr -cd '0-9,' < /etc/homelab/docker-lan-tcp 2>/dev/null || true)
  printf '%s\n' "# Gerado pelo homelab-m3-deploy. Ver scripts/server/lib/firewall.sh" \
    "ALLOWED_V4=$NET" "ALLOWED_V6=fe80::/10" "DOCKER_LAN_TCP=${LAN_TCP:-8090,3001}" "DOCKER_LAN_UDP=" > /etc/homelab/firewall.conf
  chmod 0644 /etc/homelab/firewall.conf
  hl_ok "firewall.conf criado (ALLOWED_V4=$NET)"
fi
if /usr/local/sbin/homelab-apply "$ADMIN_USER" --only-ssh-firewall >/dev/null 2>&1; then
  hl_ok "SSH/firewall reaplicados (guard 10 min: confirme o acesso)"
else
  hl_fail "homelab-apply retornou erro (ver /var/log/homelab/homelab-apply.log)"
fi
mark APPLY_DONE

# ------------------------------------------------------------------ 5
hl_section "5. Backup (restic)"
printf '%s\n' "ADMIN_USER=$ADMIN_USER" "RESTIC_REPOSITORY=$RESTIC_REPOSITORY" \
  "RESTIC_PASSWORD_FILE=$RESTIC_PASSWORD_FILE" "STACKS_DIR=$STACKS_DIR" \
  "EXPORT_DIR=/var/backups/homelab-restic-export" "EXPORT_GROUP=$ADMIN_GROUP" > /etc/homelab/backup.conf
chmod 0644 /etc/homelab/backup.conf
if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
  echo ">>> Crie a SENHA DO BACKUP (minimo 12 caracteres) e guarde-a no gerenciador de senhas."
  p1=""
  for _ in 1 2 3; do
    read -rsp "Senha do backup: " p1 </dev/tty; echo >/dev/tty
    read -rsp "Repita a senha:  " p2 </dev/tty; echo >/dev/tty
    [ "$p1" = "$p2" ] && [ ${#p1} -ge 12 ] && break
    echo "As senhas nao conferem ou tem menos de 12 caracteres." >/dev/tty; p1=""
  done
  if [ -n "$p1" ]; then ( umask 077; printf '%s' "$p1" > "$RESTIC_PASSWORD_FILE" ); unset p1 p2; hl_ok "senha do backup salva (0600, root)"
  else hl_fail "senha do backup nao definida"; fi
fi
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
if [ -s "$RESTIC_PASSWORD_FILE" ]; then
  if restic cat config >/dev/null 2>&1; then hl_ok "repositorio restic ja existe"
  else install -d -m 2750 -o root -g "$ADMIN_GROUP" "$RESTIC_REPOSITORY" && restic init >/dev/null && hl_ok "repositorio criado" || hl_fail "restic init"; fi
fi
install -m 0644 "$REPO"/scripts/server/systemd/homelab-*.service "$REPO"/scripts/server/systemd/homelab-*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now homelab-backup.timer homelab-restore-test.timer >/dev/null 2>&1 \
  && hl_ok "timers: backup 03:30, restauracao mensal" || hl_fail "timers"

# ------------------------------------------------------------------ 6
hl_section "6. Backup + teste real de restauracao"
systemctl start homelab-backup.service && hl_ok "backup: $(cat /var/backups/homelab-backup.status)" \
  || hl_fail "backup: $(cat /var/backups/homelab-backup.status 2>/dev/null)"
systemctl start homelab-restore-test.service && hl_ok "restauracao: $(cat /var/backups/homelab-restore-test.status)" \
  || hl_fail "restauracao: $(cat /var/backups/homelab-restore-test.status 2>/dev/null)"
sudo -u "$ADMIN_USER" test -r /var/backups/homelab-restic-export/MANIFEST.sha256 \
  && hl_ok "export legivel pelo administrador (copia pull)" || hl_fail "export nao legivel pelo administrador"

# ------------------------------------------------------------------ 7
hl_section "7. Recursos"
docker compose -f "$STACKS_DIR/monitoring/compose.yaml" ps --format 'table {{.Name}}\t{{.Status}}' || true
free -m | head -2; df -h / | tail -1
systemctl --failed --no-legend | grep . && hl_fail "ha unidades com falha" || echo "nenhuma unidade com falha"
mark DEPLOY_DONE
hl_finish
