#!/bin/bash
# HomeLab-01 - configuracao administrativa (executar com sudo, uma vez).
# Seguro para reexecutar. Mudancas em SSH e firewall ficam protegidas por um
# "guard": se o acesso nao for confirmado em 10 min, elas sao revertidas sozinhas.
set -u
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ADMIN_USER="${1:?uso: sudo bash homelab-apply.sh <usuario-admin-com-chave-ssh>}"
LOG=/home/$ADMIN_USER/homelab-apply.log
exec > >(tee "$LOG") 2>&1
chown "$ADMIN_USER:$ADMIN_USER" "$LOG"; chmod 600 "$LOG"

section() { echo; echo "===== $* ====="; }
ok()   { echo "[OK]   $*"; }
fail() { echo "[FALHA] $*"; }
[ "$(id -u)" -eq 0 ] || { echo "Execute com sudo."; exit 1; }
echo "Inicio: $(date -Is)"

# ---------------------------------------------------------------- 1. Hora
section "1. Hora (NTP + RTC)"
install -d /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/10-homelab.conf <<'EOF'
# NTP.br primeiro (Brasil), pool Debian como reserva.
[Time]
NTP=a.st1.ntp.br b.st1.ntp.br c.st1.ntp.br
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org
EOF
systemctl restart systemd-timesyncd
for i in $(seq 1 20); do
  [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && break; sleep 2
done
if [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then
  ok "NTP sincronizado: $(date -Is)"
  hwclock --systohc --utc && ok "RTC gravado: $(hwclock --show 2>/dev/null)"
else
  fail "NTP ainda nao sincronizou (RTC nao alterado)"
fi
timedatectl timesync-status 2>/dev/null | grep -E 'Server|Offset' || true

# ---------------------------------------------------------------- 2. Pacotes
section "2. Atualizacoes do sistema"
apt-get update -q && ok "apt update"
echo "--- pendentes antes do upgrade ---"; apt list --upgradable 2>/dev/null | tail -n +2
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade && ok "full-upgrade"
apt-get -y -q install unattended-upgrades apt-listchanges && ok "unattended-upgrades instalado"
apt-get -y -q autoremove --purge && ok "autoremove (kernels antigos)"

section "3. Atualizacoes automaticas de seguranca"
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
unattended-upgrade --dry-run >/dev/null 2>&1 && ok "unattended-upgrade dry-run" || fail "unattended-upgrade dry-run"
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager | head -4

# ---------------------------------------------------------------- 4. Servicos
section "4. Servicos desnecessarios num servidor"
for s in cups.service cups-browsed.service cups.socket cups.path ModemManager.service bluetooth.service; do
  if systemctl list-unit-files "$s" --no-legend 2>/dev/null | grep -q .; then
    systemctl disable --now "$s" >/dev/null 2>&1 && ok "desativado: $s" || fail "$s"
  fi
done

# ---------------------------------------------------------------- 5. Desgaste do pendrive
section "5. Limites de log (disco e pendrive)"
install -d /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-homelab.conf <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald && ok "journald limitado a 200M / 1 mes"
if [ ! -s /etc/docker/daemon.json ]; then
  install -d /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker && ok "docker: rotacao de logs 10m x3"
else
  echo "daemon.json ja existe; nao alterado"
fi

# ---------------------------------------------------------------- 6. Guard
section "6. Guard de reversao automatica (10 min)"
cat > /usr/local/sbin/homelab-guard-rollback <<'EOF'
#!/bin/bash
# Reverte SSH/firewall se ~ADMIN/.homelab-guard-confirm nao for
# criado depois do inicio do guard.
STAMP=/run/homelab-guard.stamp
CONFIRM=/home/__ADMIN_USER__/.homelab-guard-confirm
if [ -f "$CONFIRM" ] && [ "$CONFIRM" -nt "$STAMP" ]; then
  logger -t homelab-guard "acesso confirmado; mudancas mantidas"; rm -f "$STAMP" "$CONFIRM"; exit 0
fi
logger -t homelab-guard "acesso NAO confirmado; revertendo SSH e firewall"
rm -f /etc/ssh/sshd_config.d/10-homelab-hardening.conf
sshd -t && systemctl reload ssh
nft delete table inet homelab_fw 2>/dev/null
systemctl disable nftables 2>/dev/null
[ -f /etc/nftables.conf.homelab-bak ] && cp -f /etc/nftables.conf.homelab-bak /etc/nftables.conf
rm -f "$STAMP"
EOF
sed -i "s/__ADMIN_USER__/$ADMIN_USER/" /usr/local/sbin/homelab-guard-rollback
chmod 755 /usr/local/sbin/homelab-guard-rollback
systemctl stop homelab-guard.timer homelab-guard.service 2>/dev/null
rm -f "/home/$ADMIN_USER/.homelab-guard-confirm"
touch /run/homelab-guard.stamp
systemd-run --quiet --unit=homelab-guard --on-active=10min /usr/local/sbin/homelab-guard-rollback \
  && ok "guard armado: reverte em 10 min se nao confirmado"

# ---------------------------------------------------------------- 7. SSH
section "7. Endurecimento do SSH"
cat > /etc/ssh/sshd_config.d/10-homelab-hardening.conf <<EOF
# HomeLab: somente chave publica. Revertido pelo guard se nao confirmado.
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
if sshd -t; then
  systemctl reload ssh && ok "sshd recarregado (sessoes atuais mantidas)"
  sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|x11forwarding|maxauthtries|allowusers)'
else
  fail "sshd -t reprovou; configuracao removida"; rm -f /etc/ssh/sshd_config.d/10-homelab-hardening.conf
fi

# ---------------------------------------------------------------- 8. Firewall
section "8. Firewall (nftables, compativel com Docker)"
[ -f /etc/nftables.conf.homelab-bak ] || cp -a /etc/nftables.conf /etc/nftables.conf.homelab-bak
cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# HomeLab firewall. Sem "flush ruleset": preserva as tabelas do Docker.
table inet homelab_fw
delete table inet homelab_fw

table inet homelab_fw {
  set lan4 { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } }

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
    ip saddr @lan4 udp dport 5353 accept comment "mDNS (HomeLab-01.local)"
    ip6 saddr fe80::/10 udp dport 5353 accept
    udp sport 67 udp dport 68 accept comment "cliente DHCP"
    udp sport 547 udp dport 546 accept comment "cliente DHCPv6"
    limit rate 5/minute log prefix "homelab_fw drop: " level info
    counter drop
  }
}
EOF
if nft -c -f /etc/nftables.conf; then
  nft -f /etc/nftables.conf && systemctl enable nftables >/dev/null 2>&1 && ok "firewall ativo e habilitado no boot"
  nft list table inet homelab_fw | head -30
  iptables -S DOCKER >/dev/null 2>&1 && ok "regras do Docker preservadas"
else
  fail "nft -c reprovou; firewall nao aplicado"; cp -f /etc/nftables.conf.homelab-bak /etc/nftables.conf
fi

# ---------------------------------------------------------------- 9. Auditoria final
section "9. Auditoria final"
apt list --upgradable 2>/dev/null | tail -n +2 | sed 's/^/pendente: /'
[ -f /var/run/reboot-required ] && echo "REBOOT NECESSARIO: $(cat /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')" || echo "reboot nao necessario"
uname -r; dpkg -l 'linux-image-*' | awk '/^ii/{print $2, $3}'
systemctl --failed --no-legend
ss -tulnp | grep -v '^Netid'
df -h /
echo
echo "Fim: $(date -Is)"
echo "APLICACAO_CONCLUIDA - confirme o acesso SSH em ate 10 min (touch ~/.homelab-guard-confirm)"
