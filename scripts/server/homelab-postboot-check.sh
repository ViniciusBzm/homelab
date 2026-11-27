#!/bin/bash
# HomeLab - verificacao com root apos reboot + teste real do rollback do guard.
#
# Uso: sudo bash homelab-postboot-check.sh <usuario-admin> [caminho/homelab-apply.sh]
#
# A) Aplica o homelab-apply.sh com guard de 2 min e NAO confirma: o guard deve
#    restaurar exatamente o estado anterior (arquivos e regras em memoria).
# B) Reaplica com guard normal (10 min) - o administrador confirma depois.
# C) Docker: hello-world, Alpine, Compose e consumo de um container.
# D) Porta publicada: bloqueada por padrao; liberada so ao entrar em docker_lan_tcp.
#    Marcadores "@@MARK" no log permitem que um cliente externo teste cada fase.
set -u
# >>> hl-env: HL_* so valem no sandbox de testes (namespace de usuario). Num root real
# (mapa de uid identidade) toda variavel HL_* herdada e descartada: nada de PATH,
# bibliotecas ou caminhos injetados pelo ambiente em scripts privilegiados.
if grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$' /proc/self/uid_map 2>/dev/null; then
  for _hl_v in $(compgen -v HL_); do unset "$_hl_v"; done; unset _hl_v
fi
# <<< hl-env
export PATH=${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
ADMIN_USER="${1:?uso: sudo bash $0 <usuario-admin> [homelab-apply.sh]}"
APPLY="${2:-$(dirname "$(readlink -f "$0")")/homelab-apply.sh}"
[ "$(id -u)" -eq 0 ] || { echo "Execute com sudo."; exit 1; }
[ -f "$APPLY" ] || { echo "homelab-apply.sh nao encontrado: $APPLY"; exit 2; }
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
LOG_DIR=/var/log/homelab; install -d -m 0750 -o root -g "$(id -gn "$ADMIN_USER")" "$LOG_DIR"
LOG="$LOG_DIR/homelab-postboot.log"; rm -f -- "$LOG"
install -m 0640 -o root -g "$(id -gn "$ADMIN_USER")" /dev/null "$LOG"
exec > >(tee -a "$LOG") 2>&1

FAILS=0
section() { echo; echo "===== $* ====="; }
ok()   { echo "[OK]    $*"; }
fail() { echo "[FALHA] $*"; FAILS=$((FAILS+1)); }
mark() { echo "@@MARK $1 $(date +%T)"; }
state_hash() { cat /etc/nftables.conf /etc/ssh/sshd_config.d/10-homelab-hardening.conf 2>/dev/null | sha256sum | cut -c1-16; }
GUARD_DIR=/var/lib/homelab-guard
echo "Inicio: $(date -Is)  kernel=$(uname -r)"

# ------------------------------------------------------------------ A
section "A. Teste do rollback (guard de 2 min, sem confirmacao)"
H0=$(state_hash); echo "estado anterior:  $H0"
bash "$APPLY" "$ADMIN_USER" --guard-minutes 2 --only-ssh-firewall >/dev/null 2>&1
H1=$(state_hash); echo "estado aplicado:  $H1"
nft list chain inet homelab_fw forward >/dev/null 2>&1 && echo "regras novas carregadas (cadeia forward presente)"
mark ROLLBACK_WAIT
for _ in $(seq 1 60); do [ -f "$GUARD_DIR/armed" ] || break; sleep 5; done
sleep 3
H2=$(state_hash); echo "apos o guard:     $H2"
if [ "$H2" = "$H0" ] && [ "$H1" != "$H0" ] && ! nft list chain inet homelab_fw forward >/dev/null 2>&1 && sshd -t; then
  ok "ROLLBACK_TEST_OK: arquivos e regras em memoria voltaram ao estado anterior ($(cat $GUARD_DIR/last-rollback 2>/dev/null))"
elif [ "$H1" = "$H0" ]; then
  fail "teste inconclusivo: a aplicacao nao mudou nada"
else
  fail "ROLLBACK_TEST_FALHOU"
fi
systemctl is-active --quiet ssh && ok "ssh ativo apos rollback" || fail "ssh inativo"

# ------------------------------------------------------------------ B
section "B. Aplicacao definitiva (guard de 10 min)"
bash "$APPLY" "$ADMIN_USER" --only-ssh-firewall >/dev/null 2>&1; rc=$?
grep -E '^\[(OK|FALHA)\]' /var/log/homelab/homelab-apply.log
[ $rc -eq 0 ] && ok "homelab-apply.sh sem falhas" || fail "homelab-apply.sh retornou $rc"
nft list chain inet homelab_fw forward >/dev/null 2>&1 && ok "protecao de portas Docker carregada" || fail "cadeia forward ausente"
mark APPLY_DONE

# ------------------------------------------------------------------ C
section "C. Docker"
systemctl is-active --quiet docker && ok "docker ativo" || fail "docker inativo"
docker version --format 'Engine {{.Server.Version}}' && docker compose version
docker run --rm hello-world 2>&1 | grep -q 'Hello from Docker' && ok "hello-world" || fail "hello-world"
docker run --rm alpine:3.22 sh -c 'echo "alpine: $(cat /etc/alpine-release)"; wget -q -T 5 -O /dev/null http://deb.debian.org && echo "rede do container: ok"' || fail "alpine"
tmpd=$(mktemp -d)
cat > "$tmpd/compose.yaml" <<'EOF'
services:
  teste:
    image: alpine:3.22
    command: ["sh", "-c", "echo compose-ok"]
EOF
(cd "$tmpd" && docker compose -p hlteste up --abort-on-container-exit 2>&1 | grep -q compose-ok && docker compose -p hlteste down >/dev/null 2>&1) && ok "compose up/down" || fail "compose"
rm -rf "$tmpd"
docker run -d --name hl-stats alpine:3.22 sleep 60 >/dev/null && sleep 3
docker stats --no-stream --format 'container {{.Name}}: CPU {{.CPUPerc}}  RAM {{.MemUsage}}' hl-stats
docker rm -f hl-stats >/dev/null && ok "container de medicao removido"

# ------------------------------------------------------------------ D
section "D. Porta publicada do Docker vs firewall"
docker run -d --rm --name hl-porttest -p 18080:8080 alpine:3.22 \
  sh -c 'while true; do printf "HTTP/1.0 200 OK\r\n\r\nporttest-ok\n" | nc -l -p 8080; done' >/dev/null
sleep 2
mark PORT_BLOCKED; sleep 40
nft add element inet homelab_fw docker_lan_tcp '{ 18080 }' && ok "18080 adicionada a docker_lan_tcp (temporario)"
mark PORT_ALLOWED; sleep 40
nft delete element inet homelab_fw docker_lan_tcp '{ 18080 }' && ok "18080 removida da lista"
docker rm -f hl-porttest >/dev/null 2>&1; ok "container de teste removido"
mark PORT_DONE

# ------------------------------------------------------------------ E
section "E. Recursos"
free -m | head -2; echo "load: $(cut -d' ' -f1-3 /proc/loadavg)"; df -h / | tail -1
docker ps -a --format '{{.Names}}' | grep . || echo "nenhum container restante"
docker system df
systemctl --failed --no-legend | grep . || echo "nenhuma unidade com falha"
echo "Fim: $(date -Is)  falhas=$FAILS"
mark POSTBOOT_DONE
exit $(( FAILS > 0 ? 1 : 0 ))
