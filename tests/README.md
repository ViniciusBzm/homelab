# Testes automatizados

| Suíte | Onde roda | Como | Cobre |
|---|---|---|---|
| [`server/`](server/) | Qualquer Linux com `unshare`, `restic`, `nft` (`/usr/sbin/nft`), `flock`, `python3` | `bash tests/server/run.sh [filtro]` (**sem sudo**) | backup, export consistente, pausa/religamento, locks, restauração local e externa, guard/rollback, firewall, segurança de config/logs/ambiente, códigos de saída |
| [`windows/`](windows/) | Windows PowerShell 5.1 | `powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\Test-HomeLabBackup.ps1` | validação do manifesto da cópia pull (alterado, faltando, sobrando, `..`, vazio), rotação atual/anterior |

## Reproduzir
1. Clone o repositório numa máquina Linux (ou copie `scripts/server` e `tests/server` para o servidor, **fora de `/tmp`**, que a suíte cobre com um `tmpfs` próprio).
2. `bash tests/server/run.sh`. O código de saída é 0 só se todos passarem. Para um subconjunto: `bash tests/server/run.sh backup`.
3. No Windows: o comando da tabela acima.

Não é preciso privilégio: a suíte **não usa sudo** e não altera o sistema.

## Isolamento da suíte de servidor
- Roda dentro de `unshare -rnm`:
  - **root falso** (uid 0 só no namespace; nenhum privilégio real);
  - **rede isolada** (o `nft` real opera numa pilha vazia e descartável);
  - **montagens privadas**, com um `tmpfs` próprio em `/tmp`.
- `docker`, `systemctl`, `sshd`, `systemd-run`, `curl`, `logger` e `iptables` são **mocks** (`server/mocks/`). `restic`, `flock`, `sha256sum`, `tar` e `python3` (SQLite) são **reais**.
- Os scripts aceitam caminhos `HL_*` e `HL_PATH` **somente** dentro de um namespace de usuário (veja abaixo). A suíte **aborta antes do primeiro teste** se algum comando de sistema não resolver para o mock, ou se algum script não respeitar `HL_PATH`.

## `HL_*` não é vetor de injeção em produção
Cada script privilegiado começa com o bloco `hl-env`. Se `/proc/self/uid_map` for o mapa identidade (`0 0 4294967295`, ou seja, root de verdade no namespace inicial), **toda** variável `HL_*` herdada é apagada antes de definir o `PATH` fixo. São duas camadas:
1. O `sudo` do Debian (`env_reset`) já não repassa `HL_*`.
2. O bloco `hl-env` cobre `sudo -E`, `sudo VAR=valor cmd`, shells de root e o systemd.

Evidências: os testes `t_hl_env_descartado_em_root_real` e `t_guarda_hl_env_antes_do_path_em_todos` passaram, e a execução no **namespace real** do servidor com `HL_PATH=/maligno` resultou no `PATH` de produção nos 7 scripts (no fim de [`evidencias/servidor-2026-11-27.txt`](evidencias/servidor-2026-11-27.txt)).

## Incidente de isolamento (27/11/2026) e correção
Na primeira execução, os scripts tinham `export PATH=/usr/local/sbin:…` fixo. Isso **anulou os mocks**, e alguns testes de guard chamaram o `systemctl`/`systemd-run` **reais** do servidor.
- **Impacto:** nenhum. As chamadas foram negadas pelo polkit ("Interactive authentication required"), porque o processo no namespace não tem privilégio real. Os hashes e as datas de `sshd_config.d/10-homelab-hardening.conf` e `/etc/nftables.conf`, os serviços (`nftables`, `ssh`, `docker`), os 4 contêineres e a ausência de unidades `homelab-guard` foram conferidos antes e depois: **inalterados**.
- **Correção:**
  1. `HL_PATH` respeitado pelos scripts, só dentro do sandbox (bloco `hl-env`);
  2. trava no `run.sh` que aborta se algum comando não resolver para o mock;
  3. teste `t_mocks_sao_usados_pelos_scripts`;
  4. `tmpfs` próprio em `/tmp`, para o `restic restore` não depender do dono do `/tmp` real.

## Evidências
| Arquivo | Conteúdo |
|---|---|
| [`evidencias/servidor-2026-11-27.txt`](evidencias/servidor-2026-11-27.txt) | Suíte de servidor **48/48** (Debian 12, kernel 6.1.0-56, restic 0.14.0, nftables 1.0.6) + prova do `hl-env` no namespace real |
| [`evidencias/windows-2026-11-27.txt`](evidencias/windows-2026-11-27.txt) | Suíte Windows **10/10** (Windows PowerShell 5.1) |

**Total: 58 testes aprovados.** São testes em **sandbox**; o que já está implantado no servidor está descrito em [M3](../docs/marcos/M3-observabilidade-backup.md).
