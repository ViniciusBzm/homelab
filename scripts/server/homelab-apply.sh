#!/bin/bash
# HomeLab - configuracao administrativa do servidor (Debian 12). Idempotente.
#
# Uso: sudo bash homelab-apply.sh <usuario-admin> [--guard-minutes N] [--skip-upgrade] [--only-ssh-firewall]
#
# SSH e firewall sao protegidos por um guard: snapshot do estado atual, reversao
# automatica em N minutos (padrao 10) sem confirmacao (touch ~/.homelab-guard-confirm)
# e reversao IMEDIATA se qualquer passo de SSH/firewall falhar.
# Uma unica execucao por vez (lock) e nenhuma nova enquanto um guard estiver pendente.
set -u
export DEBIAN_FRONTEND=noninteractive
# >>> hl-env: HL_* so valem no sandbox de testes. Falha segura: os overrides so sao
# mantidos se o processo estiver POSITIVAMENTE num namespace de usuario do tipo
# "unshare -r" (uid_map de uma linha "0 <uid> 1"). Root real, uid_map ilegivel ou
# qualquer falha => todas as HL_* herdadas sao descartadas. O grep usado e o do
# caminho absoluto do sistema (nao depende do PATH herdado).
_hl_keep=0
if [ -r /proc/self/uid_map ] && [ -x /usr/bin/grep ] \
   && /usr/bin/grep -qxE '[[:space:]]*0[[:space:]]+[1-9][0-9]*[[:space:]]+1[[:space:]]*' /proc/self/uid_map 2>/dev/null \
   && [ "$(/usr/bin/grep -c '' /proc/self/uid_map 2>/dev/null)" = 1 ]; then
  _hl_keep=1
fi
if [ "$_hl_keep" != 1 ]; then for _hl_v in $(compgen -v HL_); do unset "$_hl_v"; done; fi
unset _hl_keep _hl_v
# <<< hl-env
export PATH=${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
HL_LIB_DIR=${HL_LIB_DIR:-$(dirname -- "$(readlink -f -- "$0")")/lib}
[ -f "$HL_LIB_DIR/guard.sh" ] || HL_LIB_DIR=/usr/local/lib/homelab
# shellcheck source=lib/guard.sh
. "$HL_LIB_DIR/guard.sh"
# shellcheck source=lib/firewall.sh
. "$HL_LIB_DIR/firewall.sh"

ADMIN_USER="${1:-}"; shift || true
GUARD_MINUTES=10; SKIP_UPGRADE=0; ONLY_SF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --guard-minutes)     GUARD_MINUTES="${2:?}"; shift 2 ;;
    --skip-upgrade)      SKIP_UPGRADE=1; shift ;;
    --only-ssh-firewall) ONLY_SF=1; shift ;;
    *) hl_die "opcao desconhecida: $1" 2 ;;
  esac
done
[[ "$GUARD_MINUTES" =~ ^[0-9]+$ ]] && [ "$GUARD_MINUTES" -ge 1 ] || hl_die "--guard-minutes invalido" 2
hl_require_root
[ -n "$ADMIN_USER" ] && getent passwd "$ADMIN_USER" >/dev/null \
  || hl_die "uso: sudo bash $0 <usuario-admin> [--guard-minutes N] [--skip-upgrade] [--only-ssh-firewall]" 2
ADMIN_HOME=${HL_ADMIN_HOME:-$(getent passwd "$ADMIN_USER" | cut -d: -f6)}
AUTH_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
[ -s "$AUTH_KEYS" ] && [ ! -L "$AUTH_KEYS" ] \
  || hl_die "ABORTADO: $ADMIN_USER nao tem authorized_keys valido; desligar a senha trancaria o acesso." 3
ETC_DIR=${HL_ETC_DIR:-/etc/homelab}
CONFIRM="$ADMIN_HOME/.homelab-guard-confirm"

