#!/bin/bash
# HomeLab - configuracao administrativa do servidor (Debian 12). Idempotente.
#
# Uso: sudo bash homelab-apply.sh <usuario-admin> [--guard-minutes N] [--skip-upgrade]
#
# Mudancas em SSH e firewall ficam protegidas por um "guard": antes de aplica-las,
# o estado atual e salvo; se o acesso nao for confirmado (touch ~/.homelab-guard-confirm)
# em N minutos (padrao 10), o estado salvo e restaurado automaticamente.
set -u
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ADMIN_USER="${1:-}"; shift || true
GUARD_MINUTES=10; SKIP_UPGRADE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --guard-minutes) GUARD_MINUTES="${2:?}"; shift 2 ;;
    --skip-upgrade)  SKIP_UPGRADE=1; shift ;;
    *) echo "opcao desconhecida: $1"; exit 2 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "Execute com sudo."; exit 1; }
[ -n "$ADMIN_USER" ] && id "$ADMIN_USER" >/dev/null 2>&1 || { echo "uso: sudo bash $0 <usuario-admin> [--guard-minutes N] [--skip-upgrade]"; exit 2; }
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[ -s "$ADMIN_HOME/.ssh/authorized_keys" ] || { echo "ABORTADO: $ADMIN_USER nao tem authorized_keys; desligar senha trancaria o acesso."; exit 3; }

# Log legivel pelo administrador (criado antes do redirecionamento: sem corrida de permissao)
LOG="$ADMIN_HOME/homelab-apply.log"
install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" /dev/null "$LOG"
exec > >(tee -a "$LOG") 2>&1

FAILS=0
section() { echo; echo "===== $* ====="; }
ok()   { echo "[OK]    $*"; }
fail() { echo "[FALHA] $*"; FAILS=$((FAILS+1)); }
echo "Inicio: $(date -Is)  guard=${GUARD_MINUTES}min  skip_upgrade=$SKIP_UPGRADE"

GUARD_DIR=/var/lib/homelab-guard
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-homelab-hardening.conf
NFT_CONF=/etc/nftables.conf

