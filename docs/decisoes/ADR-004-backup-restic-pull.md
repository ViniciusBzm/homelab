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

## Revisão de 27/11/2026 (PR #2) — proposta, ainda não aplicada no servidor
**Problema:** o PC copiava (`scp -r`) o repositório **vivo**. Uma cópia feita durante `backup` ou `prune` podia ficar inconsistente, por exemplo com índices apontando para packs já apagados.

**Correção:**
1. Backup, restauração local e prune usam o **mesmo lock** (`/run/homelab-backup.lock`): nunca rodam juntos.
2. Ao final de um ciclo **sem falhas** (backup → forget/prune → check), o servidor publica um **export** em `/var/backups/homelab-restic-export`:
   - cópia por hardlinks (o restic nunca altera arquivos já gravados), sem `locks/`;
   - `MANIFEST.sha256` e `GENERATION`;
   - troca atômica (`rename`) sob **lock exclusivo** em `homelab-restic-export.lock`.
3. O PC copia **só o export**, numa única conexão `ssh … flock -s … tar` (lock compartilhado), por um pipe binário do `cmd.exe`. Ele **valida o manifesto** (hash de cada arquivo, nenhum faltando, nenhum sobrando) antes de substituir a cópia boa. Se falhar, a cópia anterior fica intacta.
4. Com falha no ciclo, o export **não** é trocado: a cópia externa continua na última versão boa.

**Consequência dos hardlinks:** os arquivos do repositório e do export são os mesmos inodes, então o `chgrp`/`chmod` (grupo do administrador, somente leitura) vale para os dois. Isso já era o caso no modelo anterior.

**Outras correções:**
- Os contêineres pausados são registrados **antes** do `stop`, para que uma parada parcial também seja religada. Uma garantia em `trap EXIT` religa em qualquer saída. Serviços que não voltam fazem o backup terminar com **falha** e alerta.
- A restauração (local e externa) usa `restore --verify`, exige que cada banco SQLite esperado exista e passe no `PRAGMA integrity_check`, e que a contagem de arquivos restaurados seja **igual à do snapshot**. Antes, um diretório vazio passava.
- A URL de push na home do administrador é tratada como **não confiável**: sem link simbólico, com dono certo, só `http://127.0.0.1:<porta>/api/push/<token>` e `curl --proto =http`.

**Testes:** 48 cenários de servidor em sandbox (sucesso e falha) e 10 do lado Windows, num total de 58 aprovados. Ver [`tests/`](../../tests/). **Ainda não implantado no servidor.**

## Alternativas
- **Push do servidor para o PC:** exigiria um servidor SSH no Windows (mudança de sistema e porta aberta) e daria ao servidor acesso de escrita no PC.
- **Nuvem com camada gratuita:** útil como terceira cópia; fica PLANEJADO, sem dependência.
- **Clonezilla (imagem completa):** complementar, para recuperação total; PLANEJADO, porque exige desligar o servidor.
