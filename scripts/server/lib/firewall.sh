# shellcheck shell=bash
# HomeLab - geracao do ruleset nftables a partir de /etc/homelab/firewall.conf.
#
#   ALLOWED_V4=192.0.2.0/24     sub-rede(s) autorizada(s) (obrigatorio; CSV)
#   ALLOWED_V6=fe80::/10            IPv6 autorizado (CSV; vazio = nenhum)
#   DOCKER_LAN_TCP=8090,3001        portas publicadas pelo Docker liberadas (porta do HOST)
#   DOCKER_LAN_UDP=                 idem, UDP
#
# Regras:
# - input: drop por padrao; SSH, mDNS e as portas Docker liberadas so de ALLOWED_*.
#   (O Docker atende IPv6 e conexoes locais pelo docker-proxy, que passa pela cadeia
#   input; por isso as portas Docker tambem aparecem aqui, restritas a ALLOWED_V6.)
# - forward (antes do Docker): conexoes novas com DNAT para containers so passam
#   se a porta original estiver na lista e a origem for ALLOWED_*.
# - Sem "flush ruleset": as tabelas do Docker sao preservadas.

# shellcheck source=common.sh
. "${HL_LIB_DIR:?}/common.sh"

fw_set_elems() { # CSV -> "elements = { a, b }" ou vazio
  [ -n "$1" ] && printf 'elements = { %s }' "${1//,/, }"
}

# Uso: fw_render ALLOWED_V4 ALLOWED_V6 DOCKER_LAN_TCP DOCKER_LAN_UDP
fw_render() {
  local a4=$1 a6=$2 tcp=$3 udp=$4
  hl_valid_cidr4_list "$a4" || { echo "ALLOWED_V4 invalido: '$a4'" >&2; return 2; }
  hl_valid_cidr6_list "$a6" || { echo "ALLOWED_V6 invalido: '$a6'" >&2; return 2; }
  hl_valid_port_list "$tcp" || { echo "DOCKER_LAN_TCP invalido: '$tcp'" >&2; return 2; }
  hl_valid_port_list "$udp" || { echo "DOCKER_LAN_UDP invalido: '$udp'" >&2; return 2; }
  cat <<EOF
#!/usr/sbin/nft -f
# HomeLab firewall (gerado por homelab-apply). Sem "flush ruleset": preserva o Docker.
table inet homelab_fw
delete table inet homelab_fw

table inet homelab_fw {
  set allowed4 { type ipv4_addr; flags interval; $(fw_set_elems "$a4") }
  set allowed6 { type ipv6_addr; flags interval; $(fw_set_elems "$a6") }
  set docker_lan_tcp { type inet_service; $(fw_set_elems "$tcp") }
  set docker_lan_udp { type inet_service; $(fw_set_elems "$udp") }

  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } accept
    iifname "docker0" accept
    iifname "br-*" accept
    ip  saddr @allowed4 tcp dport 22 accept comment "SSH so da sub-rede autorizada"
    ip6 saddr @allowed6 tcp dport 22 accept
    ip  saddr @allowed4 udp dport 5353 accept comment "mDNS"
    ip6 saddr @allowed6 udp dport 5353 accept
    ip  saddr @allowed4 tcp dport @docker_lan_tcp accept comment "docker-proxy (IPv4 local)"
    ip6 saddr @allowed6 tcp dport @docker_lan_tcp accept comment "docker-proxy (IPv6)"
    ip  saddr @allowed4 udp dport @docker_lan_udp accept
    ip6 saddr @allowed6 udp dport @docker_lan_udp accept
    udp sport 67 udp dport 68 accept comment "cliente DHCP"
    udp sport 547 udp dport 546 accept comment "cliente DHCPv6"
    limit rate 5/minute log prefix "homelab_fw drop: " level info
    counter drop
  }

  chain forward {
    type filter hook forward priority filter - 10; policy accept;
    ct state established,related accept
    iifname "docker0" accept
    iifname "br-*" accept
    ct status dnat oifname "docker0" jump docker_published
    ct status dnat oifname "br-*" jump docker_published
  }

  chain docker_published {
    ip  saddr @allowed4 meta l4proto tcp ct original proto-dst @docker_lan_tcp accept
    ip6 saddr @allowed6 meta l4proto tcp ct original proto-dst @docker_lan_tcp accept
    ip  saddr @allowed4 meta l4proto udp ct original proto-dst @docker_lan_udp accept
    ip6 saddr @allowed6 meta l4proto udp ct original proto-dst @docker_lan_udp accept
    limit rate 5/minute log prefix "homelab_fw docker drop: " level info
    counter drop
  }
}
EOF
}

# Le a configuracao (com compatibilidade com o arquivo antigo docker-lan-tcp) e
# imprime o ruleset. Uso: fw_render_from_conf [diretorio-de-config]
fw_render_from_conf() {
  local dir=${1:-${HL_ETC_DIR:-/etc/homelab}}
  ALLOWED_V4=""; ALLOWED_V6="fe80::/10"; DOCKER_LAN_TCP=""; DOCKER_LAN_UDP=""
  if [ -f "$dir/firewall.conf" ]; then
    hl_read_conf "$dir/firewall.conf" ALLOWED_V4 ALLOWED_V6 DOCKER_LAN_TCP DOCKER_LAN_UDP
  elif [ -f "$dir/docker-lan-tcp" ]; then
    hl_require_secure_file "$dir/docker-lan-tcp"
    DOCKER_LAN_TCP=$(tr -cd '0-9,' < "$dir/docker-lan-tcp" | sed 's/^,*//; s/,*$//')
  fi
  if [ -z "$ALLOWED_V4" ]; then
    echo "AVISO: ALLOWED_V4 nao definido em $dir/firewall.conf; usando todas as faixas privadas (RFC 1918)" >&2
    ALLOWED_V4="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
  fi
  fw_render "$ALLOWED_V4" "$ALLOWED_V6" "$DOCKER_LAN_TCP" "$DOCKER_LAN_UDP"
}
