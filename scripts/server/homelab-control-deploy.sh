#!/bin/bash
# HomeLab - implanta o HomeLab Control (M4.4) com rollback automatico. Nao toca na stack do M3,
# no SSH nem no firewall (a porta fica so em 127.0.0.1; acesso por tunel SSH).
#
# Uso: sudo bash homelab-control-deploy.sh <usuario-admin> <repo> [--rollback]
#   <repo>      clone com o commit REVISADO (arvore limpa). A imagem recebe a tag do commit.
#   --rollback  volta para a imagem anterior registrada (sem build).
#
# 1. Pre-requisitos (nada e alterado se falhar)   4. Subida do projeto "control"
# 2. Arquivos da stack + validacao do gateway      5. Validacao (saude, rotas, isolamento, M3 intacto)
# 3. Build e inspecao da imagem                    6. Limpeza (mantem a imagem atual e a anterior)
# Falha em 4 ou 5 => rollback automatico (imagem e arquivos anteriores; sem anterior => down).
set -uo pipefail
# >>> hl-env: HL_* so valem no sandbox de testes. Falha segura: os overrides so sao
# mantidos se o processo estiver POSITIVAMENTE num namespace de usuario do tipo
# "unshare -r" (uid_map de uma linha "0 <uid> 1"). Root real, uid_map ilegivel ou
# qualquer falha => todas as HL_* herdadas sao descartadas. O grep usado e o do
# caminho absoluto do sistema (nao depende do PATH herdado).
_hl_keep=0
if [ -r /proc/self/uid_map ] && [ -x /usr/bin/grep ] \
   && /usr/bin/grep -qxE '[[:space:]]*0[[:space:]]+[1-9][0-9]*[[:space:]]+1[[:space:]]*' /proc/self/uid_map 2>/dev/null \
   && [ "$(/usr/bin/grep -c '' /proc/self/uid_map 2>/dev/null)" = 1 ]; then
  _hl_keep=1
