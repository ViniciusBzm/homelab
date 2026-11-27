# ADR-005 — Scripts idempotentes em vez de Ansible (por enquanto)

**Data:** 27/11/2026 · **Estado:** Aceita

## Contexto
Foi pedido avaliar o Ansible.

## Avaliação
- **Um único host:** o Ansible agrega mais valor com vários servidores ou papéis reutilizáveis.
- **Nó de controle:** o Ansible não roda nativamente no Windows; precisaria do WSL, que **não inicia neste PC** porque a virtualização (SVM) está desligada na BIOS. Rodá-lo no próprio servidor anula a vantagem de ter o controle fora do host.
- **Idempotência já obtida:** os scripts em `scripts/server/` são reexecutáveis (testado), validam antes de aplicar (`sshd -t`, `nft -c`, `compose config`) e têm reversão automática.
- **Sudo com senha:** o fluxo seria o mesmo (`--ask-become-pass`).

## Decisão
Manter os scripts Bash idempotentes e o Compose. **Reavaliar** quando houver um segundo host ou quando o WSL ficar disponível. Os scripts já estão organizados por função para virar roles depois.
