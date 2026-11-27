#!/bin/bash
# HomeLab - teste de restauracao a partir de uma COPIA EXTERNA do repositorio restic
# (ex.: a copia "pull" do PC), usando a senha do backup DIGITADA pela pessoa.
# Prova que, se o servidor morrer, a copia externa + a senha guardada bastam.
#
# Uso: sudo bash homelab-external-restore-test.sh <diretorio-do-repositorio-copiado>
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPO="${1:?uso: sudo bash $0 <repositorio-copiado>}"
[ "$(id -u)" -eq 0 ] || { echo "Execute com sudo."; exit 1; }
[ -f "$REPO/config" ] || { echo "Nao parece um repositorio restic: $REPO"; exit 2; }
T=$(mktemp -d /tmp/hl-ext-restore.XXXXXX); trap 'rm -rf "$T"; unset RESTIC_PASSWORD' EXIT

echo ">>> Digite a SENHA DO BACKUP (a que voce guardou no gerenciador de senhas):"
read -rsp "Senha do backup: " RESTIC_PASSWORD </dev/tty; echo
export RESTIC_PASSWORD

echo "== snapshots na copia externa =="
restic -r "$REPO" snapshots --compact || { echo "EXTERNAL_RESTORE_FALHOU: senha incorreta ou copia ilegivel"; exit 1; }
echo "== integridade da copia (check + 100% dos dados) =="
restic -r "$REPO" check --read-data || { echo "EXTERNAL_RESTORE_FALHOU: check"; exit 1; }

CHECK=(/etc/ssh/sshd_config.d /etc/nftables.conf /etc/homelab/backup.conf /etc/systemd/timesyncd.conf.d
       /opt/homelab/stacks/monitoring/compose.yaml)
INC=(); for p in "${CHECK[@]}"; do INC+=(--include "$p"); done
restic -r "$REPO" restore latest --target "$T" "${INC[@]}" >/dev/null || { echo "EXTERNAL_RESTORE_FALHOU: restore"; exit 1; }
ok=0; bad=0
for p in "${CHECK[@]}"; do
  if diff -r "$p" "$T$p" >/dev/null 2>&1; then ok=$((ok+1)); echo "  igual: $p"; else bad=$((bad+1)); echo "  DIFERENTE: $p"; fi
done
# Dados dos servicos tambem restauram (sem comparar: mudam a cada minuto)
restic -r "$REPO" restore latest --target "$T" --include /opt/homelab/stacks/monitoring/data >/dev/null \
  && echo "  dados do Beszel/Kuma restaurados: $(du -sh "$T/opt/homelab/stacks/monitoring/data" | cut -f1)"
if [ "$bad" -eq 0 ] && [ "$ok" -gt 0 ]; then
  echo "EXTERNAL_RESTORE_OK itens=$ok $(date -Is)" | tee /var/backups/homelab-external-restore.status
else
  echo "EXTERNAL_RESTORE_FALHOU iguais=$ok diferentes=$bad"; exit 1
fi
