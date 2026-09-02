# Retrospectiva — Presence Power Save

## Objetivos

- Ligar/desligar automaticamente a restrição de E-cores conforme a presença
  física do operador, detectada por Bluetooth e/ou USB do celular.
- Presença sozinha não bastava: precisava combinar com atividade local
  (tela ligada), senão o celular por perto com a máquina ociosa mantinha
  energia total sem necessidade.
- Depois, um requisito surgiu no meio do design: uma sessão de acesso
  remoto realmente em uso também deveria valer como presença — trabalho
  pesado solicitado de longe não pode ser estrangulado só porque o
  operador não está fisicamente na sala.
- Design feito por um agente separado (papel de arquiteto), implementação
  por outro — divisão deliberada para separar decisão de arquitetura de
  execução de código.

## O que funcionou

- **Medir antes de decidir.** Cada decisão de arquitetura (fonte de
  ociosidade, sinal de sessão remota ativa) só foi fechada depois de rodar
  o comando de verdade no sistema e olhar o número, não por dedução
  teórica. Isso pegou um caso real: a primeira leitura de `xprintidle`
  parecia "sinal quebrado" e só depois, com uma segunda medição
  controlada, ficou claro que era "sinal ambíguo quanto à origem" — a
  interpretação inicial estava errada, não a medição.
- **Reusar a infraestrutura existente em vez de recriar.** O único
  mecanismo de efeito é um script que já existia e já era confiável
  (`cedro_eco_mode.sh`); o daemon novo nunca chama `systemctl
  set-property` diretamente. Isso manteve a superfície de risco pequena.
- **Convergir contra o estado real, não contra uma variável interna.**
  Qualquer intervenção manual (ligar/desligar o modo eco na mão) se
  resolve sozinha no próximo ciclo, sem o daemon "brigar" com o operador
  ou ficar dessincronizado.
- **Falha aberta como princípio único, aplicado em todo lugar.** Erro de
  leitura de tela, adaptador Bluetooth sumindo do barramento, daemon
  travado — todos os casos de falha convergem pro mesmo lado (energia
  total), exceto um: erro ao medir a sessão remota fica INDETERMINADO ⇒
  inativo, porque nesse caso específico "falhar aberto" significaria
  prender a máquina em energia total pra sempre sem ninguém perceber, o
  que é pior do que o custo de perder uns segundos de prioridade.
- **Separar quem desenha de quem implementa.** O agente de design
  encontrou o problema do RustDesk quebrando a métrica de ociosidade só
  porque investigou o sistema de verdade antes de propor algo — algo que
  só aconteceu por causa da separação de papéis, que forçou a explicitar
  premissas em vez de deixá-las implícitas dentro de uma única passada.

## O que custou mais do que devia / erros no caminho

- **Sinal remoto ativo entrou tarde.** O requisito de "sessão remota
  realmente ativa conta como presença" só apareceu depois da primeira
  versão do design estar pronta, obrigando uma segunda rodada de
  investigação e uma revisão não-trivial da máquina de estados (o sinal
  entrou nos dois lados da regra, não só num OR simples). Se tivesse sido
  levantado antes, a primeira versão já teria saído correta.
- **A primeira interpretação do `xprintidle` (seção de ociosidade) estava
  parcialmente errada** — foi corrigida na rodada seguinte, mas a decisão
  final (DPMS em vez de `xprintidle`) não mudou; só o motivo documentado
  mudou. Vale registrar para quem for mexer nisso depois: o `xprintidle`
  não é "ruidoso", é "sem procedência" — mistura input local com XTEST
  injetado por qualquer processo, incluindo automação da própria casa.
- **Limiar de bytes calibrado numa amostra pequena.** A separação medida
  entre sessão parada e sessão ativa foi grande (dezenas de vezes), o que
  dá confiança na direção da decisão, mas é uma calibração de uma sessão
  específica, não um valor validado em produção por semanas. O daemon
  loga a taxa bruta durante o burn-in exatamente para permitir recalibrar
  com dados reais em vez de behavior assumido.
- **Trade-off deixado em aberto, de propósito:** se o operador disparar um
  job pesado remotamente e desconectar em seguida, todos os sinais somem e
  a máquina volta pro modo econômico dentro da janela de tolerância —
  inclusive estrangulando o próprio job que acabou de ser pedido. Detecção
  de presença não é a ferramenta certa para "segurar energia total durante
  um job específico"; a saída (kill-switch manual antes de desconectar, ou
  um arquivo de hold com TTL renovado pelo próprio job) foi discutida e
  deliberadamente **não** implementada — ainda é especulativa até os logs
  do burn-in mostrarem que o caso realmente acontece na prática.
