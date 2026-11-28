# shellcheck shell=bash
# Guard, rollback e firewall (nft real num namespace de rede isolado).

t_fw_render_restrito_a_subrede_com_ipv6() {
  . "$HL_LIB_DIR/firewall.sh"
  fw_render "192.0.2.0/24" "fe80::/10" "8090,3001" "" > "$SB/fw.nft" || fail "render"
  /usr/sbin/nft -c -f "$SB/fw.nft" || fail "nft -c reprovou"
  assert_grep '192.0.2.0/24' "$SB/fw.nft"
  assert_no_grep '10.0.0.0/8' "$SB/fw.nft"
  assert_grep 'ip6 saddr @allowed6 tcp dport 22 accept' "$SB/fw.nft"
  assert_grep 'ip6 saddr @allowed6 tcp dport @docker_lan_tcp accept' "$SB/fw.nft"
  assert_grep 'ip6 saddr @allowed6 meta l4proto tcp ct original proto-dst @docker_lan_tcp accept' "$SB/fw.nft"
  /usr/sbin/nft -f "$SB/fw.nft" && runtime | grep -q '8090' || fail "nao carregou"
}

t_fw_render_listas_vazias_validas() {
  . "$HL_LIB_DIR/firewall.sh"
  fw_render "192.0.2.0/24" "" "" "" > "$SB/fw.nft" || fail "render"
  /usr/sbin/nft -c -f "$SB/fw.nft" || fail "nft -c reprovou listas vazias"
}

t_fw_render_rejeita_entrada_invalida() {
  . "$HL_LIB_DIR/firewall.sh"
  ! fw_render "192.0.2.0/33x" "" "" "" >/dev/null 2>&1 || fail "CIDR invalido aceito"
  ! fw_render "192.0.2.0/24" "" "70000" "" >/dev/null 2>&1 || fail "porta 70000 aceita"
  ! fw_render "192.0.2.0/24" "" "22; flush ruleset" "" >/dev/null 2>&1 || fail "injecao aceita"
  ! fw_render "" "" "" "" >/dev/null 2>&1 || fail "ALLOWED_V4 vazio aceito"
}

t_fw_conf_rejeita_chave_ou_valor_inseguro() {
  . "$HL_LIB_DIR/firewall.sh"
  printf 'ALLOWED_V4="1.2.3.0/24"\n' > "$HL_ETC_DIR/firewall.conf"; chmod 0644 "$HL_ETC_DIR/firewall.conf"
  ! ( fw_render_from_conf "$HL_ETC_DIR" ) >/dev/null 2>&1 || fail "aspas aceitas"
  printf 'PATH=/tmp\n' > "$HL_ETC_DIR/firewall.conf"
  ! ( fw_render_from_conf "$HL_ETC_DIR" ) >/dev/null 2>&1 || fail "chave desconhecida aceita"
}

t_fw_compatibilidade_arquivo_antigo() {
  . "$HL_LIB_DIR/firewall.sh"
  echo "8090,3001" > "$HL_ETC_DIR/docker-lan-tcp"; chmod 0644 "$HL_ETC_DIR/docker-lan-tcp"
  fw_render_from_conf "$HL_ETC_DIR" > "$SB/fw.nft" 2> "$SB/err" || fail "render legado"
  assert_grep 'RFC 1918' "$SB/err"; assert_grep '8090, 3001' "$SB/fw.nft"
}

t_apply_sucesso_arma_guard() {
  setup_guard_old_state
  assert_rc 0 apply
  runtime | grep -q '192.0.2.0/24' || fail "regras novas nao carregadas"
  runtime | grep -q '10.0.0.0/8' && fail "faixa antiga continua liberada"
  assert_grep 'Protegido pelo homelab-guard' "$HL_SSHD_DROPIN"
  [ -f "$HL_GUARD_DIR/armed" ] || fail "guard nao armado"
  assert_grep 'systemd-run .*--on-active=10min' "$MOCK_STATE/calls"
}

t_apply_recusa_com_guard_pendente() {
  setup_guard_old_state
  assert_rc 0 apply
  assert_rc 5 apply
}

t_apply_execucao_concorrente_recusada() {
  setup_guard_old_state
  ( flock -x 9; sleep 6 ) 9>>"$HL_RUN_DIR/homelab-apply.lock" &
  sleep 0.3
  assert_rc 4 apply
  [ ! -f "$HL_GUARD_DIR/armed" ] || fail "nao deveria armar"
  wait
}

t_apply_sshd_invalido_reverte_na_hora() {
  setup_guard_old_state; before=$(runtime)
  MOCK_SSHD_REJECT_NEW=1 assert_nonzero apply
  assert_grep 'drop-in ANTIGO' "$HL_SSHD_DROPIN"
  [ "$(runtime)" = "$before" ] || fail "firewall em memoria nao e o anterior"
  [ ! -f "$HL_GUARD_DIR/armed" ] || fail "guard deveria ser desarmado"
}

t_apply_falha_ao_carregar_firewall_reverte_tudo() {
  setup_guard_old_state; before=$(runtime)
  MOCK_NFT_LOAD_FAIL=1 assert_nonzero apply
  assert_grep 'drop-in ANTIGO' "$HL_SSHD_DROPIN"
  runtime | grep -q '10.0.0.0/8' || fail "regras antigas nao restauradas"
  [ "$(runtime)" = "$before" ] || fail "estado em memoria difere do anterior"
  [ ! -f "$HL_GUARD_DIR/armed" ] || fail "guard deveria ser desarmado"
}

t_apply_guard_nao_arma_nada_muda() {
  setup_guard_old_state; before=$(runtime)
  MOCK_SYSTEMD_RUN_FAIL=1 assert_nonzero apply
  assert_grep 'drop-in ANTIGO' "$HL_SSHD_DROPIN"
  [ "$(runtime)" = "$before" ] || fail "nada deveria mudar sem guard"
}