hl_lock "${HL_RUN_DIR:-/run}/homelab-apply.lock"
guard_pending && hl_die "ha um guard pendente ($GUARD_DIR/armed). Confirme o acesso (touch $CONFIRM) ou aguarde a reversao antes de reaplicar." 5
HL_LOG_GROUP=${HL_LOG_GROUP:-$(id -gn "$ADMIN_USER")}
hl_log_init homelab-apply
echo "guard=${GUARD_MINUTES}min skip_upgrade=$SKIP_UPGRADE only_ssh_firewall=$ONLY_SF"

if [ "$ONLY_SF" -eq 0 ]; then
  # ---------------------------------------------------------------- 1. Hora
  hl_section "1. Hora (NTP + RTC)"
  install -d /etc/systemd/timesyncd.conf.d
  printf '%s\n' '# NTP.br primeiro (Brasil), pool Debian como reserva.' '[Time]' \
    'NTP=a.st1.ntp.br b.st1.ntp.br c.st1.ntp.br' \
    'FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org' \
    > /etc/systemd/timesyncd.conf.d/10-homelab.conf
  systemctl restart systemd-timesyncd || hl_fail "reiniciar timesyncd"
  for _ in $(seq 1 20); do [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && break; sleep 2; done
  if [ "$(timedatectl show -p NTPSynchronized --value)" = yes ]; then
    hl_ok "NTP sincronizado: $(date -Is)"; hwclock --systohc --utc && hl_ok "RTC gravado" || hl_fail "hwclock --systohc"
  else
    hl_fail "NTP nao sincronizou (RTC nao alterado)"
  fi

  # ---------------------------------------------------------------- 2. Pacotes
  hl_section "2. Atualizacoes"
  if [ "$SKIP_UPGRADE" -eq 1 ]; then echo "pulado (--skip-upgrade)"; else
    apt-get update -q && hl_ok "apt update" || hl_fail "apt update"
    apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade && hl_ok "full-upgrade" || hl_fail "full-upgrade"
    apt-get -y -q install unattended-upgrades apt-listchanges && hl_ok "unattended-upgrades" || hl_fail "instalar unattended-upgrades"
    apt-get -y -q autoremove --purge && hl_ok "autoremove" || hl_fail "autoremove"
  fi
  printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' \
    'APT::Periodic::AutocleanInterval "7";' > /etc/apt/apt.conf.d/20auto-upgrades
  printf '%s\n' '// Somente seguranca (padrao Debian). Sem reboot automatico.' \
    'Unattended-Upgrade::Automatic-Reboot "false";' 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' \
    'Unattended-Upgrade::Remove-Unused-Dependencies "true";' > /etc/apt/apt.conf.d/52homelab-unattended
  if command -v unattended-upgrade >/dev/null; then
    unattended-upgrade --dry-run >/dev/null 2>&1 && hl_ok "unattended-upgrade dry-run" || hl_fail "unattended-upgrade dry-run"
  fi

  # ---------------------------------------------------------------- 3. Servicos
  hl_section "3. Servicos desnecessarios num servidor"
  for s in cups.service cups-browsed.service cups.socket cups.path ModemManager.service bluetooth.service; do
    if systemctl list-unit-files "$s" --no-legend 2>/dev/null | grep -q .; then
      systemctl disable --now "$s" >/dev/null 2>&1 && hl_ok "desativado: $s" || hl_fail "desativar $s"
    fi
  done

  # ---------------------------------------------------------------- 4. Logs
  hl_section "4. Limites de log (pendrive)"
  install -d /etc/systemd/journald.conf.d
  printf '%s\n' '[Journal]' 'SystemMaxUse=200M' 'MaxRetentionSec=1month' > /etc/systemd/journald.conf.d/10-homelab.conf
  systemctl restart systemd-journald && hl_ok "journald 200M / 1 mes" || hl_fail "journald"
  if [ ! -s /etc/docker/daemon.json ]; then
    install -d /etc/docker
    printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' > /etc/docker/daemon.json
    systemctl restart docker && hl_ok "docker: rotacao de logs" || hl_fail "reiniciar docker"
  else
    echo "daemon.json existente preservado"
  fi
fi

# ------------------------------------------------------------------ 5. Guard
hl_section "5. Guard: snapshot + reversao em ${GUARD_MINUTES} min"
TMPD=$(mktemp -d); trap 'rm -rf -- "$TMPD"' EXIT
# Gera e valida TUDO antes de tocar em qualquer coisa.
cat > "$TMPD/sshd.conf" <<EOF
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
if ! fw_render_from_conf "$ETC_DIR" > "$TMPD/nftables.conf"; then
  hl_fail "configuracao do firewall invalida ($ETC_DIR/firewall.conf); nada foi alterado"; hl_finish
fi
"$NFT_BIN" -c -f "$TMPD/nftables.conf" || { hl_fail "nft -c reprovou o ruleset gerado; nada foi alterado"; hl_finish; }
guard_snapshot && hl_ok "snapshot do estado atual" || { hl_fail "snapshot"; hl_finish; }
guard_arm "$GUARD_MINUTES" "$CONFIRM" && hl_ok "guard armado ($(date -d "+${GUARD_MINUTES} min" +%T))" \
  || { hl_fail "guard NAO armou: SSH e firewall nao foram alterados"; hl_finish; }

# Qualquer falha (ou interrupcao) daqui ate o fim restaura o snapshot na hora.
ROLLBACK_DONE=0
rollback_now() {
  [ "$ROLLBACK_DONE" -eq 1 ] && return; ROLLBACK_DONE=1
  echo "!!! falha durante SSH/firewall: restaurando o estado anterior agora"
  if guard_restore; then
    hl_ok "estado anterior restaurado"; guard_disarm
  else
    # Nao desarma: o timer tenta de novo e o "armed" bloqueia novas aplicacoes.
    echo "$(date -Is) restauracao imediata incompleta" > "$GUARD_DIR/rollback-failed"
    hl_fail "restauracao incompleta: guard MANTIDO armado (nova tentativa no timer). Verifique pelo console."
  fi
}
trap 'rollback_now; rm -rf -- "$TMPD"; exit 130' INT TERM HUP

# ------------------------------------------------------------------ 6. SSH
hl_section "6. SSH somente por chave"
install -m 0644 "$TMPD/sshd.conf" "$SSHD_DROPIN"
if sshd -t && systemctl reload ssh; then hl_ok "sshd validado e recarregado (sessoes atuais mantidas)"
else hl_fail "SSH: validacao ou reload falhou"; rollback_now; hl_finish; fi

# ------------------------------------------------------------------ 7. Firewall
hl_section "7. Firewall nftables (sub-rede autorizada, IPv6, portas do Docker)"
install -m 0755 "$TMPD/nftables.conf" "$NFT_CONF"
if "$NFT_BIN" -f "$NFT_CONF" && systemctl enable nftables >/dev/null 2>&1; then
  hl_ok "firewall carregado e habilitado no boot"
  grep -E '^\s*set (allowed4|allowed6|docker_lan_tcp)' "$NFT_CONF" | sed 's/^ */  /'
else
  hl_fail "firewall: falha ao carregar"; rollback_now; hl_finish
fi
if iptables -S DOCKER >/dev/null 2>&1; then hl_ok "regras do Docker preservadas"; else echo "aviso: cadeia DOCKER ausente (Docker parado?)"; fi
trap 'rm -rf -- "$TMPD"' INT TERM HUP

# ------------------------------------------------------------------ 8. Resumo
hl_section "8. Resumo"
[ -f /var/run/reboot-required ] && echo "REBOOT NECESSARIO" || echo "reboot nao necessario"
echo "kernel: $(uname -r)"
echo "APLICACAO_CONCLUIDA - confirme o acesso em ate ${GUARD_MINUTES} min: touch ~/.homelab-guard-confirm"
hl_finish
