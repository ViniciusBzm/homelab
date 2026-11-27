# shellcheck shell=bash
# Restauracao local e externa: sucesso real e ausencia de falso positivo.

ext() { HL_STACKS_DIR="$SB/stacks" HL_TEST_PASSWORD_FILE="$1" bash "$REPO/scripts/server/homelab-external-restore-test.sh" "$2" --no-compare-live; }
copy_export() { mkdir -p "$SB/copia"; cp -a "$SB/state/export/." "$SB/copia/"; chmod -R u+w "$SB/copia"; }

t_restore_local_sucesso() {
  setup_backup; assert_rc 0 backup
  assert_rc 0 restore
  assert_grep '^ok ' "$HL_STATE_DIR/homelab-restore-test.status"
  assert_grep 'banco OK (integrity_check): uptime-kuma/kuma.db' "$HL_LOG_DIR/homelab-restore-test.log"
}

t_restore_local_detecta_banco_ausente() {
  setup_backup; rm "$SB/stacks/monitoring/data/uptime-kuma/kuma.db"; assert_rc 0 backup
  assert_nonzero restore
  assert_grep '^fail ' "$HL_STATE_DIR/homelab-restore-test.status"
}

t_restore_local_detecta_banco_corrompido() {
  setup_backup
  db="$SB/stacks/monitoring/data/beszel/data.db"
  { printf 'SQLite format 3\000'; head -c 8192 /dev/urandom; } > "$db"   # cabecalho valido, conteudo lixo
  assert_rc 0 backup
  assert_nonzero restore
}

t_restore_local_detecta_dados_vazios() {
  setup_backup; rm -rf "$SB/stacks/monitoring/data"/*; assert_rc 0 backup
  assert_nonzero restore     # antes: "dados restaurados: 0K" contava como sucesso
}

t_restore_aguarda_lock_do_backup() {
  setup_backup; assert_rc 0 backup
  ( flock -x 9; sleep 6 ) 9>>"$HL_RUN_DIR/homelab-backup.lock" &
  sleep 0.3
  HL_LOCK_WAIT=1 assert_rc 4 restore
  wait
}

t_externo_sucesso() {
  setup_backup; assert_rc 0 backup; copy_export
  assert_rc 0 ext "$SB/etc/restic.pass" "$SB/copia"
}

t_externo_senha_errada() {
  setup_backup; assert_rc 0 backup; copy_export
  echo "senha-errada-000000" > "$SB/errada"
  assert_nonzero ext "$SB/errada" "$SB/copia"
}

t_externo_copia_adulterada() {
  setup_backup; assert_rc 0 backup; copy_export
  f=$(find "$SB/copia/data" -type f | head -1); echo x >> "$f"
  assert_nonzero ext "$SB/etc/restic.pass" "$SB/copia"
}

t_externo_arquivo_faltando() {
  setup_backup; assert_rc 0 backup; copy_export
  rm "$(find "$SB/copia/index" -type f | head -1)"
  assert_nonzero ext "$SB/etc/restic.pass" "$SB/copia"
}

t_externo_arquivo_extra() {
  setup_backup; assert_rc 0 backup; copy_export
  echo intruso > "$SB/copia/data/intruso"
  assert_nonzero ext "$SB/etc/restic.pass" "$SB/copia"
}

t_externo_sem_manifesto() {
  setup_backup; assert_rc 0 backup
  mkdir -p "$SB/copia"; cp -a "$SB/repo/." "$SB/copia/"   # repositorio "cru", sem export
  assert_nonzero ext "$SB/etc/restic.pass" "$SB/copia"
}

t_externo_detecta_banco_ausente() {
  setup_backup; rm "$SB/stacks/monitoring/data/beszel/data.db"; assert_rc 0 backup; copy_export
  assert_nonzero ext "$SB/etc/restic.pass" "$SB/copia"
}