t_apply_config_invalida_nada_muda() {
  setup_guard_old_state; before=$(runtime)
  printf 'ALLOWED_V4=999.1.1.0/24,abc\n' > "$HL_ETC_DIR/firewall.conf"
  assert_nonzero apply
  [ "$(runtime)" = "$before" ] && grep -q 'drop-in ANTIGO' "$HL_SSHD_DROPIN" || fail "estado alterado com configuracao invalida"
  [ ! -f "$HL_GUARD_DIR/armed" ] || fail "guard armado sem necessidade"
}

t_guard_sem_confirmacao_restaura() {
  setup_guard_old_state; before=$(runtime)
  assert_rc 0 apply
  assert_rc 0 rollback
  [ "$(runtime)" = "$before" ] || fail "rollback nao restaurou o firewall em memoria"
  assert_grep 'drop-in ANTIGO' "$HL_SSHD_DROPIN"
  [ -f "$MOCK_STATE/nft_enabled" ] || fail "servico nftables deveria continuar habilitado"
  [ ! -f "$HL_GUARD_DIR/armed" ] || fail "armed deveria ser removido"
}

t_guard_com_confirmacao_mantem() {
  setup_guard_old_state
  assert_rc 0 apply; after=$(runtime)
  sleep 1; touch "$HL_ADMIN_HOME/.homelab-guard-confirm"
  assert_rc 0 rollback
  [ "$(runtime)" = "$after" ] || fail "mudancas confirmadas foram revertidas"
  assert_grep 'Protegido pelo homelab-guard' "$HL_SSHD_DROPIN"
}

t_guard_confirmacao_por_link_simbolico_ignorada() {
  setup_guard_old_state; before=$(runtime)
  assert_rc 0 apply
  sleep 1; touch "$SB/alvo"; ln -s "$SB/alvo" "$HL_ADMIN_HOME/.homelab-guard-confirm"
  assert_rc 0 rollback
  [ "$(runtime)" = "$before" ] || fail "confirmacao via link deveria ser ignorada"
}

t_guard_reexecucao_restaura_ultimo_estado_bom() {
  setup_guard_old_state
  assert_rc 0 apply; sleep 1; touch "$HL_ADMIN_HOME/.homelab-guard-confirm"; assert_rc 0 rollback
  good=$(runtime)                                   # estado confirmado (v2)
  printf '%s\n' "ALLOWED_V4=192.0.2.0/24" "DOCKER_LAN_TCP=8090,3001,9999" > "$HL_ETC_DIR/firewall.conf"
  assert_rc 0 apply                                 # nova mudanca (v3), sem confirmacao
  runtime | grep -q 9999 || fail "v3 nao aplicada"
  assert_rc 0 rollback
  [ "$(runtime)" = "$good" ] || fail "deveria voltar ao ultimo estado confirmado, nao ao padrao"
}

t_guard_restaura_regras_em_memoria_com_servico_desabilitado() {
  setup_guard_old_state; rm -f "$MOCK_STATE/nft_enabled"; before=$(runtime)
  assert_rc 0 apply
  assert_rc 0 rollback
  [ "$(runtime)" = "$before" ] || fail "tabela carregada (sem servico) nao restaurada"
  [ ! -f "$MOCK_STATE/nft_enabled" ] || fail "servico deveria continuar desabilitado"
}

# --- Regressao (revisao final do PR #2) ---------------------------------------

t_guard_snapshot_falha_nada_muda() {
  setup_guard_old_state; before=$(runtime)
  MOCK_NFT_LIST_FAIL=1 assert_nonzero apply
  [ "$(runtime)" = "$before" ] && grep -q 'drop-in ANTIGO' "$HL_SSHD_DROPIN" || fail "estado alterado sem snapshot valido"
  [ ! -f "$HL_GUARD_DIR/armed" ] || fail "guard armado sem snapshot"
}

t_guard_restauracao_em_transacao_unica() {
  setup_guard_old_state; before=$(runtime)
  assert_rc 0 apply; : > "$MOCK_STATE/nft-calls"
  assert_rc 0 rollback
  [ "$(runtime)" = "$before" ] || fail "estado nao restaurado"
  ! grep -q '^nft delete table' "$MOCK_STATE/nft-calls" || fail "delete separado: janela sem firewall"
  [ "$(grep -c '^nft -f' "$MOCK_STATE/nft-calls")" -eq 1 ] || fail "restauracao deveria ser um unico nft -f"
  head -2 "$HL_GUARD_DIR/restore.nft" | grep -q 'delete table inet homelab_fw' || fail "transacao sem delete+recriacao"
}

t_guard_rollback_incompleto_mantem_armado() {
  setup_guard_old_state
  assert_rc 0 apply
  MOCK_NFT_RESTORE_FAIL=1 assert_nonzero rollback
  [ -f "$HL_GUARD_DIR/armed" ] || fail "guard desarmado apos rollback incompleto"
  [ -f "$HL_GUARD_DIR/rollback-failed" ] || fail "falha nao registrada"
  assert_rc 5 apply                                  # bloqueia novas aplicacoes
}

t_apply_reversao_imediata_incompleta_nao_desarma() {
  setup_guard_old_state
  MOCK_NFT_LOAD_FAIL=1 MOCK_NFT_RESTORE_FAIL=1 assert_nonzero apply
  [ -f "$HL_GUARD_DIR/armed" ] || fail "guard desarmado apos reversao incompleta"
  [ -f "$HL_GUARD_DIR/rollback-failed" ] || fail "falha nao registrada"
  assert_grep 'guard MANTIDO armado' "$HL_LOG_DIR/homelab-apply.log"
}
