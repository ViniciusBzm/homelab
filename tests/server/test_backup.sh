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

# --- Retry do push (notificacao) ao Uptime Kuma.
setup_push() {
  setup_backup
  export HL_PUSH_URL_FILE="$SB/home/push-url" HL_PUSH_INTERVAL=1
  echo "http://127.0.0.1:3001/api/push/TokenSecreto123" > "$HL_PUSH_URL_FILE"
}
push_calls() { grep -c '^curl ' "$MOCK_STATE/curl" 2>/dev/null || echo 0; }
L() { echo "$HL_LOG_DIR/homelab-backup.log"; }

t_backup_push_sucesso_imediato() {
  setup_push
  assert_rc 0 backup
  [ "$(push_calls)" -eq 1 ] || fail "esperada 1 chamada, obtidas $(push_calls)"
  assert_grep 'recebida pelo Uptime Kuma (tentativa 1)' "$(L)"
  assert_no_grep 'TokenSecreto123' "$(L)"
}

t_backup_push_kuma_indisponivel_temporariamente() {
  setup_push
  MOCK_CURL_FAIL_N=2 assert_rc 0 backup
  [ "$(push_calls)" -eq 3 ] || fail "esperadas 3 chamadas (para na confirmacao), obtidas $(push_calls)"
  assert_grep 'recebida pelo Uptime Kuma (tentativa 3)' "$(L)"
  assert_grep 'tentativa 1 sem confirmacao (curl=7)' "$(L)"
  assert_grep '^ok ' "$HL_STATE_DIR/homelab-backup.status"
  [ "$(snapshots)" -eq 1 ] || fail "o backup nao pode ser repetido"
  assert_no_grep 'TokenSecreto123' "$(L)"
}

t_backup_push_esgota_tentativas_sem_afetar_backup() {
  setup_push
  local t0=$SECONDS
  HL_PUSH_LIMIT=3 MOCK_CURL_FAIL_N=1000 assert_rc 0 backup
  local n; n=$(push_calls)
  [ "$n" -ge 2 ] && [ "$n" -le 4 ] || fail "tentativas fora do limite: $n"
  assert_grep 'NOTIFICACAO ao Uptime Kuma falhou apos' "$(L)"
  assert_grep '^ok ' "$HL_STATE_DIR/homelab-backup.status"
  [ "$(snapshots)" -eq 1 ] || fail "o backup nao pode ser repetido"
  [ $((SECONDS - t0)) -lt 30 ] || fail "retry excedeu o tempo esperado"
  assert_no_grep 'TokenSecreto123' "$(L)"
}

t_backup_push_resposta_sem_ok_nao_confirma() {
  setup_push
  HL_PUSH_LIMIT=2 MOCK_CURL_BODY='{"ok":false,"msg":"Monitor not found"}' assert_rc 0 backup
  assert_grep 'sem confirmacao (curl=resposta-sem-ok)' "$(L)"
  assert_grep 'NOTIFICACAO ao Uptime Kuma falhou' "$(L)"
}

t_backup_falha_com_notificacao_falha_e_distinta() {
  setup_push
  HL_PUSH_LIMIT=2 MOCK_CURL_FAIL_N=1000 MOCK_STOP_FAIL=1 assert_nonzero backup
  assert_grep '^fail ' "$HL_STATE_DIR/homelab-backup.status"
  assert_grep 'status=down' "$MOCK_STATE/curl"
  assert_grep 'resultado do backup inalterado: down' "$(L)"
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

# --- Regressao (revisao final do PR #2) ---------------------------------------

t_backup_consulta_falha_apos_parar_nao_confirma() {
  setup_backup
  MOCK_PS_FAIL_AFTER_STOP=1 assert_nonzero backup
  [ "$(snapshots)" -eq 0 ] || fail "consulta falha nao pode confirmar a parada"
  assert_grep 'parada nao confirmada' "$HL_LOG_DIR/homelab-backup.log"
  assert_grep 'compose -f .* start beszel uptime-kuma' "$MOCK_STATE/calls"
  grep -qx beszel "$MOCK_STATE/running" || fail "servicos nao religados"
}

t_backup_consulta_falha_apos_religar_reprova() {
  setup_backup
  MOCK_PS_FAIL_AFTER_START=1 assert_nonzero backup
  assert_grep '^fail ' "$HL_STATE_DIR/homelab-backup.status"
  assert_grep 'religamento nao confirmado' "$HL_LOG_DIR/homelab-backup.log"
}

t_export_nova_geracao_invalida_nao_e_promovida() {
  setup_backup
  assert_rc 0 backup; gen1=$(cat "$SB/state/export/GENERATION"); sleep 1
  HL_TEST_CORRUPT_NEW_EXPORT=1 assert_nonzero backup
  [ "$(cat "$SB/state/export/GENERATION")" = "$gen1" ] || fail "geracao invalida foi promovida"
  ( cd "$SB/state/export" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "geracao anterior danificada"
  ! ls -d "$SB/state/export".new.* >/dev/null 2>&1 || fail "sobrou diretorio .new"
}

t_export_falha_ao_promover_restaura_anterior() {
  setup_backup
  assert_rc 0 backup; gen1=$(cat "$SB/state/export/GENERATION"); sleep 1
  HL_TEST_FAIL_PROMOTE=1 assert_nonzero backup
  [ -d "$SB/state/export" ] || fail "export sumiu apos falha na promocao"
  [ "$(cat "$SB/state/export/GENERATION")" = "$gen1" ] || fail "geracao anterior nao restaurada"
  ( cd "$SB/state/export" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "geracao anterior danificada"
  ! ls -d "$SB/state/export".old.* "$SB/state/export".new.* >/dev/null 2>&1 || fail "sobraram diretorios temporarios"
}

t_export_recupera_troca_interrompida() {
  setup_backup
  assert_rc 0 backup
  mv "$SB/state/export" "$SB/state/export.old.4242"          # queda entre os dois "mv"
  assert_rc 0 backup
  assert_grep 'geracao anterior recuperada' "$HL_LOG_DIR/homelab-backup.log"
  ( cd "$SB/state/export" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "export invalido apos recuperacao"
}
