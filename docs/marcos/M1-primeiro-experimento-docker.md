# HomeLab — M1: primeiro experimento com Docker

**Registro elaborado em:** 16/10/2026  
**Equipamento:** Dell Wyse 7020  
**Sistema:** Debian 12 (Bookworm), arquitetura `amd64`  
**Objetivo:** instalar Docker Engine/Compose pelo repositório oficial, executar containers de teste e verificar o consumo de recursos, sem publicar portas ou manter serviços persistentes.

> **Escopo do resultado:** os experimentos de containers foram concluídos. O marco M1 mais amplo ainda requer validação de reinício/retorno do Docker e registro do comportamento da conectividade. As medições são instantâneos, não testes de carga.

## 1. Situação de partida

- **CONFIRMADO:** acesso por SSH a partir do Windows, com Debian 12 atualizado e kernel `6.1.0-53-amd64` verificado em sessão anterior.
- **CONFIRMADO:** GNOME não inicia automaticamente; modo texto é o alvo padrão de boot (`multi-user.target`).
- **CONFIRMADO:** conexão temporária Windows → Ethernet → Wyse, usando compartilhamento de conexão (ICS).
- **PENDENTE DE VALIDAÇÃO:** a internet do Wyse nem sempre retorna após reinícios. Em dois episódios, foi preciso desativar e reativar o compartilhamento na interface Wi-Fi do Windows. Isso pode interromper temporariamente o SSH.
- **DECISÃO:** usar Docker Engine e Compose diretamente, sem CasaOS nesta fase.

## 2. Instalação e versões observadas

O repositório oficial do Docker foi configurado em `/etc/apt/sources.list.d/docker.sources`, para `bookworm/stable/amd64`, com assinatura por `/etc/apt/keyrings/docker.asc`. A chave teve sua impressão digital conferida anteriormente:

`9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`

O `sudo apt update` baixou o índice do Docker sem erro de GPG. Em seguida, a instalação foi simulada e executada:

