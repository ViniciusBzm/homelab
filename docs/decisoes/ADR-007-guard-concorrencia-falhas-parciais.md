# ADR-007 — Guard: concorrência, falhas parciais e logs de root

**Data:** 27/11/2026 · **Estado:** Proposta (PR #2, ainda **não aplicada** no servidor)

## Contexto
A revisão técnica do PR #2 apontou riscos no guard de SSH/firewall e nos scripts executados como root:
1. Duas execuções simultâneas do `homelab-apply.sh` sobrescreveriam o snapshot: a reversão voltaria a um estado não confirmado.
2. Reaplicar com um guard pendente fotografaria um estado ainda não validado.
3. Uma falha **no meio** (SSH aplicado, firewall não) só seria revertida pelo timer, depois de até 10 min.
4. O snapshot guardava arquivos, mas não o estado **em memória** (tabela carregada sem o serviço habilitado).
5. Logs escritos pelo root na home do administrador podiam ser redirecionados por um link simbólico. `/tmp/smart.$$` era previsível.
6. `homelab-m3-deploy.sh` e `homelab-postboot-check.sh` terminavam com código 0 mesmo com falhas.

## Decisão
- **Lock** `/run/homelab-apply.lock` (não bloqueante): uma aplicação por vez. O timer de reversão usa o mesmo lock (com espera), para nunca restaurar no meio de uma aplicação.
- **Recusa** (código 5) enquanto existir `armed`: é preciso confirmar ou esperar a reversão.
- **Tudo é gerado e validado antes** (`nft -c` do ruleset, configuração lida e verificada). Se algo falhar nessa fase, nada muda.
- **Reversão imediata:** qualquer falha em SSH/firewall (validação, reload, carga do nft) ou interrupção (`INT/TERM/HUP`) restaura o snapshot na hora e desarma o timer. Se o guard não armar, nada é alterado.
- **Snapshot completo:** drop-in do SSH, `nftables.conf`, **dump da tabela em memória** e estado do serviço. A restauração continua mesmo se um passo falhar, registra cada passo e devolve erro. Se o SSH restaurado não validar, remove o drop-in (volta ao padrão do Debian) para não trancar o acesso.
- **Confirmação** por arquivo na home: ignorada se for link simbólico.
- **Logs de root** em `/var/log/homelab/` (`0750 root:<grupo-admin>`, arquivos `0640`), recriados a cada execução. Nenhum log de root na home. Temporários com `mktemp`.
- **Códigos de saída:** todos os scripts terminam com `hl_finish`, que sai com 1 se qualquer etapa falhou.
- **Testável sem abrir brecha:** os caminhos aceitam sobrescrita `HL_*` e o `PATH` aceita `HL_PATH` **somente dentro de um namespace de usuário** (o sandbox de testes). O bloco `hl-env` no topo de cada script apaga toda variável `HL_*` quando `/proc/self/uid_map` é o mapa identidade, ou seja, root real. Isso impede que um ambiente herdado (`sudo -E`, `sudo VAR=… cmd`, shell de root) injete executáveis ou bibliotecas. O `env_reset` do sudo é a primeira camada; o `hl-env` é a segunda.

## Evidência (sandbox, 27/11/2026)
Testes `t_apply_*`, `t_guard_*` e `t_log_*`: concorrência recusada; guard pendente recusado; sshd inválido e falha na carga do nft revertidos **na hora** (estado em memória idêntico ao anterior); configuração inválida não muda nada; sem confirmação restaura; com confirmação mantém; confirmação por link simbólico ignorada; reexecução volta ao **último estado confirmado**; tabela carregada com serviço desabilitado restaurada com o serviço ainda desabilitado; log não segue link simbólico.

## Consequências
Reaplicar exige confirmar (ou esperar) o guard anterior. Os logs mudam de lugar: leia em `/var/log/homelab/`, como membro do grupo do administrador.
