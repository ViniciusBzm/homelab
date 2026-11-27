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

## Alternativas
- **ufw:** o Docker contorna as regras dele (problema conhecido).
- **`iptables: false` no Docker:** quebra a rede dos containers e exige NAT manual.
