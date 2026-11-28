# shellcheck shell=bash
# HomeLab - guard de reversao para mudancas em SSH e firewall.
#
# Ciclo: guard_snapshot -> guard_arm N -> (aplicar) -> confirmacao do administrador
#   - falha durante a aplicacao  -> guard_restore imediato + guard_disarm
#   - sem confirmacao em N min   -> timer executa homelab-guard-rollback (guard_check)
#   - confirmacao (arquivo mais novo que o "armed") -> mudancas mantidas
#
# O snapshot guarda arquivos E o estado em memoria (tabela nft carregada,
# servico habilitado), para que a reversao volte exatamente ao estado anterior,
# inclusive numa reexecucao.

# shellcheck source=common.sh
. "${HL_LIB_DIR:?}/common.sh"

GUARD_DIR=${HL_GUARD_DIR:-/var/lib/homelab-guard}
SSHD_DROPIN=${HL_SSHD_DROPIN:-/etc/ssh/sshd_config.d/10-homelab-hardening.conf}
NFT_CONF=${HL_NFT_CONF:-/etc/nftables.conf}
NFT_BIN=${HL_NFT:-nft}
GUARD_UNIT=${HL_GUARD_UNIT:-homelab-guard}
GUARD_ROLLBACK_BIN=${HL_GUARD_ROLLBACK_BIN:-/usr/local/sbin/homelab-guard-rollback}

guard_log() { echo "$(date -Is) guard: $*" | tee -a "$GUARD_DIR/guard.log" >&2; command -v logger >/dev/null && logger -t homelab-guard "$*" || true; }

guard_pending() { [ -f "$GUARD_DIR/armed" ]; }

# Fotografa o estado atual. Toda operacao e verificada; qualquer falha devolve !=0
# e o snapshot anterior (se houver) continua intacto.
guard_snapshot() {
  local s="$GUARD_DIR/snapshot.new" tables state
  install -d -m 0700 -- "$GUARD_DIR" || return 1
  rm -rf -- "$s" && install -d -m 0700 -- "$s" || return 1
  if [ -e "$SSHD_DROPIN" ]; then cp -a -- "$SSHD_DROPIN" "$s/sshd-dropin.conf" || return 1; fi
  if [ -e "$NFT_CONF" ]; then cp -a -- "$NFT_CONF" "$s/nftables.conf" || return 1; fi
  # "Tabela ausente" e um estado valido; "erro ao consultar o nft" nao e.
  tables=$("$NFT_BIN" list tables inet) || { guard_log "ERRO: nft list tables falhou"; return 1; }
  if grep -qx 'table inet homelab_fw' <<< "$tables"; then
    "$NFT_BIN" list table inet homelab_fw > "$s/runtime.nft" && [ -s "$s/runtime.nft" ] \
      || { guard_log "ERRO: nao foi possivel gravar as regras em memoria"; return 1; }
    : > "$s/runtime-present" || return 1
  fi
  state=$(systemctl is-enabled nftables 2>/dev/null)
  case "$state" in
    enabled) : > "$s/nft-enabled" || return 1 ;;
    disabled|masked|static|indirect|alias|linked*) ;;
    *) guard_log "ERRO: estado do servico nftables desconhecido: '$state'"; return 1 ;;
  esac
  # Troca: o snapshot antigo so sai depois que o novo esta no lugar.
  rm -rf -- "$GUARD_DIR/snapshot.prev"
  if [ -d "$GUARD_DIR/snapshot" ]; then mv -- "$GUARD_DIR/snapshot" "$GUARD_DIR/snapshot.prev" || return 1; fi
  if ! mv -- "$s" "$GUARD_DIR/snapshot"; then
    [ -d "$GUARD_DIR/snapshot.prev" ] && mv -- "$GUARD_DIR/snapshot.prev" "$GUARD_DIR/snapshot"
    return 1
  fi
  rm -rf -- "$GUARD_DIR/snapshot.prev"
}