fi
if [ "$_hl_keep" != 1 ]; then for _hl_v in $(compgen -v HL_); do unset "$_hl_v"; done; fi
unset _hl_keep _hl_v
# <<< hl-env
export PATH=${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
ADMIN_USER="${1:?uso: sudo bash $0 <usuario-admin> <repo> [--rollback]}"
REPO="$(readlink -f -- "${2:?uso: sudo bash $0 <usuario-admin> <repo> [--rollback]}")"
MODE=${3:-deploy}
HL_LIB_DIR="$REPO/scripts/server/lib"
# shellcheck source=lib/common.sh
. "$HL_LIB_DIR/common.sh"
# shellcheck source=lib/control.sh
. "$HL_LIB_DIR/control.sh"
hl_require_root
getent passwd "$ADMIN_USER" >/dev/null || hl_die "usuario inexistente: $ADMIN_USER" 2
ADMIN_GROUP=$(id -gn "$ADMIN_USER")
DIR=${HL_CONTROL_DIR:-/opt/homelab/stacks/control}
ENVF="$DIR/.env"
SECRET="$DIR/secrets/kuma_api_key"
CTR_UID=1000                       # usuario "node" da imagem
PORT=8088
COMPOSE=(docker compose -p control --project-directory "$DIR" -f "$DIR/compose.yaml")
M3_CTRS="beszel beszel-agent uptime-kuma socket-proxy"
hl_lock /run/homelab-deploy.lock
HL_LOG_GROUP=$ADMIN_GROUP hl_log_init homelab-control-deploy

m3_fingerprint() { docker ps --no-trunc --format '{{.Names}} {{.ID}} {{.State}}' | grep -E "^($(tr ' ' '|' <<< "$M3_CTRS")) " | sort; }

# ------------------------------------------------------------------ 1
hl_section "1. Pre-requisitos (somente leitura)"
command -v docker >/dev/null && docker compose version >/dev/null || hl_die "docker/compose indisponivel" 1
docker network inspect monitoring >/dev/null 2>&1 || hl_die "rede 'monitoring' (M3) inexistente" 1
M3_BEFORE=$(m3_fingerprint)
[ "$(wc -l <<< "$M3_BEFORE")" -eq 4 ] && ! grep -qv ' running$' <<< "$M3_BEFORE" || hl_die "stack do M3 nao esta integra (4 conteineres em execucao)" 1
hl_ok "M3 integro: $(awk '{print $1}' <<< "$M3_BEFORE" | tr '\n' ' ')"
for f in /var/backups/homelab-backup.status /var/backups/homelab-restore-test.status; do
  [ -f "$f" ] && [ ! -L "$f" ] || hl_die "arquivo de status ausente: $f" 1
done
[ -f "$ENVF" ] || hl_die "crie $ENVF a partir de stacks/control/.env.example (imagens com versao fixa)" 3
hl_require_secure_file "$ENVF"
NODE_IMAGE=$(cd_env_get "$ENVF" NODE_IMAGE); GATEWAY_IMAGE=$(cd_env_get "$ENVF" GATEWAY_IMAGE)
PREV_TAG=$(cd_env_get "$ENVF" CONTROL_TAG)
cd_image_pinned "$NODE_IMAGE" || hl_die "NODE_IMAGE sem versao fixa: '$NODE_IMAGE'" 3
cd_image_pinned "$GATEWAY_IMAGE" || hl_die "GATEWAY_IMAGE sem versao fixa: '$GATEWAY_IMAGE'" 3
msg=$(cd_check_secret "$SECRET" "$CTR_UID") || hl_die "$msg" 3
hl_ok "configuracao e chave do Kuma (arquivo protegido; conteudo nao exibido)"
if ss -Htln "sport = :$PORT" | grep -q . && ! docker ps --format '{{.Names}}' | grep -qx homelab-control; then
  hl_die "porta $PORT ocupada por outro processo" 1
fi

if [ "$MODE" = --rollback ]; then
  TAG=$(cd_env_get "$ENVF" PREVIOUS_TAG)
  [ -n "$TAG" ] || hl_die "nao ha imagem anterior registrada" 1
  hl_section "Rollback manual para $TAG"
else
  GIT=(git -c "safe.directory=$REPO" -C "$REPO")
  TAG=$("${GIT[@]}" rev-parse --short=12 HEAD) || hl_die "repositorio invalido: $REPO" 1
  [ -z "$("${GIT[@]}" status --porcelain)" ] || hl_die "arvore do repositorio com alteracoes locais" 1
  hl_ok "commit $TAG (anterior: ${PREV_TAG:-nenhum})"

  # ---------------------------------------------------------------- 2
  hl_section "2. Arquivos da stack"
  install -d -m 0750 -o root -g "$ADMIN_GROUP" "$DIR"
  install -d -m 0700 -o root -g root "$DIR/.previous"
  for f in compose.yaml gateway.conf; do [ -f "$DIR/$f" ] && cp -p -- "$DIR/$f" "$DIR/.previous/$f"; done
  docker pull -q "$GATEWAY_IMAGE" >/dev/null || hl_die "nao foi possivel baixar $GATEWAY_IMAGE" 1
  if docker run --rm --read-only --tmpfs /tmp --cap-drop ALL --network none \
       -v "$REPO/stacks/control/gateway.conf:/etc/nginx/conf.d/default.conf:ro" "$GATEWAY_IMAGE" nginx -t >/dev/null 2>&1; then
    hl_ok "gateway.conf valido (nginx -t)"
  else hl_die "gateway.conf reprovado no nginx -t" 1; fi
  install -m 0644 -o root -g root "$REPO/stacks/control/compose.yaml" "$DIR/compose.yaml"
  install -m 0644 -o root -g root "$REPO/stacks/control/gateway.conf" "$DIR/gateway.conf"
  hl_ok "compose.yaml e gateway.conf instalados em $DIR"

  # ---------------------------------------------------------------- 3
  hl_section "3. Build e inspecao da imagem"
  docker build -q -f "$REPO/stacks/control/Dockerfile" --build-arg "NODE_IMAGE=$NODE_IMAGE" \
    --label "org.opencontainers.image.revision=$TAG" -t "homelab-control:$TAG" "$REPO" >/dev/null || hl_die "build falhou" 1
  if docker run --rm --entrypoint sh --network none "homelab-control:$TAG" -c '
       [ "$(id -u)" = 1000 ] || exit 11
       for t in npm npx corepack yarn; do command -v $t >/dev/null && exit 12; done
       for m in tsx esbuild vite vitest @playwright typescript; do [ -e /app/node_modules/$m ] && exit 13; done
       [ -z "$(find /app -name fixtures -o -name "*.ts" -not -path "*/node_modules/*" | head -1)" ] || exit 14
       [ -f /app/server.mjs ] && [ -f /app/web/index.html ] || exit 15'; then
    hl_ok "imagem homelab-control:$TAG ($(docker image inspect -f '{{.Size}}' "homelab-control:$TAG" | awk '{printf "%.0f MB", $1/1e6}')): nao-root, sem ferramentas de dev, sem fixtures"
  else hl_die "imagem reprovada na inspecao (codigo $?)" 1; fi
fi

# ------------------------------------------------------------------ 4
rollback() {
  hl_section "ROLLBACK"
  for f in compose.yaml gateway.conf; do [ -f "$DIR/.previous/$f" ] && cp -p -- "$DIR/.previous/$f" "$DIR/$f"; done
  if [ -n "$PREV_TAG" ] && docker image inspect "homelab-control:$PREV_TAG" >/dev/null 2>&1; then
    cd_env_set "$ENVF" CONTROL_TAG "$PREV_TAG"
    "${COMPOSE[@]}" up -d --remove-orphans && echo "voltou para homelab-control:$PREV_TAG" || echo "ROLLBACK FALHOU: verifique manualmente"
  else
    "${COMPOSE[@]}" down --remove-orphans && echo "sem versao anterior: projeto control removido" || echo "ROLLBACK FALHOU: verifique manualmente"
  fi
  [ "$(m3_fingerprint)" = "$M3_BEFORE" ] && echo "M3 intacto apos o rollback" || echo "ATENCAO: M3 diferente do inicio"
  hl_fail "implantacao revertida"
  hl_finish
}

hl_section "4. Subida do projeto control"
[ "$MODE" = --rollback ] || { [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$TAG" ] && cd_env_set "$ENVF" PREVIOUS_TAG "$PREV_TAG"; }
cd_env_set "$ENVF" CONTROL_TAG "$TAG" || hl_die "gravar CONTROL_TAG" 1
"${COMPOSE[@]}" up -d --remove-orphans || rollback
for i in $(seq 1 40); do
  st=$(docker inspect -f '{{.State.Health.Status}}' homelab-control 2>/dev/null)
  [ "$st" = healthy ] && break; sleep 3
done
[ "${st:-}" = healthy ] && hl_ok "homelab-control saudavel" || { echo "estado: ${st:-ausente}"; rollback; }

# ------------------------------------------------------------------ 5
hl_section "5. Validacao"
ok=1
chk() { if "$@"; then :; else echo "  reprovado: $*"; ok=0; fi; }
probe() { docker exec homelab-control node -e "fetch('$1',{method:'${2:-GET}'}).then(r=>{console.log(r.status)},()=>console.log('ERR'))" 2>/dev/null; }
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$PORT/api/health"); chk [ "$code" = 200 ]
sum=$(curl -s -m 10 "http://127.0.0.1:$PORT/api/v1/summary")
for s in host backup containers monitors; do
  chk python3 -c "import json,sys; d=json.loads(sys.argv[1]); m={x['name']:x['state'] for x in d['meta']['sources']}; sys.exit(m.get('$s') not in ('ok','stale'))" "$sum"
done
echo "fontes: $(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(' '.join(x['name']+'='+x['state'] for x in d['meta']['sources']), '| status', d['data']['status'])" "$sum" 2>/dev/null)"
chk [ "$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}' homelab-control)" = "1000:1000 true [ALL]" ]
chk [ "$(docker inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' homelab-control)" = "127.0.0.1:$PORT " ]
chk [ "$(docker inspect -f '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}' homelab-control)" = "control_edge control_internal " ]
chk [ "$(probe http://control-gateway:8081/containers/json?all=1)" = 200 ]
chk [ "$(probe http://control-gateway:8081/containers/socket-proxy/json)" = 403 ]
chk [ "$(probe http://control-gateway:8081/version)" = 403 ]
chk [ "$(probe 'http://control-gateway:8081/containers/json?all=1' POST)" = 403 ]
chk [ "$(probe http://control-gateway:8082/api/push/x)" = 403 ]
chk [ "$(probe http://socket-proxy:2375/version)" = ERR ]
chk [ "$(probe http://uptime-kuma:3001/)" = ERR ]
chk [ "$(m3_fingerprint)" = "$M3_BEFORE" ]
[ "$ok" = 1 ] && hl_ok "rotas, endurecimento, isolamento do socket-proxy e M3 intacto" || rollback

# ------------------------------------------------------------------ 6
hl_section "6. Limpeza"
keep="$TAG $(cd_env_get "$ENVF" PREVIOUS_TAG)"
for img in $(docker images homelab-control --format '{{.Tag}}'); do
  if ! grep -qw -- "$img" <<< "$keep"; then docker rmi -f "homelab-control:$img" >/dev/null && echo "removida homelab-control:$img"; fi
done
hl_ok "implantado homelab-control:$TAG em 127.0.0.1:$PORT (tunel: ssh -L $PORT:127.0.0.1:$PORT homelab)"
hl_finish