# ------------------------------------------------------------------ 1. Hora
section "1. Hora (NTP + RTC)"
install -d /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/10-homelab.conf <<'EOF'
# NTP.br primeiro (Brasil), pool Debian como reserva.
[Time]
NTP=a.st1.ntp.br b.st1.ntp.br c.st1.ntp.br
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org
EOF
systemctl restart systemd-timesyncd
for _ in $(seq 1 20); do [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && break; sleep 2; done
if [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then
  ok "NTP sincronizado: $(date -Is)"
  hwclock --systohc --utc && ok "RTC gravado" || fail "hwclock --systohc"
else
  fail "NTP nao sincronizou (RTC nao alterado)"
fi

# ------------------------------------------------------------------ 2. Pacotes
section "2. Atualizacoes"
if [ "$SKIP_UPGRADE" -eq 1 ]; then
  echo "pulado (--skip-upgrade)"
else
  apt-get update -q && ok "apt update" || fail "apt update"
  apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade && ok "full-upgrade" || fail "full-upgrade"
  apt-get -y -q install unattended-upgrades apt-listchanges && ok "unattended-upgrades" || fail "instalar unattended-upgrades"
  apt-get -y -q autoremove --purge && ok "autoremove" || fail "autoremove"
fi
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52homelab-unattended <<'EOF'
// Somente seguranca (padrao Debian). Sem reboot automatico.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
if command -v unattended-upgrade >/dev/null; then
  unattended-upgrade --dry-run >/dev/null 2>&1 && ok "unattended-upgrade dry-run" || fail "unattended-upgrade dry-run"
fi

# ------------------------------------------------------------------ 3. Servicos
section "3. Servicos desnecessarios num servidor"
for s in cups.service cups-browsed.service cups.socket cups.path ModemManager.service bluetooth.service; do
  if systemctl list-unit-files "$s" --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now "$s" >/dev/null 2>&1 && ok "desativado: $s" || fail "desativar $s"
  fi
done

# ------------------------------------------------------------------ 4. Logs
section "4. Limites de log (pendrive)"
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-homelab.conf <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald && ok "journald 200M / 1 mes" || fail "journald"
if [ ! -s /etc/docker/daemon.json ]; then
  install -d /etc/docker
  printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' > /etc/docker/daemon.json
  systemctl restart docker && ok "docker: rotacao de logs" || fail "reiniciar docker"
else
  echo "daemon.json existente preservado"
fi

# ------------------------------------------------------------------ 5. Guard
section "5. Guard: snapshot do estado atual + reversao em ${GUARD_MINUTES} min"
install -d -m 700 "$GUARD_DIR"
rm -rf "$GUARD_DIR/snapshot"; install -d -m 700 "$GUARD_DIR/snapshot"
[ -f "$SSHD_DROPIN" ] && cp -a "$SSHD_DROPIN" "$GUARD_DIR/snapshot/sshd-dropin.conf"
cp -a "$NFT_CONF" "$GUARD_DIR/snapshot/nftables.conf"
systemctl is-enabled --quiet nftables && touch "$GUARD_DIR/snapshot/nft-enabled"
cat > /usr/local/sbin/homelab-guard-rollback <<EOF
#!/bin/bash
# Restaura o snapshot de SSH/firewall se o acesso nao foi confirmado.
S=$GUARD_DIR/snapshot; STAMP=$GUARD_DIR/armed; CONFIRM=$ADMIN_HOME/.homelab-guard-confirm
if [ -f "\$CONFIRM" ] && [ "\$CONFIRM" -nt "\$STAMP" ]; then
  logger -t homelab-guard "acesso confirmado; mudancas mantidas"; rm -f "\$STAMP" "\$CONFIRM"; exit 0
fi
logger -t homelab-guard "acesso NAO confirmado; restaurando snapshot"
if [ -f "\$S/sshd-dropin.conf" ]; then cp -a "\$S/sshd-dropin.conf" $SSHD_DROPIN; else rm -f $SSHD_DROPIN; fi
sshd -t && systemctl reload ssh
cp -a "\$S/nftables.conf" $NFT_CONF
nft delete table inet homelab_fw 2>/dev/null
if [ -f "\$S/nft-enabled" ]; then nft -f $NFT_CONF; systemctl enable nftables; else systemctl disable nftables; fi
echo "\$(date -Is) rollback executado" > $GUARD_DIR/last-rollback
rm -f "\$STAMP"
EOF
chmod 755 /usr/local/sbin/homelab-guard-rollback
systemctl stop homelab-guard.timer homelab-guard.service >/dev/null 2>&1
systemctl reset-failed homelab-guard.timer homelab-guard.service >/dev/null 2>&1
rm -f "$ADMIN_HOME/.homelab-guard-confirm"
touch "$GUARD_DIR/armed"
GUARD_OK=0
if systemd-run --quiet --unit=homelab-guard --on-active="${GUARD_MINUTES}min" /usr/local/sbin/homelab-guard-rollback; then
  GUARD_OK=1; ok "guard armado ($(date -d "+${GUARD_MINUTES} min" +%T))"
else
  fail "guard NAO armou: SSH e firewall nao serao alterados"
fi

# ------------------------------------------------------------------ 6. SSH
section "6. SSH somente por chave"
if [ "$GUARD_OK" -eq 1 ]; then
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
# HomeLab: somente chave publica. Protegido pelo homelab-guard.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers $ADMIN_USER
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  install -m 644 "$tmp" "$SSHD_DROPIN"; rm -f "$tmp"
  if sshd -t; then
    systemctl reload ssh && ok "sshd recarregado (sessoes atuais mantidas)" || fail "reload ssh"
  else
    fail "sshd -t reprovou; restaurando snapshot"
    if [ -f "$GUARD_DIR/snapshot/sshd-dropin.conf" ]; then cp -a "$GUARD_DIR/snapshot/sshd-dropin.conf" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
  fi
fi

# ------------------------------------------------------------------ 7. Firewall
section "7. Firewall nftables (entrada + portas publicadas do Docker)"
if [ "$GUARD_OK" -eq 1 ]; then
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
#!/usr/sbin/nft -f
# HomeLab firewall. Sem "flush ruleset": preserva as tabelas do Docker.
table inet homelab_fw
delete table inet homelab_fw

table inet homelab_fw {
  set lan4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } }

  # Portas publicadas pelo Docker (porta do HOST) liberadas para a rede local.
  # Vazio = nenhuma porta publicada acessivel. Ex.: elements = { 8080, 3000 }
  set docker_lan_tcp { type inet_service; }
  set docker_lan_udp { type inet_service; }

  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    iifname "docker0" accept
    iifname "br-*" accept
    ip saddr @lan4 tcp dport 22 accept comment "SSH so da rede local"
    ip6 saddr fe80::/10 tcp dport 22 accept
    ip saddr @lan4 udp dport 5353 accept comment "mDNS"
    ip6 saddr fe80::/10 udp dport 5353 accept
    udp sport 67 udp dport 68 accept comment "cliente DHCP"
    udp sport 547 udp dport 546 accept comment "cliente DHCPv6"
    limit rate 5/minute log prefix "homelab_fw drop: " level info
    counter drop
  }

  # Roda antes do Docker (priority filter - 10): um drop aqui e definitivo.
  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    ct state established,related accept
    iifname "docker0" accept
    iifname "br-*" accept
    ct status dnat oifname "docker0" jump docker_published
    ct status dnat oifname "br-*" jump docker_published
  }

  chain docker_published {
    ip saddr @lan4 meta l4proto tcp ct original proto-dst @docker_lan_tcp accept
    ip saddr @lan4 meta l4proto udp ct original proto-dst @docker_lan_udp accept
    limit rate 5/minute log prefix "homelab_fw docker drop: " level info
    counter drop
  }
}
EOF
  # Portas publicadas liberadas para a LAN: /etc/homelab/docker-lan-tcp (ex.: "8090,3001")
  LAN_TCP=$(tr -cd '0-9,' < /etc/homelab/docker-lan-tcp 2>/dev/null | sed 's/^,*//; s/,*$//')
  if [ -n "$LAN_TCP" ]; then
    sed -i "s|set docker_lan_tcp { type inet_service; }|set docker_lan_tcp { type inet_service; elements = { $LAN_TCP } }|" "$tmp"
    echo "portas Docker liberadas para a LAN: $LAN_TCP"
  fi
  if nft -c -f "$tmp"; then
    install -m 755 "$tmp" "$NFT_CONF"
    nft -f "$NFT_CONF" && systemctl enable nftables >/dev/null 2>&1 && ok "firewall ativo e habilitado no boot" || fail "carregar firewall"
    iptables -S DOCKER >/dev/null 2>&1 && ok "regras do Docker preservadas" || fail "cadeia DOCKER ausente"
  else
    fail "nft -c reprovou; firewall atual mantido"
  fi
  rm -f "$tmp"
fi

# ------------------------------------------------------------------ 8. Resumo
section "8. Resumo"
apt list --upgradable 2>/dev/null | tail -n +2 | sed 's/^/pendente: /'
[ -f /var/run/reboot-required ] && echo "REBOOT NECESSARIO" || echo "reboot nao necessario"
echo "kernel: $(uname -r)"
systemctl --failed --no-legend
echo "Fim: $(date -Is)  falhas=$FAILS"
if [ "$GUARD_OK" -eq 1 ]; then
  echo "APLICACAO_CONCLUIDA - confirme o acesso em ate ${GUARD_MINUTES} min: touch ~/.homelab-guard-confirm"
else
  echo "APLICACAO_CONCLUIDA_SEM_SSH_FIREWALL"
fi
exit $(( FAILS > 0 ? 1 : 0 ))
