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

# Fotografa o estado atual (atomico: snapshot.new -> snapshot).
guard_snapshot() {
  install -d -m 0700 -- "$GUARD_DIR"
  local s="$GUARD_DIR/snapshot.new"
  rm -rf -- "$s"; install -d -m 0700 -- "$s"
  if [ -f "$SSHD_DROPIN" ]; then cp -a -- "$SSHD_DROPIN" "$s/sshd-dropin.conf"; fi
  if [ -f "$NFT_CONF" ]; then cp -a -- "$NFT_CONF" "$s/nftables.conf"; fi
  if "$NFT_BIN" list table inet homelab_fw > "$s/runtime.nft" 2>/dev/null; then
    touch "$s/runtime-present"
  else
    rm -f "$s/runtime.nft"
  fi
  if systemctl is-enabled --quiet nftables 2>/dev/null; then touch "$s/nft-enabled"; fi
  rm -rf -- "$GUARD_DIR/snapshot"; mv -- "$s" "$GUARD_DIR/snapshot"
}

# Restaura o snapshot. Continua mesmo se um passo falhar e devolve !=0 se algum falhou.
guard_restore() {
  local s="$GUARD_DIR/snapshot" rc=0
  [ -d "$s" ] || { guard_log "ERRO: sem snapshot para restaurar"; return 1; }
  # SSH
  if [ -f "$s/sshd-dropin.conf" ]; then cp -a -- "$s/sshd-dropin.conf" "$SSHD_DROPIN"; else rm -f -- "$SSHD_DROPIN"; fi
  if sshd -t; then
    systemctl reload ssh || { guard_log "ERRO: reload do ssh falhou"; rc=1; }
  else
    # Ultimo recurso para nao trancar o acesso: volta ao padrao do Debian.
    guard_log "ERRO: sshd -t reprovou o snapshot; removendo o drop-in"
    rm -f -- "$SSHD_DROPIN"; systemctl reload ssh || true; rc=1
  fi
  # Firewall (arquivo + estado em memoria + servico)
  if [ -f "$s/nftables.conf" ]; then cp -a -- "$s/nftables.conf" "$NFT_CONF"; fi
  "$NFT_BIN" delete table inet homelab_fw 2>/dev/null || true
  if [ -f "$s/runtime-present" ]; then
    { echo "table inet homelab_fw"; echo "delete table inet homelab_fw"; cat "$s/runtime.nft"; } > "$GUARD_DIR/restore.nft"
    "$NFT_BIN" -f "$GUARD_DIR/restore.nft" || { guard_log "ERRO: falha ao recarregar as regras anteriores"; rc=1; }
  fi
  if [ -f "$s/nft-enabled" ]; then systemctl enable nftables >/dev/null 2>&1 || rc=1
  else systemctl disable nftables >/dev/null 2>&1 || true; fi
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
  local rc=0; guard_restore || rc=$?
  rm -f -- "$GUARD_DIR/armed"
  return $rc
}
