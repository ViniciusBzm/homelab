# shellcheck shell=bash
# HomeLab - restauracao e validacao de snapshots restic (usado pelos testes de
# restauracao local e externa). Nada de "passou porque o diretorio existe":
# cada banco SQLite esperado precisa existir, ter cabecalho valido e passar no
# PRAGMA integrity_check, e a quantidade de arquivos restaurados precisa bater
# com a do snapshot.

# shellcheck source=common.sh
. "${HL_LIB_DIR:?}/common.sh"

# Arquivos de configuracao estaveis comparados com os atuais (relativos a /).
RS_STABLE_DEFAULT="/etc/ssh/sshd_config.d /etc/nftables.conf /etc/homelab/backup.conf /etc/systemd/timesyncd.conf.d"

# Uso: rs_restore REPO DESTINO CAMINHO...   (restic com --verify)
rs_restore() {
  local repo=$1 dest=$2; shift 2
  local inc=() p
  for p in "$@"; do inc+=(--include "$p"); done
  restic -r "$repo" restore latest --tag homelab --verify --target "$dest" "${inc[@]}" >/dev/null
}

# Compara caminhos restaurados com os atuais. Imprime e devolve o numero de diferencas.
rs_compare_live() {
  local dest=$1; shift
  local p bad=0 ok=0
  for p in "$@"; do
    [ -e "$p" ] || continue
    if diff -r -- "$p" "$dest$p" >/dev/null 2>&1; then ok=$((ok + 1)); echo "  igual: $p"
    else bad=$((bad + 1)); echo "  DIFERENTE: $p"; fi
  done
  RS_COMPARED=$ok
  return $bad
}

# Valida os dados dos servicos restaurados.
# Uso: rs_validate_service_data REPO DESTINO DIR_DADOS "db1 db2 ..."
#   DIR_DADOS: caminho absoluto no snapshot (ex.: /opt/homelab/stacks/monitoring/data)
#   dbs: caminhos relativos a DIR_DADOS (ex.: beszel/data.db uptime-kuma/kuma.db)
rs_validate_service_data() {
  local repo=$1 dest=$2 data=$3 dbs=$4 rc=0 db expected got
  expected=$(restic -r "$repo" ls latest --tag homelab --recursive --json "$data" 2>/dev/null | grep -c '"type":"file"' || true)
  got=$(find "$dest$data" -type f 2>/dev/null | wc -l)
  if [ "$expected" -gt 0 ] && [ "$got" -eq "$expected" ]; then
    echo "  dados dos servicos: $got/$expected arquivos restaurados"
  else
    echo "  FALHA: dados dos servicos com $got de $expected arquivos esperados"; rc=1
  fi
  for db in $dbs; do
    if hl_sqlite_ok "$dest$data/$db"; then echo "  banco OK (integrity_check): $db"
    else echo "  FALHA: banco ausente, vazio ou corrompido: $db"; rc=1; fi
  done
  return $rc
}