# Restaura o snapshot. Continua mesmo se um passo falhar e devolve !=0 se algum falhou.
# Firewall: UMA transacao nft (cria + apaga + recarrega no mesmo arquivo), sem janela
# em que a tabela fique ausente.
guard_restore() {
  local s="$GUARD_DIR/snapshot" rc=0 tx="$GUARD_DIR/restore.nft"
  [ -d "$s" ] || { guard_log "ERRO: sem snapshot para restaurar"; return 1; }
  # SSH
  if [ -f "$s/sshd-dropin.conf" ]; then
    cp -a -- "$s/sshd-dropin.conf" "$SSHD_DROPIN" || { guard_log "ERRO: copiar drop-in do SSH"; rc=1; }
  else
    rm -f -- "$SSHD_DROPIN" || { guard_log "ERRO: remover drop-in do SSH"; rc=1; }
  fi
  if sshd -t; then
    systemctl reload ssh || { guard_log "ERRO: reload do ssh falhou"; rc=1; }
  else
    # Ultimo recurso para nao trancar o acesso: volta ao padrao do Debian.
    guard_log "ERRO: sshd -t reprovou o snapshot; removendo o drop-in"
    rm -f -- "$SSHD_DROPIN"; systemctl reload ssh || true; rc=1
  fi
  # Firewall em memoria: transacao unica.
  if { echo "table inet homelab_fw"; echo "delete table inet homelab_fw"
       if [ -f "$s/runtime-present" ]; then cat -- "$s/runtime.nft"; fi; } > "$tx"; then
    "$NFT_BIN" -f "$tx" || { guard_log "ERRO: transacao nft de restauracao falhou (regras atuais mantidas)"; rc=1; }
  else
    guard_log "ERRO: nao foi possivel gravar $tx"; rc=1
  fi
  # Arquivo e servico
  if [ -f "$s/nftables.conf" ]; then
    cp -a -- "$s/nftables.conf" "$NFT_CONF" || { guard_log "ERRO: copiar nftables.conf"; rc=1; }
  else
    rm -f -- "$NFT_CONF" || rc=1
  fi
  if [ -f "$s/nft-enabled" ]; then systemctl enable nftables >/dev/null 2>&1 || { guard_log "ERRO: habilitar nftables"; rc=1; }
  else systemctl disable nftables >/dev/null 2>&1 || { guard_log "ERRO: desabilitar nftables"; rc=1; }; fi
  guard_log "restauracao concluida (rc=$rc)"
  echo "$(date -Is) rc=$rc" > "$GUARD_DIR/last-rollback"
  return $rc
}

# Arma a reversao automatica em N minutos.
guard_arm() {
  local minutes=$1 confirm=$2
  systemctl stop "$GUARD_UNIT.timer" "$GUARD_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$GUARD_UNIT.timer" "$GUARD_UNIT.service" >/dev/null 2>&1 || true
  rm -f -- "$confirm"
  printf 'CONFIRM=%s\nARMED_AT=%s\n' "$confirm" "$(date +%s)" > "$GUARD_DIR/armed"
  if systemd-run --quiet --unit="$GUARD_UNIT" --on-active="${minutes}min" "$GUARD_ROLLBACK_BIN"; then
    return 0
  fi
  rm -f -- "$GUARD_DIR/armed"; return 1
}

guard_disarm() {
  systemctl stop "$GUARD_UNIT.timer" "$GUARD_UNIT.service" >/dev/null 2>&1 || true
  rm -f -- "$GUARD_DIR/armed"
}

# Acao do timer: mantem se confirmado depois de armar; senao restaura.
guard_check() {
  [ -f "$GUARD_DIR/armed" ] || { guard_log "nada armado"; return 0; }
  local confirm
  confirm=$(sed -n 's/^CONFIRM=//p' "$GUARD_DIR/armed")
  # O arquivo de confirmacao fica na home do administrador: nao seguir links.
  if [ -n "$confirm" ] && [ -f "$confirm" ] && [ ! -L "$confirm" ] && [ "$confirm" -nt "$GUARD_DIR/armed" ]; then
    guard_log "acesso confirmado; mudancas mantidas"
    rm -f -- "$confirm" "$GUARD_DIR/armed"
    return 0
  fi
  guard_log "acesso NAO confirmado; restaurando o snapshot"
  if guard_restore; then
    rm -f -- "$GUARD_DIR/armed" "$GUARD_DIR/rollback-failed"
    return 0
  fi
  # Restauracao incompleta: o guard NAO e desarmado. O "armed" fica, o homelab-apply
  # recusa novas execucoes e a unidade termina com erro (visivel em systemctl --failed).
  echo "$(date -Is) restauracao incompleta; ver $GUARD_DIR/guard.log" > "$GUARD_DIR/rollback-failed"
  guard_log "CRITICO: restauracao incompleta; guard mantido armado. Verifique pelo console e so entao remova $GUARD_DIR/armed"
  return 1
}
