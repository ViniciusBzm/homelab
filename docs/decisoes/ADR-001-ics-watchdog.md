# ADR-001 — ICS do Windows com persistência e watchdog

**Data:** 26/11/2026 · **Estado:** Aceita

## Contexto
O servidor só tem internet pelo ICS (Wi-Fi → Ethernet) do PC. Depois de reinícios, o SSH funcionava mas a internet não, e só desligar e religar o compartilhamento resolvia. Diagnóstico: faltava `EnableRebootPersistConnection` (KB4055559), o serviço estava em Manual, e o ICS ficava "configurado sem NAT/DNS".

## Decisão
- Corrigir a persistência com o valor no Registro e o serviço em Automático.
- Criar um watchdog agendado como SYSTEM que testa o **efeito** (o DNS do ICS responde) e reaplica o compartilhamento.
- O watchdog ignora os adaptadores `vEthernet` (Hyper-V/WSL) e só age se o PC tiver internet.

## Alternativas
- **Ligar o Wyse direto no roteador:** é a melhor solução, mas depende de um cabo ou ponto de rede indisponível agora. Fica PLANEJADO.
- **Bridge de rede no Windows:** muda a rede do PC e arrisca a conexão principal.
- **Comprar um adaptador ou roteador:** fora do orçamento.

## Consequências
O servidor continua dependendo do PC ligado. A tarefa reaplica o ICS em até 5 min. Em 27/11/2026, o ICS voltou sozinho depois do boot do PC, sem precisar do watchdog. O monitor "ICS do Windows" no Uptime Kuma alerta se o compartilhamento parar de funcionar.
