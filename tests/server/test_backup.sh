# shellcheck shell=bash
# Backup: consistencia, pausa/religamento dos servicos, lock, seguranca da configuracao.

t_backup_sucesso_publica_export_consistente() {
  setup_backup
  assert_rc 0 backup
  assert_grep '^ok ' "$HL_STATE_DIR/homelab-backup.status"
  [ "$(snapshots)" -eq 1 ] || fail "esperado 1 snapshot"
  ( cd "$SB/state/export" && sha256sum -c --quiet --strict MANIFEST.sha256 ) || fail "manifesto do export invalido"
  [ -f "$SB/state/export/GENERATION" ] || fail "GENERATION ausente"
  [ -z "$(ls -A "$SB/state/export/locks" 2>/dev/null)" ] || fail "export contem locks do restic"
  assert_grep 'compose -f .* stop beszel uptime-kuma' "$MOCK_STATE/calls"
  assert_grep 'compose -f .* start beszel uptime-kuma' "$MOCK_STATE/calls"
  grep -qx uptime-kuma "$MOCK_STATE/running" && grep -qx beszel "$MOCK_STATE/running" || fail "servicos nao religados"
}

t_backup_falha_ao_parar_aborta_e_religa() {
  setup_backup
  MOCK_STOP_FAIL=1 assert_nonzero backup
  assert_grep '^fail ' "$HL_STATE_DIR/homelab-backup.status"
  [ "$(snapshots)" -eq 0 ] || fail "nao deveria criar snapshot com servicos em estado incerto"
  grep -qx beszel "$MOCK_STATE/running" || fail "servico parado parcialmente nao foi religado"
  [ ! -d "$SB/state/export" ] || fail "export nao deveria ser publicado"
}

t_backup_falha_ao_religar_retorna_erro() {
  setup_backup
  MOCK_START_FAIL=1 assert_nonzero backup
  assert_grep '^fail ' "$HL_STATE_DIR/homelab-backup.status"
  [ "$(snapshots)" -eq 1 ] || fail "o snapshot em si deveria existir"
  assert_grep 'servicos NAO voltaram' "$HL_LOG_DIR/homelab-backup.log"
  [ ! -d "$SB/state/export" ] || fail "export nao deveria ser publicado com falha"
}

t_backup_execucao_concorrente_recusada() {
  setup_backup
  mkdir -p "$HL_RUN_DIR"; ( flock -x 9; sleep 6 ) 9>>"$HL_RUN_DIR/homelab-backup.lock" &
  sleep 0.5
  assert_rc 4 backup
  [ "$(snapshots)" -eq 0 ] || fail "segunda execucao nao deveria criar snapshot"
  wait
}

t_backup_config_insegura_recusada() {
  setup_backup
  chmod 0666 "$HL_BACKUP_CONF"; assert_rc 3 backup
  chmod 0644 "$HL_BACKUP_CONF"; mv "$HL_BACKUP_CONF" "$SB/etc/real.conf"; ln -s "$SB/etc/real.conf" "$HL_BACKUP_CONF"
  assert_rc 3 backup
  rm "$HL_BACKUP_CONF"; mv "$SB/etc/real.conf" "$HL_BACKUP_CONF"
  echo 'RESTIC_REPOSITORY=$(touch /tmp/pwned)' >> "$HL_BACKUP_CONF"; assert_rc 3 backup
  [ ! -e /tmp/pwned ] || fail "configuracao foi executada"
}

t_backup_senha_legivel_por_outros_recusada() {
  setup_backup
  chmod 0644 "$SB/etc/restic.pass"; assert_rc 3 backup
}

t_backup_push_url_nao_confiavel() {
  setup_backup
  export HL_PUSH_URL_FILE="$SB/home/push-url"
  echo "file:///etc/shadow" > "$HL_PUSH_URL_FILE"
  assert_rc 0 backup; [ ! -s "$MOCK_STATE/curl" ] || fail "curl chamado com URL invalida"
  rm "$HL_PUSH_URL_FILE"; ln -s /etc/hostname "$HL_PUSH_URL_FILE"
  assert_rc 0 backup; [ ! -s "$MOCK_STATE/curl" ] || fail "curl chamado via link simbolico"
  rm "$HL_PUSH_URL_FILE"; echo "http://127.0.0.1:3001/api/push/abcdef123456" > "$HL_PUSH_URL_FILE"
  assert_rc 0 backup; assert_grep 'status=up' "$MOCK_STATE/curl"; assert_grep '--proto =http' "$MOCK_STATE/curl"
}

t_backup_export_espera_copia_em_andamento() {
  setup_backup
  assert_rc 0 backup; gen1=$(cat "$SB/state/export/GENERATION")
  sleep 1
  # Uma copia "pull" segura o lock compartilhado por 3 s: o backup espera e depois troca o export.
  ( flock -s 9; sleep 3 ) 9<"$SB/state/export.lock" &
  sleep 0.3
  HL_EXPORT_LOCK_WAIT=20 assert_rc 0 backup
  wait
  gen2=$(cat "$SB/state/export/GENERATION"); [ "$gen1" != "$gen2" ] || fail "export nao foi trocado"
  ( cd "$SB/state/export" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "export inconsistente"
}

t_backup_export_ocupado_preserva_versao_anterior() {
  setup_backup
  assert_rc 0 backup; gen1=$(cat "$SB/state/export/GENERATION")
  ( flock -s 9; sleep 6 ) 9<"$SB/state/export.lock" &
  sleep 0.3
  HL_EXPORT_LOCK_WAIT=1 assert_nonzero backup
  wait
  [ "$(cat "$SB/state/export/GENERATION")" = "$gen1" ] || fail "export anterior deveria permanecer"
  ( cd "$SB/state/export" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "export anterior corrompido"
}

t_backup_copia_sob_lock_e_valida() {
  setup_backup
  assert_rc 0 backup
  mkdir "$SB/copia"
  flock -s "$SB/state/export.lock" tar -C "$SB/state/export" -cf - . | tar -xf - -C "$SB/copia"
  ( cd "$SB/copia" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "copia sob lock invalida"
  f=$(find "$SB/copia/data" -type f | head -1); chmod u+w "$f"; echo x >> "$f"
  ! ( cd "$SB/copia" && sha256sum -c --quiet MANIFEST.sha256 2>/dev/null ) || fail "adulteracao nao detectada"
}

t_log_nao_segue_link_simbolico() {
  setup_backup
  mkdir -p "$HL_LOG_DIR"; echo "original" > "$SB/vitima"; ln -s "$SB/vitima" "$HL_LOG_DIR/homelab-backup.log"
  assert_rc 0 backup
  [ "$(cat "$SB/vitima")" = original ] || fail "log escreveu atraves do link"
  [ ! -L "$HL_LOG_DIR/homelab-backup.log" ] || fail "link nao foi substituido"
}
