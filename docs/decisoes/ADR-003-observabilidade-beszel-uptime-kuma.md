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

## Privacidade dos alertas (ntfy.sh público)
- **Quem lê:** no servidor público `ntfy.sh`, um tópico sem autenticação é lido e publicado por **qualquer pessoa que saiba o nome**. A única proteção é o nome aleatório (`hl-` + 96 bits). Ele fica fora do Git e só aparece nas configurações do Beszel e do Kuma.
- **O que trafega:** título e texto do alerta (nome do monitor, "Down/Up", mensagem de erro curta e, no Beszel, o nome do sistema e o valor da métrica). Isso fica **armazenado temporariamente nos servidores do ntfy.sh**, que guardam mensagens em cache por algumas horas para entrega posterior, e passa pelos serviços de push do celular.
- **Regras:**
  - nomes de monitores e sistemas genéricos (sem IP, usuário ou domínio);
  - nenhum segredo em mensagens;
  - se o tópico vazar (print, log, repositório), **trocar** o tópico no Beszel e no Kuma e assinar o novo.
- **Evolução possível (sem custo):** token de acesso com conta gratuita no ntfy.sh, ou um ntfy próprio (outro serviço; só com decisão registrada).

## Limitações do monitoramento hospedado no próprio servidor
| Situação | O que acontece | Mitigação atual / futura |
|---|---|---|
| Wyse desligado, travado ou sem energia | Beszel e Kuma param junto: **nenhum alerta** é enviado | Futuro: *dead-man's switch* externo (ex.: `HEARTBEAT_URL` do agente Beszel para um serviço gratuito de heartbeat que alerte quando o sinal **para**) |
| ICS do Windows quebrado (servidor sem internet) | O Kuma detecta (monitor "ICS do Windows"), mas o alerta não sai, porque o ntfy.sh fica inalcançável | O watchdog do Windows corrige em até 5 min. Futuro: alerta local no Windows |
| PC Windows desligado | O servidor fica sem internet; mesmo efeito da linha acima | Aceito: topologia provisória (ADR-001) |
| Reboot curto (menos de 1 min) | Sem alerta, por projeto (evita ruído) | Os limites ficam no Beszel/Kuma |
| Pendrive falhando | S.M.A.R.T. básico (o controlador expõe pouco); a falha pode ser abrupta | Backup diário + cópia externa; imagem Clonezilla (planejado) |

Em resumo, o monitoramento atual detecta problemas **dentro** de um servidor que está de pé e com internet. A ausência total do servidor só é percebida com um observador externo, que ainda **não existe**.
