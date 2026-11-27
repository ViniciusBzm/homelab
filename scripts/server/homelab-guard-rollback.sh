#!/bin/bash
# HomeLab - acao do timer do guard (instalado como /usr/local/sbin/homelab-guard-rollback).
# Mantem as mudancas se o administrador confirmou; senao restaura o snapshot.
set -u
# >>> hl-env: HL_* so valem no sandbox de testes (namespace de usuario). Num root real
# (mapa de uid identidade) toda variavel HL_* herdada e descartada: nada de PATH,
# bibliotecas ou caminhos injetados pelo ambiente em scripts privilegiados.
if grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$' /proc/self/uid_map 2>/dev/null; then
  for _hl_v in $(compgen -v HL_); do unset "$_hl_v"; done; unset _hl_v
fi
# <<< hl-env
export PATH=${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
HL_LIB_DIR=${HL_LIB_DIR:-/usr/local/lib/homelab}
# shellcheck source=lib/guard.sh
. "$HL_LIB_DIR/guard.sh"
hl_require_root
# Mesmo lock do homelab-apply: nunca restaura no meio de uma aplicacao.
hl_lock "${HL_RUN_DIR:-/run}/homelab-apply.lock" 600
guard_check
