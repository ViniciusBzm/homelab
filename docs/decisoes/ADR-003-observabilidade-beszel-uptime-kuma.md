# ADR-003 — Observabilidade com Beszel + Uptime Kuma

**Data:** 27/11/2026 · **Estado:** Aceita

## Contexto
Requisitos: métricas de CPU, RAM, temperatura, disco, rede e containers **com histórico**; S.M.A.R.T. quando houver suporte; disponibilidade de serviços; alertas; interface web moderna na LAN. Restrições: cerca de 5 GiB de RAM e um pendrive como disco, que não aguenta escrita contínua pesada.

## Decisão
| Ferramenta | Papel | Por quê |
|---|---|---|
| **Beszel 0.21.2** (hub + agente `-alpine`) | Métricas, histórico, containers, S.M.A.R.T. e alertas | Leve (dezenas de MB), interface moderna, alertas via Shoutrrr (ntfy) |
| **Uptime Kuma 2.5.12-slim** | Checks HTTP/TCP/DNS, página de status e push do backup | Cobre o que o Beszel não faz; a variante `slim` não traz MariaDB nem Chromium |
| **socket-proxy (linuxserver)** | API do Docker **só leitura** para os dois | Montar `docker.sock` dá controle total do Docker, mesmo com `:ro` |

Versões fixadas, limites de memória e CPU, healthchecks, rotação de logs e `restart: unless-stopped`.

## Alternativas descartadas
- **Prometheus + Grafana (+ node_exporter/cAdvisor):** mais RAM e escrita contínua; seria redundante com o Beszel.
- **Netdata:** completo, mas pesado para este hardware e com histórico gravado em disco.
- **Glances / Homepage / Dashy:** o Glances não tem histórico e alertas no mesmo pacote; Homepage e Dashy apenas agregam links e seriam redundantes.
