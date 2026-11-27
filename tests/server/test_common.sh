# shellcheck shell=bash
# Funcoes comuns e codigos de saida.

t_finish_codigo_de_saida() {
  . "$HL_LIB_DIR/common.sh"
  ( HL_FAILS=0; hl_finish ) >/dev/null; [ $? -eq 0 ] || fail "sem falhas deveria sair 0"
  ( HL_FAILS=2; hl_finish ) >/dev/null; [ $? -eq 1 ] || fail "com falhas deveria sair 1"
}

t_scripts_terminam_com_codigo_correto() {
  for s in homelab-apply homelab-backup homelab-restore-test homelab-external-restore-test homelab-m3-deploy; do
    last=$(grep -v '^\s*$' "$REPO/scripts/server/$s.sh" | tail -1)
    [ "$last" = "hl_finish" ] || fail "$s.sh nao termina com hl_finish (ultima linha: $last)"
  done
  tail -1 "$REPO/scripts/server/homelab-postboot-check.sh" | grep -q 'exit \$(( FAILS > 0' || fail "postboot sem exit code"
}

t_sem_temporario_previsivel() {
  ! grep -nE '/tmp/[A-Za-z._-]*\$\$' "$REPO"/scripts/server/*.sh || fail "arquivo temporario previsivel (\$\$) em /tmp"
}

t_root_nao_escreve_log_na_home_do_admin() {
  ! grep -nE 'ADMIN_HOME/homelab-[a-z0-9-]*\.log' "$REPO"/scripts/server/*.sh || fail "log de root na home do administrador"
}

t_mocks_sao_usados_pelos_scripts() {
  # O guard-rollback sem nada armado so chama logger/systemctl: confirma que foram os mocks.
  HL_LIB_DIR="$REPO/scripts/server/lib" bash "$REPO/scripts/server/homelab-guard-rollback.sh" >/dev/null 2>&1
  bash -c 'export PATH=${HL_PATH:-/usr/bin}; command -v systemctl' | grep -q "$HERE/mocks/systemctl" || fail "script usaria o systemctl real"
}

# Executa o bloco "hl-env" de um script com um uid_map simulado e devolve o PATH resultante.
# PATH herdado aponta para um diretorio com um "grep" falso que sempre aprova.
hl_env_path_with_map() {
  local script=$1 map=$2 blk
  mkdir -p "$SB/evil"; printf '#!/bin/sh\nexit 0\n' > "$SB/evil/grep"; chmod +x "$SB/evil/grep"
  blk=$(sed -n '/>>> hl-env/,/<<< hl-env/p' "$script" | sed "s|/proc/self/uid_map|$map|g")
  env -i PATH="$SB/evil:/usr/bin:/bin" HL_PATH=/maligno HL_LIB_DIR=/maligno HL_FAILS=9 bash -c "$blk
export PATH=\${HL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}
echo \"\$PATH|\${HL_LIB_DIR:-}|\${HL_FAILS:-}\""
}

t_hl_env_descartado_em_root_real() {
  local PROD="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin||"
  printf '         0          0 4294967295\n' > "$SB/map-real"     # namespace inicial (root de verdade)
  printf '         0       1000          1\n' > "$SB/map-teste"    # namespace de usuario (sandbox)
  printf '         0       1000          1\n         1     100000      65536\n' > "$SB/map-duas"   # nao e o sandbox
  printf 'lixo\n' > "$SB/map-lixo"
  for s in "$REPO"/scripts/server/homelab-*.sh; do
    n=$(basename "$s")
    [ "$(hl_env_path_with_map "$s" "$SB/map-real")" = "$PROD" ] || fail "$n: HL_* aceito em root real (grep falso no PATH)"
    [ "$(hl_env_path_with_map "$s" "$SB/inexistente")" = "$PROD" ] || fail "$n: uid_map ilegivel deveria descartar"
    [ "$(hl_env_path_with_map "$s" "$SB/map-duas")" = "$PROD" ] || fail "$n: mapa nao identificado deveria descartar"
    [ "$(hl_env_path_with_map "$s" "$SB/map-lixo")" = "$PROD" ] || fail "$n: mapa invalido deveria descartar"
    out=$(hl_env_path_with_map "$s" "$SB/map-teste")
    [ "${out%%|*}" = "/maligno" ] || fail "$n: sandbox deveria aceitar HL_PATH ($out)"
  done
}

t_hl_env_usa_grep_por_caminho_absoluto() {
  for s in "$REPO"/scripts/server/homelab-*.sh; do
    blk=$(sed -n '/>>> hl-env/,/<<< hl-env/p' "$s")
    grep -q '/usr/bin/grep -qxE' <<< "$blk" || fail "$(basename "$s"): sem /usr/bin/grep"
    bare=$(grep -v '^[[:space:]]*#' <<< "$blk" | grep -oE '(/usr/bin/)?grep ' | grep -vc '^/usr/bin/grep ')
    [ "$bare" -eq 0 ] || fail "$(basename "$s"): $bare chamada(s) de grep sem caminho absoluto"
  done
}

t_guarda_hl_env_antes_do_path_em_todos() {
  for s in "$REPO"/scripts/server/homelab-*.sh; do
    awk '/>>> hl-env/{g=NR} /^export PATH=/{p=NR} END{exit !(g && p && g<p)}' "$s" || fail "$(basename "$s") sem guarda hl-env antes do PATH"
  done
}

t_sintaxe_bash() {
  for f in "$REPO"/scripts/server/*.sh "$REPO"/scripts/server/lib/*.sh; do bash -n "$f" || fail "sintaxe: $f"; done
}
