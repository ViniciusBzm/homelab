# shellcheck shell=bash
# HomeLab - funcoes comuns dos scripts executados como root.
# Todos os caminhos aceitam sobrescrita por variavel de ambiente (HL_*) para que
# os testes rodem num sandbox isolado sem tocar no sistema real.

HL_FAILS=${HL_FAILS:-0}

hl_section() { echo; echo "===== $* ====="; }
hl_ok()      { echo "[OK]    $*"; }
hl_fail()    { echo "[FALHA] $*"; HL_FAILS=$((HL_FAILS + 1)); }
hl_die()     { echo "[ERRO]  $*" >&2; exit "${2:-1}"; }

# Codigo de saida = 0 somente se nenhuma etapa falhou.
hl_finish() {
  echo "Fim: $(date -Is)  falhas=$HL_FAILS"
  [ "$HL_FAILS" -eq 0 ] && exit 0
  exit 1
}

hl_require_root() { [ "$(id -u)" -eq 0 ] || hl_die "Execute com sudo." 1; }

# Arquivo lido/executado por root: precisa ser arquivo regular (nao link),
# pertencer ao root e nao ser gravavel por grupo/outros.
hl_require_secure_file() {
  local f=$1 owner mode
  [ -L "$f" ] && hl_die "inseguro (link simbolico): $f" 3
  [ -f "$f" ] || hl_die "ausente: $f" 3
  owner=$(stat -c %u -- "$f"); mode=$(stat -c %a -- "$f")
  [ "$owner" = 0 ] || hl_die "inseguro (dono uid $owner, esperado root): $f" 3
  [ $(( 8#$mode & 8#022 )) -eq 0 ] || hl_die "inseguro (gravavel por grupo/outros, modo $mode): $f" 3
}

# Le KEY=VALOR sem executar o arquivo (nada de "source").
# Uso: hl_read_conf ARQUIVO CHAVE1 CHAVE2 ...  (so as chaves listadas sao aceitas)
hl_read_conf() {
  local f=$1; shift
  local allowed=" $* " line key val n=0
  hl_require_secure_file "$f"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9_./:,@%+\ -]*)$ ]] \
      || hl_die "$f:$n: linha invalida (use CHAVE=valor sem aspas nem caracteres especiais)" 3
    key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    [[ "$allowed" == *" $key "* ]] || hl_die "$f:$n: chave nao permitida: $key" 3
    printf -v "$key" '%s' "$val"
  done < "$f"
}

# Log em diretorio do root (0750, grupo do administrador): nenhum usuario comum
# consegue plantar um link simbolico ali. Sem corrida de permissao: o arquivo e
# criado antes do redirecionamento.
hl_log_init() {
  local name=$1 dir=${HL_LOG_DIR:-/var/log/homelab} group=${HL_LOG_GROUP:-root}
  install -d -m 0750 -o root -g "$group" -- "$dir"
  HL_LOG="$dir/$name.log"
  rm -f -- "$HL_LOG"
  install -m 0640 -o root -g "$group" /dev/null "$HL_LOG"
  exec > >(tee -a -- "$HL_LOG") 2>&1
  echo "Inicio: $(date -Is)  script=$name"
}

# Lock exclusivo nao bloqueante (ou com espera). Mantem o descritor aberto ate o fim.
# Uso: hl_lock ARQUIVO [segundos-de-espera]
hl_lock() {
  local file=$1 wait=${2:-0}
  install -d -m 0755 -- "$(dirname -- "$file")"
  exec {HL_LOCK_FD}>>"$file" || hl_die "nao foi possivel abrir o lock $file" 4
  if [ "$wait" -gt 0 ]; then
    flock -w "$wait" "$HL_LOCK_FD" || hl_die "outra execucao ainda segura $file apos ${wait}s" 4
  else
    flock -n "$HL_LOCK_FD" || hl_die "outra execucao em andamento ($file)" 4
  fi
}

hl_valid_port_list() { [[ -z "$1" || "$1" =~ ^[0-9]{1,5}(,[0-9]{1,5})*$ ]] || return 1
  local p; IFS=, read -ra _ps <<< "$1"; for p in "${_ps[@]}"; do [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1; done; }
hl_valid_cidr4_list() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(,([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2})*$ ]]; }
hl_valid_cidr6_list() { [[ -z "$1" || "$1" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}(,[0-9a-fA-F:]+/[0-9]{1,3})*$ ]]; }

# Verifica que um arquivo comeca com o cabecalho SQLite e passa no integrity_check
# (python3 ja vem no Debian; nao instala nada).
hl_sqlite_ok() {
  local db=$1
  [ -s "$db" ] || return 1
  [ "$(head -c 15 -- "$db")" = "SQLite format 3" ] || return 1
  python3 - "$db" <<'PY' >/dev/null 2>&1
import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
r = con.execute("PRAGMA integrity_check").fetchone()[0]
sys.exit(0 if r == "ok" else 1)
PY
}
