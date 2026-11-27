# ADR-006 — Sudo continua exigindo senha

**Data:** 26/11/2026 · **Estado:** Aceita

## Contexto
O objetivo é administração direta por um agente, com o mínimo de intervenção. As opções avaliadas foram `NOPASSWD`, um ticket de sudo global estendido e o grupo `docker`.

## Decisão
Nenhuma delas. A chave SSH do agente fica num arquivo sem frase-senha; se o sudo não pedisse senha (ou se o grupo `docker` desse root na prática), quem obtivesse essa chave teria root. A tentativa de estender o ticket do sudo também foi barrada pela política de permissões do agente, por reduzir a supervisão humana.

## Consequências
Tarefas de root são agrupadas num **script revisado** e executadas numa janela visível onde a pessoa digita a senha uma vez. Tudo o que não precisa de root (validações, leitura de estado, testes de rede e configuração das interfaces web) é feito sem senha.
