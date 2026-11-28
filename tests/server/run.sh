#!/bin/bash
# Suite de testes dos scripts de servidor do HomeLab.
#
# Isolamento: roda dentro de "unshare -rn" (namespace de usuario + de rede):
#   - "root" falso (uid 0 so dentro do namespace): os scripts passam no hl_require_root
#     mas nao conseguem alterar nada do sistema real;
#   - rede isolada: o nft real opera numa pilha de rede vazia e descartavel;
#   - todos os caminhos (HL_*) apontam para um diretorio temporario apagado ao final;
#   - docker, systemctl, sshd, systemd-run, curl, logger e iptables sao simulados.
# restic, flock, sha256sum, tar e python3 sao reais.
#
# Uso: bash tests/server/run.sh [filtro]     (ex.: bash tests/server/run.sh backup)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
if [ "${HL_IN_SANDBOX:-}" != 1 ]; then
  command -v unshare >/dev/null || { echo "unshare ausente"; exit 2; }
  HL_IN_SANDBOX=1 exec unshare -rnm bash "$0" "$@"
fi
[ "$(id -u)" = 0 ] || { echo "namespace sem uid 0"; exit 2; }
# /tmp proprio (tmpfs) num namespace de montagem privado: nao afeta o /tmp real e tem
# dono mapeado, para o restic conseguir restaurar os metadados dos diretorios pais.
mount -t tmpfs -o size=512m,mode=1777 hl-tests /tmp || { echo "nao foi possivel montar tmpfs privado"; exit 2; }
FILTER=${1:-}
ROOT_SB=$(mktemp -d /tmp/hl-tests.XXXXXX); trap 'rm -rf "$ROOT_SB"' EXIT
chmod +x "$HERE"/mocks/*
export PATH="$HERE/mocks:/usr/sbin:/sbin:/usr/bin:/bin"
export HL_PATH="$PATH"      # os scripts usam HL_PATH no lugar do PATH fixo de producao
export REPO HERE
# Trava de seguranca: aborta se qualquer comando de sistema nao resolver para o mock.
for c in docker systemctl sshd systemd-run curl logger iptables; do
  [ "$(PATH=$HL_PATH command -v "$c")" = "$HERE/mocks/$c" ] || { echo "ABORTADO: $c nao resolve para o mock"; exit 3; }
done
for s in "$REPO"/scripts/server/homelab-*.sh; do
  grep -q '^export PATH=\${HL_PATH:-' "$s" || { echo "ABORTADO: $s nao respeita HL_PATH"; exit 3; }
done
# shellcheck source=lib.sh
. "$HERE/lib.sh"
for t in "$HERE"/test_*.sh; do . "$t"; done

PASS=0; FAIL=0; FAILED=()
for fn in $(declare -F | awk '{print $3}' | grep '^t_' | grep -- "$FILTER"); do
  SB="$ROOT_SB/$fn"; mkdir -p "$SB"
  if ( set +e; export SB; setup_common; "$fn" ) > "$SB.out" 2>&1; then
    PASS=$((PASS + 1)); printf '  \033[32mPASSOU\033[0m %s\n' "$fn"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$fn"); printf '  \033[31mFALHOU\033[0m %s\n' "$fn"; sed 's/^/        | /' "$SB.out" | tail -25
  fi
done
echo; echo "Resultado: $PASS passaram, $FAIL falharam ($(date -Is), $(uname -r), restic $(restic version | awk '{print $2}'), $(/usr/sbin/nft --version))"
[ "$FAIL" -eq 0 ]
