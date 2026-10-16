# M0 — Fundação do servidor: Debian, rede e SSH

**Período:** outubro de 2026  
**Ambiente:** Dell Wyse 7020 · Debian 12 (Bookworm)  
**Status:** **CONFIRMADO** para administração local, boot em modo texto e SSH após reinício. A dependência de internet via Windows continua **PENDENTE DE VALIDAÇÃO**.

> Este registro descreve o que foi observado nas sessões. Não documenta uma configuração de produção, nem garante disponibilidade contínua.

## Objetivo

Preparar um computador reaproveitado para funcionar como laboratório Linux de baixo custo, permitindo administração remota sem manter um desktop gráfico aberto continuamente.

## Equipamento e premissas

| Item | Observação |
|---|---|
| Máquina | Dell Wyse 7020, adquirido por R$ 350 |
| CPU | AMD GX-420CA, conforme identificação anterior (reconfirmação pendente) |
| Memória | 6 GB nominais; ~5,2 GiB visíveis no Debian |
| Armazenamento | 32 GB nominais; partição raiz de ~29 GB |
| Sistema | Debian 12 Bookworm, arquitetura amd64 |
| Uso | Laboratório pessoal, não infraestrutura de produção |

O hardware foi escolhido para aprender com limites reais, sem substituir a máquina antes de medir o que ela consegue executar.

## O caminho percorrido

### 1. Instalação e administração local

**CONFIRMADO:** Debian 12 instalado e login local funcional. O GNOME permaneceu instalado, mas o alvo de boot foi ajustado para modo texto (`multi-user.target`) para não iniciar a interface gráfica por padrão.

Comandos úteis para inspecionar o estado do sistema:

```bash
systemctl get-default
free -h
df -h /
```

**Cuidado com a interpretação:** o comportamento após a mudança foi observado, mas não é correto atribuir toda a diferença de uso de memória exclusivamente à interface gráfica; o consumo depende de vários processos.

### 2. Contorno provisório de conectividade

A primeira tentativa de conexão Wi-Fi diretamente no Wyse não encontrou o hotspot testado. Isso **não** comprovou defeito de placa ou driver.

A solução provisória foi conectar o servidor, por cabo Ethernet, ao PC Windows com compartilhamento de conexão à internet (ICS).

```text
Internet / rede doméstica
          |
    PC com Windows
     Wi-Fi + ICS
          |
      Ethernet
          |
    Dell Wyse 7020
      Debian / SSH
```

**CONFIRMADO:** a conexão permitiu atualizar o Debian, acessar o servidor por SSH e baixar imagens de container.

**LIMITAÇÃO:** o compartilhamento depende do Windows estar ligado e configurado. Em reinícios, foi observado que o SSH local voltava a funcionar, mas a saída para a internet do Wyse nem sempre voltava automaticamente. Reativar o compartilhamento no Windows restaurou a conectividade em testes anteriores.

Não foram publicados endereços IP, nomes de usuário ou informações de acesso neste documento.

### 3. SSH e diagnóstico de reinício

O SSH foi instalado e passou a aceitar conexões a partir do PowerShell do Windows.

Houve uma falha de acesso após reinício: `Connection timed out`. A investigação diferenciou **serviço SSH ativo** de **conectividade de rede**, evitando concluir que um timeout significava necessariamente problema no daemon.

Verificações usadas durante o diagnóstico:

```bash
systemctl is-active ssh
systemctl is-enabled ssh
systemctl get-default
```

**Evidências posteriores:**

- `ssh` foi observado como `active` e `enabled`.
- A configuração do NetworkManager tinha permissão de conexão restrita a um usuário; esse vínculo foi removido e a mudança conferida.
- Um reinício posterior permitiu conexão SSH **sem login local prévio** no Wyse.

**CONFIRMADO:** acesso remoto por SSH após o reinício testado.  
**PENDENTE DE VALIDAÇÃO:** repetibilidade da conectividade à internet via ICS; não confundir com o estado do serviço SSH.

**Recuperação:** enquanto a topologia depender do Windows, manter monitor e teclado disponíveis antes de alterar rede, boot, usuários, firewall ou SSH.

### 4. Manutenção do Debian

Foram executadas atualização de índices e instalação supervisionada de atualizações do sistema.

```bash
sudo apt update
sudo apt-get upgrade
sudo dpkg --audit
```

**Observações registradas:**

- 75 pacotes foram atualizados durante a manutenção.
- `dpkg --audit` não apontou pendências na verificação registrada.
- O kernel `6.1.0-53-amd64` foi instalado e confirmado após reinício.
- Na última consulta de APT desta fase, os pacotes estavam atualizados.
- Foram observados avisos sobre possível firmware `amdgpu` ausente, sem evidência de falha impeditiva no boot.

O estado das atualizações é um registro daquele momento, não uma garantia sobre a situação atual.

## Medições da fundação

Uma medição anterior à instalação do Docker registrou:

| Recurso | Valor observado |
|---|---:|
| RAM total no Linux | 5,2 GiB |
| RAM usada | 535 MiB |
| RAM disponível | 4,7 GiB |
| Swap em uso | 0 B |
| Partição raiz | ~29 GB |
| Disco usado | 5,8 GB |
| Disco livre | ~22 GB |

As medições depois da instalação do Docker estão em [M1 — primeiro experimento com Docker](M1-primeiro-experimento-docker.md).

## Lições aprendidas

1. Um serviço ativo não garante que a rede esteja operacional.
2. Um IP funcional em uma sessão não deve ser tratado como endereço permanente.
3. Alterações no NetworkManager podem afetar o retorno da rede após o boot.
4. Vale preservar acesso local durante mudanças que possam derrubar o SSH.
5. Medir o uso real de recursos é mais útil que assumir que o hardware é insuficiente.

## Resultado

| Item | Estado |
|---|---|
| Debian instalado e atualizado na sessão | **CONFIRMADO** |
| Boot sem GNOME automático | **CONFIRMADO** |
| SSH ativo e habilitado | **CONFIRMADO** |
| SSH após reinício, sem login local | **CONFIRMADO** |
| Rede Ethernet com ICS funcional durante sessões | **CONFIRMADO** |
| Internet do Wyse automaticamente estável após reinício | **PENDENTE DE VALIDAÇÃO** |
| Rede doméstica estável independente do Windows | **PLANEJADO** |

**Próximo assunto documentado:** instalação oficial de Docker Engine/Compose e ciclo completo de um container leve, no [marco M1](M1-primeiro-experimento-docker.md).
