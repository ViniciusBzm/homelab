# ADR-002 — Firewall nftables compatível com Docker

**Data:** 26–27/11/2026 · **Estado:** Aceita

## Contexto
Não havia firewall (`INPUT ACCEPT`). O `nftables.conf` padrão do Debian começa com `flush ruleset`, que apaga as regras do Docker. Além disso, o Docker encaminha as portas publicadas por fora da cadeia `input`, então um firewall só de entrada não as protege.

## Decisão
- Usar uma tabela própria `inet homelab_fw`, carregada sem `flush ruleset`.
- **input:** política drop; SSH e mDNS só de faixas privadas; ICMP liberado; interfaces do Docker liberadas.
- **forward** (prioridade `filter - 10`, ou seja, antes do Docker): conexões novas para containers só passam se a **porta do host** estiver em `docker_lan_tcp`/`docker_lan_udp` e a origem for a LAN. Por padrão, nenhuma porta passa.
- A lista vem de `/etc/homelab/docker-lan-tcp`, então reexecutar o script não a apaga.
- Toda aplicação passa pelo guard: snapshot do estado e reversão automática se o acesso não for confirmado.

## Evidência
Porta publicada de teste bloqueada → liberada → bloqueada, observada pelo PC. O rollback restaurou o estado anterior (mesmo hash) no teste deliberado. Detalhes no [M2](../marcos/M2-rede-seguranca-automacao.md).

## Revisão de 27/11/2026 (PR #2) — proposta, ainda não aplicada no servidor
- **Sub-rede autorizada em vez de todas as faixas privadas.** O ruleset é gerado de `/etc/homelab/firewall.conf` (`ALLOWED_V4`, `ALLOWED_V6`, `DOCKER_LAN_TCP`, `DOCKER_LAN_UDP`). O deploy detecta a sub-rede da rota padrão (hoje a do ICS). Sem `ALLOWED_V4`, o script avisa e volta às faixas RFC 1918.
- **IPv6:** SSH, mDNS e as portas liberadas do Docker só de `ALLOWED_V6` (padrão `fe80::/10`, link-local). O Docker atende IPv6 e conexões locais pelo `docker-proxy`, que passa pela cadeia `input`; por isso as portas do Docker também aparecem lá, restritas.
- **Entrada validada:** CIDRs e portas checados por expressão regular. O arquivo é lido sem `source` (só `CHAVE=valor`, chaves permitidas, sem aspas ou metacaracteres) e precisa pertencer ao root sem escrita de grupo/outros.
- **Testes:** ruleset válido (`nft -c`) com e sem listas vazias; entradas inválidas e injeção rejeitadas; regras carregadas num namespace de rede isolado.

## Alternativas
- **ufw:** o Docker contorna as regras dele (problema conhecido).
- **`iptables: false` no Docker:** quebra a rede dos containers e exige NAT manual.
