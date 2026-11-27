# shellcheck shell=bash
# Funcoes auxiliares da suite (executadas dentro do sandbox).

fail()   { echo "ASSERCAO FALHOU: $*"; exit 1; }
assert() { "$@" || fail "$*"; }
assert_rc() { local want=$1; shift; "$@"; local rc=$?; [ "$rc" -eq "$want" ] || fail "esperado rc=$want, obtido rc=$rc: $*"; }
assert_nonzero() { "$@"; local rc=$?; [ "$rc" -ne 0 ] || fail "esperado rc!=0: $*"; }
assert_grep() { grep -q -- "$1" "$2" || fail "'$1' nao encontrado em $2"; }
assert_no_grep() { ! grep -q -- "$1" "$2" || fail "'$1' encontrado em $2"; }

# Ambiente comum: tudo dentro de $SB.
setup_common() {
  export MOCK_STATE="$SB/mock"; mkdir -p "$MOCK_STATE"; : > "$MOCK_STATE/calls"
  export HL_LIB_DIR="$REPO/scripts/server/lib"
  export HL_RUN_DIR="$SB/run" HL_LOG_DIR="$SB/log" HL_LOG_GROUP=root HL_STATE_DIR="$SB/state"
  export HL_ADMIN_HOME="$SB/home" HL_ETC_DIR="$SB/etc" HL_RETRY_SLEEP=0
  export HL_GUARD_DIR="$SB/guard" HL_SSHD_DROPIN="$SB/sshd/10-homelab.conf" HL_NFT_CONF="$SB/nftables.conf"
  export HL_NFT="$HERE/mocks/nft-wrapper"
  export RESTIC_CACHE_DIR="$SB/cache" XDG_CACHE_HOME="$SB/cache" TMPDIR="$SB/tmp"
  mkdir -p "$SB"/{run,log,state,home/.ssh,etc,sshd,tmp,cache}
  echo "ssh-ed25519 AAAATESTE teste" > "$SB/home/.ssh/authorized_keys"
  /usr/sbin/nft delete table inet homelab_fw 2>/dev/null || true   # cada teste comeca limpo
}

mkdb() { python3 - "$1" "$2" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1]); con.execute("create table t(x)"); con.execute("insert into t values (?)", (sys.argv[2],)); con.commit(); con.close()
PY
}

# Repositorio restic + stack falsa com bancos SQLite reais.
setup_backup() {
  export HL_BACKUP_CONF="$SB/etc/backup.conf"
  mkdir -p "$SB/stacks/monitoring/data/beszel" "$SB/stacks/monitoring/data/uptime-kuma" "$SB/repo"
  echo "services: {}" > "$SB/stacks/monitoring/compose.yaml"
  mkdb "$SB/stacks/monitoring/data/beszel/data.db" beszel
  mkdb "$SB/stacks/monitoring/data/uptime-kuma/kuma.db" kuma
  echo "estavel=1" > "$SB/etc/stable.conf"
  ( umask 077; echo "senha-de-teste-123" > "$SB/etc/restic.pass" )
  printf '%s\n' "ADMIN_USER=root" "RESTIC_REPOSITORY=$SB/repo" "RESTIC_PASSWORD_FILE=$SB/etc/restic.pass" \
    "STACKS_DIR=$SB/stacks" "EXPORT_DIR=$SB/state/export" "EXPORT_GROUP=root" \
    "BACKUP_PATHS=$SB/etc $SB/stacks" "RESTORE_STABLE=$SB/etc/stable.conf" > "$HL_BACKUP_CONF"
  chmod 0644 "$HL_BACKUP_CONF"
  restic init -r "$SB/repo" --password-file "$SB/etc/restic.pass" >/dev/null || fail "restic init"
  printf 'beszel\nbeszel-agent\nuptime-kuma\n' > "$MOCK_STATE/running"
}
backup()  { bash "$REPO/scripts/server/homelab-backup.sh"; }
restore() { bash "$REPO/scripts/server/homelab-restore-test.sh"; }
snapshots() { restic -r "$SB/repo" --password-file "$SB/etc/restic.pass" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l; }

# Firewall/guard: estado "antigo" carregado (faixas RFC1918) e drop-in antigo.
setup_guard_old_state() {
  echo "# drop-in ANTIGO" > "$HL_SSHD_DROPIN"
  . "$HL_LIB_DIR/firewall.sh"
  fw_render "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" "fe80::/10" "" "" > "$HL_NFT_CONF"
  /usr/sbin/nft -f "$HL_NFT_CONF" || fail "carregar estado antigo"
  touch "$MOCK_STATE/nft_enabled"
  printf '%s\n' "ALLOWED_V4=192.0.2.0/24" "ALLOWED_V6=fe80::/10" "DOCKER_LAN_TCP=8090,3001" > "$HL_ETC_DIR/firewall.conf"
  chmod 0644 "$HL_ETC_DIR/firewall.conf"
}
apply()    { bash "$REPO/scripts/server/homelab-apply.sh" root --only-ssh-firewall "$@"; }
rollback() { bash "$REPO/scripts/server/homelab-guard-rollback.sh"; }
runtime()  { /usr/sbin/nft list table inet homelab_fw 2>/dev/null; }
