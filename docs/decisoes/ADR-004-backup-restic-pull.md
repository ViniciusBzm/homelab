# ADR-004 — Backup com restic e cópia "pull"

**Data:** 27/11/2026 · **Estado:** Aceita

## Contexto
O disco é um pendrive, o maior risco de perda total. É preciso backup automatizado, criptografado, com teste real de restauração e pelo menos uma cópia **fora** do servidor, sem custo.

## Decisão
- Usar **restic 0.14** (pacote Debian) num repositório local em `/var/backups/homelab-restic`.
- O backup roda diariamente às 03:30 e pausa por cerca de 10 s os serviços com SQLite para uma cópia consistente.
- Conteúdo: `/etc`, `/opt/homelab`, a home do administrador, `/root` e metadados (pacotes, units, containers).
- Retenção 7/4/6. `restic check` toda noite, mais leitura de 10% dos dados aos domingos.
- **Teste de restauração** mensal e automático: restaura num diretório temporário e compara byte a byte.
- **Cópia "pull"** pelo PC Windows: uma tarefa do usuário copia o repositório por SSH, mantendo a cópia atual e a anterior. O servidor não tem como apagar as cópias do PC.
- A senha do backup é criada pela pessoa no momento da implantação e guardada no gerenciador de senhas dela, nunca no Git.

## Alternativas
- **Push do servidor para o PC:** exigiria um servidor SSH no Windows (mudança de sistema e porta aberta) e daria ao servidor acesso de escrita no PC.
- **Nuvem com camada gratuita:** útil como terceira cópia; fica PLANEJADO, sem dependência.
- **Clonezilla (imagem completa):** complementar, para recuperação total; PLANEJADO, porque exige desligar o servidor.
