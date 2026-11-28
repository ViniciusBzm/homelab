# shellcheck shell=bash
# Deploy do HomeLab Control: validacoes puras (lib/control.sh) e arquivos da stack.

t_control_imagem_com_versao_fixa() {
  . "$REPO/scripts/server/lib/control.sh"
  for ok in node:22.21.1-alpine3.22 nginxinc/nginx-unprivileged:1.29.3-alpine registry.example/a/b:2026.11; do
    cd_image_pinned "$ok" || fail "recusou imagem fixa: $ok"
  done
  for bad in "" node node:latest node:lts-alpine "node:22.<x>.<y>-alpine" "node:22;rm -rf /" "NODE:22"; do
    cd_image_pinned "$bad" && fail "aceitou imagem sem versao fixa: '$bad'"
  done
  return 0
}

t_control_chave_do_kuma_protegida() {
  . "$REPO/scripts/server/lib/control.sh"
  local k="$SB/key" uid; uid=$(id -u)
  printf 'abcdEFGH1234_-key\n' > "$k"; chmod 600 "$k"
  cd_check_secret "$k" "$uid" >/dev/null || fail "recusou chave valida"
  chmod 644 "$k"; cd_check_secret "$k" "$uid" >/dev/null && fail "aceitou chave legivel por outros"
  chmod 600 "$k"; cd_check_secret "$k" 4242 >/dev/null && fail "aceitou dono errado"
  printf 'curta\n' > "$k"; cd_check_secret "$k" "$uid" >/dev/null && fail "aceitou formato invalido"
  ln -s "$k" "$SB/link"; cd_check_secret "$SB/link" "$uid" >/dev/null && fail "aceitou link simbolico"
  out=$(cd_check_secret "$k" "$uid"); grep -q curta <<< "$out" && fail "mensagem expos o conteudo da chave"
  return 0
}

t_control_env_set_seguro() {
  . "$REPO/scripts/server/lib/control.sh"
  local e="$SB/env"; printf 'NODE_IMAGE=node:22.1.0-alpine\nCONTROL_TAG=aaa\n' > "$e"; chmod 640 "$e"
  cd_env_set "$e" CONTROL_TAG bbb111 || fail "nao gravou"
  [ "$(cd_env_get "$e" CONTROL_TAG)" = bbb111 ] || fail "valor nao atualizado"
  [ "$(grep -c '^CONTROL_TAG=' "$e")" = 1 ] || fail "chave duplicada"
  [ "$(cd_env_get "$e" NODE_IMAGE)" = node:22.1.0-alpine ] || fail "outra chave perdida"
  [ "$(stat -c %a "$e")" = 640 ] || fail "modo do .env alterado"
  cd_env_set "$e" CONTROL_TAG 'x;rm -rf /' && fail "aceitou metacaracteres"
  cd_env_set "$e" 'bad key' v && fail "aceitou chave invalida"
  return 0
}

t_control_stack_isolada_e_endurecida() {
  local c="$REPO/stacks/control/compose.yaml" g="$REPO/stacks/control/gateway.conf" d="$REPO/stacks/control/Dockerfile"
  grep -q '"127.0.0.1:8088:8088"' "$c" || fail "porta nao restrita a 127.0.0.1"
  [ "$(grep -cE '^\s+- "[0-9.]*:?[0-9]+:[0-9]+"' "$c")" = 1 ] || fail "mais de uma porta publicada"
  awk '/^  homelab-control:/,/^secrets:/' "$c" | grep -q 'networks: \[control_internal\]' || fail "control deve ficar so na rede interna"
  awk '/^  homelab-control:/,/^secrets:/' "$c" | grep -q 'ports:' && fail "control nao pode publicar portas"
  grep -q 'inhibit_ipv4: "true"' "$c" || fail "rede interna com IP do host"
  awk '/^  homelab-control:/,/^secrets:/' "$c" | grep -q monitoring && fail "control nao pode entrar na rede monitoring"
  grep -q 'internal: true' "$c" || fail "rede interna ausente"
  grep -q 'cap_drop: \[ALL\]' "$c" && grep -q 'read_only: true' "$c" && grep -q 'no-new-privileges:true' "$c" || fail "endurecimento ausente"
  grep -q 'homelab-backup.status:ro' "$c" && grep -q 'homelab-restore-test.status:ro' "$c" || fail "status nao montados :ro"
  grep -v '^\s*#' "$c" | grep -qE 'restic|docker.sock|/var/backups:' && fail "montagem alem dos arquivos de status"
  grep -q 'location = /containers/json' "$g" && grep -q 'all=1' "$g" || fail "gateway sem lista restrita do Docker"
  [ "$(grep -cE '^\s*proxy_pass \$' "$g")" = 3 ] || fail "gateway com proxies inesperados"
  grep -q '^USER node' "$d" || fail "imagem nao roda como node"
  grep -q 'rm -rf /usr/local/lib/node_modules/npm' "$d" || fail "npm nao removido da imagem final"
}