```bash
apt-get -s install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Resultado observado:** 13 novos pacotes, nenhum removido, download de 111 MB e previsão de 439 MB adicionais instalados. O APT configurou os pacotes sem erros aparentes e habilitou `docker.service`, `docker.socket` e `containerd.service` para inicialização.

| Componente | Versão registrada |
|---|---|
| Docker Engine | 29.9.1 |
| Docker Compose | v5.6.0 |
| Containerd | 2.4.2 |
| Docker Buildx | 0.38.0 |

O comando `systemctl is-active docker` retornou `active`. O comando `docker compose version` retornou `Docker Compose version v5.6.0`.

## 3. Teste rápido: hello-world

```bash
sudo docker run --rm hello-world
```

**Evidência:** a imagem foi baixada do Docker Hub (`amd64`) e a execução apresentou a mensagem:

```text
Hello from Docker!
This message shows that your installation appears to be working correctly.
```

**Interpretação:** o cliente conseguiu contatar o daemon; o daemon baixou a imagem, criou e executou o container, e a saída retornou ao terminal. O parâmetro `--rm` removeu o container após o encerramento. A imagem continuou armazenada.

## 4. Teste controlado: Alpine Linux

Iniciou-se um container leve, sem volumes, sem publicação de portas e sem política de reinício automático:

```bash
sudo docker run -d --name teste alpine:3.22 sleep infinity
```

O Docker baixou a imagem e retornou um identificador de container.

```bash
sudo docker ps
```

**Evidência:** imagem `alpine:3.22`, nome `teste`, processo `sleep infinity`, status `Up 36 seconds`, campo `PORTS` vazio.

```bash
sudo docker stats --no-stream teste
```

| Indicador do container | Medição observada |
|---|---:|
| CPU | 0,00% |
| RAM | 328 KiB (aprox. 0,32 MiB) |
| Percentual de RAM | 0,01% |
| PIDs | 1 |
| Rede | 3,27 kB recebidos / 126 B enviados |
| I/O de blocos | 0 B / 0 B |

**Nota:** `5.242 GiB` era o limite mostrado pelo Docker, não uma reserva de RAM para o container. O teste consistiu em um processo ocioso; esses números não representam o consumo de uma aplicação real.

O ciclo de encerramento e limpeza foi executado:

```bash
sudo docker stop teste
sudo docker rm teste
sudo docker ps -a
```

**Evidência:** os comandos de parada e remoção retornaram `teste`; `docker ps -a` exibiu somente o cabeçalho da tabela, sem containers registrados. A imagem Alpine pode permanecer armazenada para reutilização.

## 5. Recursos do host

| Indicador | Antes do Docker | Após instalar o Docker |
|---|---:|---:|
| RAM usada (`free -h`) | 535 MiB | 642 MiB |
| RAM disponível | 4,7 GiB | 4,6 GiB |
| Swap em uso | 0 B | 0 B |
| Disco raiz usado (`df -h /`) | 5,8 GB | 6,2 GB |
| Disco raiz livre | 22 GB | 21 GB |

**Interpretação:** há uma diferença de 107 MiB de RAM usada entre as medições, mas não é possível atribuir toda essa diferença exclusivamente ao Docker. Os valores de disco são arredondados pelo `df`. O armazenamento livre de 21 GB foi observado **antes do download do Alpine**; não há nova medição consolidada após o teste.

Antes de baixar o Alpine, `sudo docker system df` apresentou 1 imagem (`hello-world`, 36,94 kB na coluna `SIZE`), 0 containers, 0 volumes e 0 cache de build. Não foi feita uma nova medição de `docker system df` após o teste Alpine.

## 6. Resultado por situação

| Aspecto | Situação |
|---|---|
| Repositório APT oficial Docker | **CONFIRMADO** |
| Instalação do Docker Engine/CLI/Buildx/Compose | **CONFIRMADO** |
| Serviço Docker ativo na sessão | **CONFIRMADO** |
| Download e execução de `hello-world` | **CONFIRMADO** |
| Container Alpine ativo e medido | **CONFIRMADO** |
| Parada, remoção e lista vazia de containers | **CONFIRMADO** |
| Docker volta a operar após reiniciar o Wyse | **PENDENTE DE VALIDAÇÃO** |
| Internet do Wyse volta automaticamente após reinício | **PENDENTE DE VALIDAÇÃO** |
| Implantação de serviços permanentes | **PLANEJADO / NÃO EXECUTADO** |
| CasaOS, NAS, Minecraft, monitoramento | **ADIADO / PLANEJADO, SEM INSTALAÇÃO NESTE MARCO** |

## 7. Lições e próximos passos

1. **Imagem não é container:** as imagens `hello-world` e Alpine foram baixadas; o container é a instância criada a partir de uma imagem.
2. **`--rm` remove a instância automaticamente:** por isso o `hello-world` não deixou container registrado.
3. **`docker ps` e `docker ps -a` respondem a perguntas diferentes:** o primeiro lista containers em execução; o segundo inclui os parados.
4. **Um container ocioso não prova capacidade para cargas maiores:** a medição de 328 KiB não valida NAS, aplicações com banco de dados, Minecraft ou um conjunto amplo de serviços.
5. **Operação e rede são questões distintas:** o Docker funcionou durante a sessão, mas a dependência do ICS do Windows ainda precisa ser resolvida.

**Próxima ação recomendada (em sessão supervisionada):** testar reinicialização e retorno do serviço Docker, **com monitor e teclado locais disponíveis**, observando também se SSH e conectividade externa voltam sem intervenção. Não iniciar esse teste sem possibilidade de recuperação local.

**Depois:** atualizar `02_HomeLab_Estado_Atual.md` com as medições recentes, as validações realizadas e a pendência de ICS; só então escolher o próximo serviço leve de laboratório.

## Referência técnica

- Docker — [Instalação do Engine no Debian](https://docs.docker.com/engine/install/debian/)
- Docker — [Introdução aos containers](https://docs.docker.com/get-started/docker-concepts/the-basics/what-is-a-container/)

---

**Critério de portfólio:** este registro documenta somente procedimentos executados e saídas efetivamente observadas; não reivindica alta disponibilidade, operação pós-reboot validada, monitoramento contínuo nem serviço permanente em produção.
