#!/bin/bash
# HomeLab - teste REAL de restauracao do repositorio local (homelab-restore-test.timer).
# Restaura o ultimo snapshot num diretorio temporario e valida:
#   - configuracoes estaveis identicas byte a byte as atuais;
#   - dados dos servicos completos (contagem igual a do snapshot) e bancos SQLite integros.
# Usa o mesmo lock do backup: nunca roda durante backup/prune.
set -uo pipefail
# >>> hl-env: HL_* so valem no sandbox de testes (namespace de usuario). Num root real
# (mapa de uid identidade) toda variavel HL_* herdada e descartada: nada de PATH,
# bibliotecas ou caminhos injetados pelo ambiente em scripts privilegiados.
if grep -qE '^[[:space:]]*0[[:space:]]+0[[:space:]]+4294967295[[:space:]]*$' /proc/self/uid_map 2>/dev/null; then
  for _hl_v in $(compgen -v HL_); do unset "$_hl_v"; done; unset _hl_v
fi
# <<< hl-env
export PATH=${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
HL_LIB_DIR=${HL_LIB_DIR:-$(dirname -- "$(readlink -f -- "$0")")/lib}
[ -f "$HL_LIB_DIR/restore.sh" ] || HL_LIB_DIR=/usr/local/lib/homelab
# shellcheck source=lib/restore.sh
. "$HL_LIB_DIR/restore.sh"
hl_require_root

CONF=${HL_BACKUP_CONF:-/etc/homelab/backup.conf}
ADMIN_USER=""; RESTIC_REPOSITORY=""; RESTIC_PASSWORD_FILE=""; STACKS_DIR=/opt/homelab/stacks
EXPORT_DIR=""; EXPORT_GROUP=""; BACKUP_PATHS=""; PAUSE_SERVICES=""
RESTORE_STABLE=""; RESTORE_DBS="beszel/data.db uptime-kuma/kuma.db"
hl_read_conf "$CONF" ADMIN_USER RESTIC_REPOSITORY RESTIC_PASSWORD_FILE STACKS_DIR EXPORT_DIR EXPORT_GROUP BACKUP_PATHS PAUSE_SERVICES RESTORE_STABLE RESTORE_DBS
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
STATE=${HL_STATE_DIR:-/var/backups}; OUT="$STATE/homelab-restore-test.status"
DATA="$STACKS_DIR/monitoring/data"
read -ra STABLE <<< "${RESTORE_STABLE:-$RS_STABLE_DEFAULT} $STACKS_DIR/monitoring/compose.yaml"

hl_lock "${HL_RUN_DIR:-/run}/homelab-backup.lock" "${HL_LOCK_WAIT:-1800}"
HL_LOG_GROUP=${HL_LOG_GROUP:-$(id -gn "$ADMIN_USER")}
hl_log_init homelab-restore-test
T=$(mktemp -d "${TMPDIR:-/tmp}/homelab-restore.XXXXXX"); trap 'rm -rf -- "$T"' EXIT

hl_section "Restauracao do ultimo snapshot (--verify)"
rs_restore "$RESTIC_REPOSITORY" "$T" "${STABLE[@]}" "$DATA" && hl_ok "restic restore --verify" || hl_fail "restic restore"
hl_section "Configuracoes estaveis"
if rs_compare_live "$T" "${STABLE[@]}" && [ "${RS_COMPARED:-0}" -gt 0 ]; then hl_ok "$RS_COMPARED item(ns) identico(s)"; else hl_fail "configuracoes diferentes ou nenhuma comparada"; fi
hl_section "Dados dos servicos"
rs_validate_service_data "$RESTIC_REPOSITORY" "$T" "$DATA" "$RESTORE_DBS" && hl_ok "dados dos servicos validos" || hl_fail "dados dos servicos invalidos"

if [ "$HL_FAILS" -eq 0 ]; then echo "ok $(date -Is) itens=${RS_COMPARED:-0} dbs_ok" > "$OUT"; echo RESTORE_TEST_OK
else echo "fail $(date -Is) falhas=$HL_FAILS" > "$OUT"; echo RESTORE_TEST_FALHOU; fi
chmod 0644 "$OUT"
hl_finish
