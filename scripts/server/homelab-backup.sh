#!/bin/bash
# HomeLab - backup restic das configuracoes essenciais (homelab-backup.timer).
#
# Consistencia:
# - Uma execucao por vez (lock); o teste de restauracao usa o mesmo lock.
# - Servicos com SQLite sao pausados durante o "restic backup" e SEMPRE religados
#   (inclusive em erro); se nao voltarem, o backup termina com falha e alerta.
# - Depois de backup + forget/prune + check, publica um EXPORT imutavel (hardlinks:
#   o restic nunca altera arquivos ja gravados) com MANIFEST.sha256, trocado de forma
#   atomica sob lock exclusivo. O PC copia somente o export, sob lock compartilhado,
#   e valida o manifesto: nunca copia um repositorio no meio de um prune.
set -uo pipefail
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
[ -f "$HL_LIB_DIR/common.sh" ] || HL_LIB_DIR=/usr/local/lib/homelab
# shellcheck source=lib/common.sh
. "$HL_LIB_DIR/common.sh"
hl_require_root

CONF=${HL_BACKUP_CONF:-/etc/homelab/backup.conf}
ADMIN_USER=""; RESTIC_REPOSITORY=""; RESTIC_PASSWORD_FILE=""; STACKS_DIR=/opt/homelab/stacks
EXPORT_DIR=""; EXPORT_GROUP=""; BACKUP_PATHS=""; PAUSE_SERVICES="beszel uptime-kuma"
RESTORE_STABLE=""; RESTORE_DBS=""
hl_read_conf "$CONF" ADMIN_USER RESTIC_REPOSITORY RESTIC_PASSWORD_FILE STACKS_DIR EXPORT_DIR EXPORT_GROUP BACKUP_PATHS PAUSE_SERVICES RESTORE_STABLE RESTORE_DBS
[ -n "$ADMIN_USER" ] && [ -n "$RESTIC_REPOSITORY" ] && [ -n "$RESTIC_PASSWORD_FILE" ] || hl_die "$CONF incompleto" 3
hl_require_secure_file "$RESTIC_PASSWORD_FILE"
[ $(( 8#$(stat -c %a -- "$RESTIC_PASSWORD_FILE") & 8#077 )) -eq 0 ] || hl_die "senha do backup legivel por grupo/outros: $RESTIC_PASSWORD_FILE" 3
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

ADMIN_HOME=${HL_ADMIN_HOME:-$(getent passwd "$ADMIN_USER" | cut -d: -f6)}
ADMIN_UID=$(id -u "$ADMIN_USER" 2>/dev/null || echo -1)
STATE=${HL_STATE_DIR:-/var/backups}
META="$STATE/homelab-meta"; STATUS="$STATE/homelab-backup.status"
EXPORT_DIR=${EXPORT_DIR:-$STATE/homelab-restic-export}; EXPORT_LOCK="$EXPORT_DIR.lock"
EXPORT_GROUP=${EXPORT_GROUP:-$(id -gn "$ADMIN_USER")}
COMPOSE_FILE="$STACKS_DIR/monitoring/compose.yaml"
PUSH_URL_FILE=${HL_PUSH_URL_FILE:-$ADMIN_HOME/.config/homelab/backup-push-url}
[ -n "$BACKUP_PATHS" ] || BACKUP_PATHS="/etc /opt/homelab $ADMIN_HOME /root $META /var/lib/homelab-guard"

hl_lock "${HL_RUN_DIR:-/run}/homelab-backup.lock"
HL_LOG_GROUP=${HL_LOG_GROUP:-$EXPORT_GROUP}
hl_log_init homelab-backup

# --- Push para o Uptime Kuma: arquivo do administrador tratado como NAO confiavel.
push() {
  local url
  [ -e "$PUSH_URL_FILE" ] || return 0
  if [ -L "$PUSH_URL_FILE" ] || [ ! -f "$PUSH_URL_FILE" ] || [ "$(stat -c %u -- "$PUSH_URL_FILE")" != "$ADMIN_UID" ]; then
    echo "aviso: $PUSH_URL_FILE ignorado (link, tipo ou dono inesperado)"; return 0
  fi
  url=$(head -c 300 -- "$PUSH_URL_FILE" | head -n 1)
  if [[ ! "$url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]{1,5}/api/push/[A-Za-z0-9]{8,64}$ ]]; then
    echo "aviso: URL de push invalida ignorada (so http://127.0.0.1:<porta>/api/push/<token>)"; return 0
  fi
  # Retry: o Kuma pode ainda estar subindo logo apos o religamento. Para na primeira
  # confirmacao ({"ok":true}); limite total de PUSH_LIMIT s. So a notificacao e repetida,
  # nunca o backup. O token nao vai para o log (stderr do curl descartado; so o codigo).
  local limit=${HL_PUSH_LIMIT:-180} interval=${HL_PUSH_INTERVAL:-10} deadline n=0 rc left resp
  deadline=$((SECONDS + limit))
  while left=$((deadline - SECONDS)); [ "$left" -gt 0 ]; do
    n=$((n + 1))
    resp=$(curl --proto =http -fs -m "$(( left < 10 ? left : 10 ))" -G \
      --data-urlencode "status=$1" --data-urlencode "msg=$2" "$url" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ] && [[ "$resp" == *'"ok":true'* ]]; then
      echo "notificacao: recebida pelo Uptime Kuma (tentativa $n)"; return 0
    fi
    [ "$rc" -eq 0 ] && rc=resposta-sem-ok
    echo "notificacao: tentativa $n sem confirmacao (curl=$rc)"
    left=$((deadline - SECONDS)); [ "$left" -gt 0 ] || break
    sleep "$(( left < interval ? left : interval ))"
  done
  echo "aviso: NOTIFICACAO ao Uptime Kuma falhou apos $n tentativa(s) em ${limit}s (resultado do backup inalterado: $1)"
  return 0
}

# --- Pausa e religamento dos servicos
STOPPED=()
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
running_services() { compose ps --status running --services 2>/dev/null; }

stop_services() {
  [ -f "$COMPOSE_FILE" ] || { echo "sem stack de monitoramento; nada a pausar"; return 0; }
  local running s want=()
  running=$(running_services) || { echo "nao foi possivel consultar os servicos"; return 1; }
  for s in $PAUSE_SERVICES; do grep -qx -- "$s" <<< "$running" && want+=("$s"); done
  [ ${#want[@]} -eq 0 ] && { echo "nenhum servico a pausar"; return 0; }
  STOPPED=("${want[@]}")   # registra ANTES: mesmo uma parada parcial sera religada
  compose stop "${want[@]}" >/dev/null 2>&1 || { echo "docker compose stop falhou"; return 1; }
  # Uma consulta que falha NAO confirma a parada.
  if ! running=$(running_services); then echo "consulta ao Docker falhou apos o stop: parada nao confirmada"; return 1; fi
  for s in "${want[@]}"; do grep -qx -- "$s" <<< "$running" && { echo "$s continua rodando"; return 1; }; done
  echo "pausados: ${want[*]}"
}

start_services() {
  [ ${#STOPPED[@]} -eq 0 ] && return 0
  local attempt s running missing
  for attempt in 1 2 3; do
    compose start "${STOPPED[@]}" >/dev/null 2>&1
    missing=()
    if running=$(running_services); then
      for s in "${STOPPED[@]}"; do grep -qx -- "$s" <<< "$running" || missing+=("$s"); done
    else
      echo "consulta ao Docker falhou (tentativa $attempt): religamento nao confirmado"
      missing=("${STOPPED[@]}")
    fi
    if [ ${#missing[@]} -eq 0 ]; then echo "religados: ${STOPPED[*]}"; STOPPED=(); return 0; fi
    sleep "${HL_RETRY_SLEEP:-3}"
  done
  echo "NAO voltaram: ${missing[*]}"; return 1
}
# Garantia final: qualquer saida (erro, sinal) tenta religar o que foi pausado.
trap 'start_services >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT TERM HUP

finish_status() { # $1 ok|fail  $2 mensagem
  echo "$1 $(date -Is) $2" > "$STATUS"; chmod 0644 "$STATUS"
  if [ "$1" = ok ]; then push up "$2"; else push down "backup falhou: $2"; fi
}

# Promocao isolada (o gancho de teste so existe no sandbox: HL_* e descartado em producao).
promote_export() { [ -z "${HL_TEST_FAIL_PROMOTE:-}" ] || return 1; mv -- "$1" "$2"; }

publish_export() {
  local new old efd leftover
  # Lock legivel pelo administrador (a copia "pull" segura um lock compartilhado nele).
  [ -f "$EXPORT_LOCK" ] && [ ! -L "$EXPORT_LOCK" ] || { rm -f -- "$EXPORT_LOCK"; install -m 0644 -o root -g root /dev/null "$EXPORT_LOCK"; }
  exec {efd}<"$EXPORT_LOCK"
  flock -x -w "${HL_EXPORT_LOCK_WAIT:-600}" "$efd" || { echo "export ocupado por uma copia em andamento"; return 1; }
  # Recupera uma troca interrompida (ex.: queda de energia entre os dois "mv").
  if [ ! -d "$EXPORT_DIR" ]; then
    leftover=$(ls -1dt -- "$EXPORT_DIR".old.* 2>/dev/null | head -1)
    [ -n "$leftover" ] && mv -- "$leftover" "$EXPORT_DIR" && echo "geracao anterior recuperada de $leftover"
  fi
  rm -rf -- "$EXPORT_DIR".new.*
  new="$EXPORT_DIR.new.$$"; old="$EXPORT_DIR.old.$$"
  cp -al -- "$RESTIC_REPOSITORY" "$new" || { rm -rf -- "$new"; return 1; }
  find "$new/locks" -mindepth 1 -delete 2>/dev/null || true
  if ! ( cd -- "$new" && find . -type f ! -name MANIFEST.sha256 ! -name GENERATION -print0 | sort -z | xargs -0 -r sha256sum > MANIFEST.sha256 ) \
     || ! echo "$SNAP $(date -Is)" > "$new/GENERATION" \
     || ! { chgrp -R -- "$EXPORT_GROUP" "$new" && find "$new" -type d -exec chmod 2750 {} + && find "$new" -type f -exec chmod 0440 {} +; }; then
    echo "falha ao montar a nova geracao; export anterior mantido"; rm -rf -- "$new"; return 1
  fi
  [ -z "${HL_TEST_CORRUPT_NEW_EXPORT:-}" ] || sed -i '1s/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$new/MANIFEST.sha256"
  # Valida a NOVA geracao antes de promover.
  if [ ! -s "$new/MANIFEST.sha256" ] || ! ( cd -- "$new" && sha256sum -c --quiet --strict MANIFEST.sha256 >/dev/null 2>&1 ); then
    echo "nova geracao reprovada na validacao; export anterior mantido"; rm -rf -- "$new"; return 1
  fi
  # Promove; se falhar, devolve a geracao anterior ao lugar.
  if [ -d "$EXPORT_DIR" ]; then mv -- "$EXPORT_DIR" "$old" || { rm -rf -- "$new"; return 1; }; fi
  if ! promote_export "$new" "$EXPORT_DIR"; then
    echo "falha ao promover a nova geracao; restaurando a anterior"
    if [ -d "$old" ]; then mv -- "$old" "$EXPORT_DIR" || echo "CRITICO: geracao anterior ficou em $old"; fi
    rm -rf -- "$new"; return 1
  fi
  rm -rf -- "$old"
  exec {efd}<&-
  echo "export publicado: $(wc -l < "$EXPORT_DIR/MANIFEST.sha256") arquivos"
}

# ------------------------------------------------------------------ 1
hl_section "1. Metadados"
install -d -m 0750 -- "$META"
{ dpkg --get-selections > "$META/dpkg-selections.txt" \
  && apt-mark showmanual > "$META/apt-manual.txt" \
  && systemctl list-unit-files --state=enabled --no-legend > "$META/enabled-units.txt" \
  && uname -a > "$META/uname.txt"; } && hl_ok "metadados" || hl_fail "metadados (continua)"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' > "$META/containers.txt" 2>/dev/null || true

# ------------------------------------------------------------------ 2
hl_section "2. Pausa dos servicos com SQLite"
if ! stop_services; then
  hl_fail "pausar servicos; backup NAO executado para nao gravar bancos em uso"
  start_services || hl_fail "servicos nao voltaram: verifique imediatamente"
  finish_status fail "nao foi possivel pausar os servicos"; hl_finish
fi

# ------------------------------------------------------------------ 3
hl_section "3. restic backup"
# shellcheck disable=SC2086
if restic backup --quiet --tag homelab --exclude-caches \
     --exclude "$ADMIN_HOME/.cache" --exclude "$ADMIN_HOME/Downloads" $BACKUP_PATHS; then
  hl_ok "snapshot criado"; BACKUP_OK=1
else
  hl_fail "restic backup"; BACKUP_OK=0
fi
start_services && hl_ok "servicos religados" || hl_fail "servicos NAO voltaram depois do backup"
if [ "$BACKUP_OK" -eq 0 ]; then finish_status fail "restic backup"; hl_finish; fi

# ------------------------------------------------------------------ 4
hl_section "4. Retencao e verificacao"
restic forget --quiet --tag homelab --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune && hl_ok "forget/prune" || hl_fail "forget/prune"
if [ "$(date +%u)" = 7 ]; then CHECK_ARGS=(--read-data-subset=10%); else CHECK_ARGS=(); fi
restic check "${CHECK_ARGS[@]}" >/dev/null && hl_ok "restic check ${CHECK_ARGS[*]}" || hl_fail "restic check"
SNAP=$(restic snapshots --tag homelab --latest 1 --json | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4)

# ------------------------------------------------------------------ 5
hl_section "5. Export consistente para a copia externa"
if [ "$HL_FAILS" -eq 0 ]; then
  publish_export && hl_ok "export atualizado" || hl_fail "export NAO atualizado (a copia externa continua na versao anterior)"
else
  echo "export mantido na versao anterior por causa das falhas acima"
fi

SIZE=$(du -sh -- "$RESTIC_REPOSITORY" | cut -f1)
if [ "$HL_FAILS" -eq 0 ]; then finish_status ok "snapshot=$SNAP repo=$SIZE"
else finish_status fail "snapshot=${SNAP:-?} com $HL_FAILS falha(s); ver $HL_LOG"; fi
hl_finish
