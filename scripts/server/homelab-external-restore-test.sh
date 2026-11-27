#!/bin/bash
# HomeLab - teste de restauracao a partir de uma COPIA EXTERNA (ex.: a copia "pull"
# do PC), com a senha do backup DIGITADA pela pessoa.
#
# Uso: sudo bash homelab-external-restore-test.sh <copia-do-export> [--no-compare-live]
#
# Etapas (qualquer falha => codigo de saida 1):
#   1. MANIFEST.sha256 da copia confere (copia completa e sem alteracao)
#   2. senha correta + restic check --read-data (100% dos dados)
#   3. restore --verify; configuracoes identicas as atuais (opcional)
#   4. dados dos servicos: contagem igual a do snapshot e bancos SQLite integros
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

REPO="${1:?uso: sudo bash $0 <copia-do-export> [--no-compare-live]}"
COMPARE_LIVE=1; [ "${2:-}" = "--no-compare-live" ] && COMPARE_LIVE=0
STACKS_DIR=${HL_STACKS_DIR:-/opt/homelab/stacks}
DATA="$STACKS_DIR/monitoring/data"
RESTORE_DBS=${HL_RESTORE_DBS:-"beszel/data.db uptime-kuma/kuma.db"}
read -ra STABLE <<< "${HL_RESTORE_STABLE:-$RS_STABLE_DEFAULT} $STACKS_DIR/monitoring/compose.yaml"
OUT=${HL_STATE_DIR:-/var/backups}/homelab-external-restore.status
[ -f "$REPO/config" ] || hl_die "nao parece um repositorio restic: $REPO" 2
T=$(mktemp -d "${TMPDIR:-/tmp}/hl-ext-restore.XXXXXX")
trap 'rm -rf -- "$T"; unset RESTIC_PASSWORD' EXIT

hl_section "1. Manifesto da copia"
if [ -f "$REPO/MANIFEST.sha256" ]; then
  ( cd -- "$REPO" && sha256sum -c --quiet --strict MANIFEST.sha256 ) && hl_ok "todos os arquivos conferem ($(wc -l < "$REPO/MANIFEST.sha256"))" \
    || { hl_fail "copia incompleta ou alterada"; echo EXTERNAL_RESTORE_FALHOU; hl_finish; }
  extra=$(cd -- "$REPO" && comm -13 <(sed 's/^[0-9a-f]*  //' MANIFEST.sha256 | sort) \
          <(find . -type f ! -name MANIFEST.sha256 ! -name GENERATION ! -path './locks/*' | sort) | head -5)
  [ -z "$extra" ] || { hl_fail "arquivos fora do manifesto: $extra"; echo EXTERNAL_RESTORE_FALHOU; hl_finish; }
else
  hl_fail "copia sem MANIFEST.sha256 (gerada antes do export consistente?)"; echo EXTERNAL_RESTORE_FALHOU; hl_finish
fi

hl_section "2. Senha e integridade (check --read-data)"
if [ -n "${HL_TEST_PASSWORD_FILE:-}" ]; then
  RESTIC_PASSWORD=$(cat -- "$HL_TEST_PASSWORD_FILE")      # somente nos testes automatizados
else
  echo ">>> Digite a SENHA DO BACKUP (a que voce guardou no gerenciador de senhas):"
  read -rsp "Senha do backup: " RESTIC_PASSWORD </dev/tty; echo
fi
export RESTIC_PASSWORD
restic -r "$REPO" snapshots --compact || { hl_fail "senha incorreta ou copia ilegivel"; echo EXTERNAL_RESTORE_FALHOU; hl_finish; }
restic -r "$REPO" check --read-data --no-lock >/dev/null && hl_ok "check --read-data sem erros" || hl_fail "restic check --read-data"

hl_section "3. Restauracao (--verify)"
rs_restore "$REPO" "$T" "${STABLE[@]}" "$DATA" && hl_ok "restore --verify" || hl_fail "restore"
if [ "$COMPARE_LIVE" -eq 1 ]; then
  if rs_compare_live "$T" "${STABLE[@]}" && [ "${RS_COMPARED:-0}" -gt 0 ]; then hl_ok "$RS_COMPARED configuracao(oes) identica(s)"; else hl_fail "configuracoes diferentes ou nenhuma comparada"; fi
fi

hl_section "4. Dados dos servicos"
rs_validate_service_data "$REPO" "$T" "$DATA" "$RESTORE_DBS" && hl_ok "dados dos servicos validos" || hl_fail "dados dos servicos invalidos"

if [ "$HL_FAILS" -eq 0 ]; then echo "EXTERNAL_RESTORE_OK $(date -Is)" | tee "$OUT"; else echo EXTERNAL_RESTORE_FALHOU; fi
hl_finish
