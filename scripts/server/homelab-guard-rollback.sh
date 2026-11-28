#!/bin/bash
# HomeLab - acao do timer do guard (instalado como /usr/local/sbin/homelab-guard-rollback).
# Mantem as mudancas se o administrador confirmou; senao restaura o snapshot.
set -u
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
HL_LIB_DIR=${HL_LIB_DIR:-/usr/local/lib/homelab}
# shellcheck source=lib/guard.sh
. "$HL_LIB_DIR/guard.sh"
hl_require_root
# Mesmo lock do homelab-apply: nunca restaura no meio de uma aplicacao.
hl_lock "${HL_RUN_DIR:-/run}/homelab-apply.lock" 600
guard_check
