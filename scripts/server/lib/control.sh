# shellcheck shell=bash
# Validacoes do deploy do HomeLab Control (funcoes puras, testadas no sandbox).

# Referencia de imagem com versao FIXA: repo:tag, tag com digito, nunca "latest".
cd_image_pinned() {
  local ref=$1 tag
  [[ "$ref" =~ ^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+$ ]] || return 1
  tag=${ref##*:}
  [[ "$tag" =~ [0-9] ]] || return 1
  [[ "$tag" != *latest* && "$tag" != *"<"* ]] || return 1
}

# Chave do Kuma: arquivo comum (nao link), dono = uid do conteiner, modo 0600/0400, conteudo valido.
cd_check_secret() {
  local f=$1 uid=$2 mode
  [ -L "$f" ] && { echo "chave: link simbolico recusado"; return 1; }
  [ -f "$f" ] || { echo "chave: ausente ($f)"; return 1; }
  [ "$(stat -c %u -- "$f")" = "$uid" ] || { echo "chave: dono deve ser uid $uid"; return 1; }
  mode=$(stat -c %a -- "$f")
  [ "$mode" = 600 ] || [ "$mode" = 400 ] || { echo "chave: modo $mode (esperado 600 ou 400)"; return 1; }
  [ "$(stat -c %s -- "$f")" -le 300 ] || { echo "chave: tamanho inesperado"; return 1; }
  grep -qxE '[A-Za-z0-9_+=/.-]{8,256}' "$f" || { echo "chave: formato invalido"; return 1; }
}

# Grava CHAVE=valor no .env sem interpretar o arquivo (valor restrito, sem metacaracteres).
cd_env_set() {
  local f=$1 key=$2 val=$3 tmp
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ && "$val" =~ ^[A-Za-z0-9._:/@-]*$ ]] || return 1
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  { grep -v "^${key}=" "$f" 2>/dev/null; echo "${key}=${val}"; } > "$tmp" && chmod --reference="$f" "$tmp" 2>/dev/null
  mv -f -- "$tmp" "$f"
}

# Le um valor do .env (so a chave pedida; nada e executado).
cd_env_get() { sed -n "s/^$2=\(.*\)$/\1/p" "$1" | tail -1; }
