# Presence Power Save

Governor de P-cores/E-cores para servidores domésticos Linux que alterna
automaticamente entre energia total e modo econômico com base na presença
física do dono da máquina — detectada pelo celular dele via Bluetooth e/ou
USB — combinada com atividade local (tela ligada) ou uma sessão de acesso
remoto (RustDesk) realmente em uso.

Pensado para uma máquina de bancada de operador único: nada aqui reinicia
serviços, mata sessões ou suspende o sistema. O único efeito colateral é
confinar `system.slice`/`user.slice` a um subconjunto de cores via
`systemctl set-property --runtime` — reversível numa linha, e que some
sozinho no próximo boot.

## A regra

```
alvo = FULL  <=>  (tela ligada OU sessão remota realmente ativa)
                  E (celular presente OU ausente há menos de 10 min)
```

Presença do celular é **necessária mas não suficiente**: com a tela apagada
e a máquina ociosa, cai pro modo econômico mesmo com o celular por perto. A
janela de 10 minutos é uma carência que protege *só* o lado do celular
(sinal de rádio pode cair por um instante) — não protege o lado da tela.

Uma sessão de acesso remoto realmente em uso conta como presença *e* como
atividade ao mesmo tempo: quem está operando de longe não depende do
monitor físico estar aceso.

## Como decide "sessão remota realmente em uso"

O jeito óbvio — medir ociosidade local (`xprintidle`, `logind IdleHint`) —
não funciona quando existe uma sessão de controle remoto: o próprio
controle remoto injeta eventos de input (XTEST) que resetam qualquer
contador de ociosidade local, criando um falso "ativo" permanente
independente de haver alguém realmente mexendo.

A saída é medir o input na origem: a taxa de `bytes_received` (canal
cliente→servidor) do socket TCP da sessão remota, comparada com um limiar
calibrado acima do piso de tráfego de keepalive. `bytes_sent` (vídeo,
servidor→cliente) não serve — fica alto mesmo com a sessão parada, porque a
tela de um servidor muda sozinha (relógio, logs, processos).

Para "tela ligada", a fonte é o estado DPMS via `xset q` — uma leitura pura
que não gera nenhum evento X, portanto imune ao mesmo problema de
auto-interferência.

## Arquitetura

- Um daemon único (`cedro_presence_daemon.py`, Python 3 + `dbus`/`gi`,
  sem dependência de pip), loop de eventos GLib.
- Bluetooth é orientado a evento (sinal D-Bus `PropertiesChanged` do BlueZ na
  propriedade `Connected` — nunca `Paired`, que é permanente).
- USB e tela são amostrados por poll leve (sysfs / `xset q`).
- A sessão remota é amostrada via `ss` (estado TCP + `tcp_info`).
- Nenhum sinal aplica nada diretamente — todos convergem numa FSM simples
  que chama um único mecanismo de efeito, comparando sempre contra o estado
  **real** do cgroup antes de agir (idempotência de verdade).
- Failsafe: energia total é o estado seguro por padrão. Se o daemon
  travar, cair, ou nunca ter subido, o sistema tende a ficar em energia
  total, não preso em economia.
- `systemd --user`, `Type=notify` com `WatchdogSec`, para pegar tanto
  crash quanto travamento silencioso (processo vivo mas com o loop
  pendurado).

Ver `retrospectiva.md` para o histórico de decisões e o que foi descartado
no caminho (e por quê).

## Uso

```
cp presence.env.example ~/.config/cedro-presence/env
# edite ~/.config/cedro-presence/env com o MAC Bluetooth e o vendor ID USB do seu aparelho

ln -s "$(pwd)/cedro_presence_daemon.py" ~/cedro_presence_daemon.py
ln -s "$(pwd)/cedro_presence_ctl.sh"    ~/cedro_presence_ctl.sh
ln -s "$(pwd)/cedro-presence.service"   ~/.config/systemd/user/cedro-presence.service

systemctl --user daemon-reload
systemctl --user enable --now cedro-presence.service

cedro_presence_ctl.sh status
cedro_presence_ctl.sh log 50
```

A unit sobe com `--execute` já ligado. Para rodar em modo observador
primeiro (recomendado: alguns dias, conferindo o log antes de deixar a
automação mexer em CPU de verdade), edite a unit e remova a flag.

Depende de um script externo, `cedro_eco_mode.sh`, que é o único ponto que
efetivamente chama `systemctl set-property`. Não está neste repositório
porque é específico da topologia de CPU de cada máquina — a interface
esperada é `cedro_eco_mode.sh on|off|status [--execute]`, onde `on`
restringe o sistema aos E-cores e `off` remove a restrição.

`cedro_presence_ctl.sh pause` / `resume` ligam/desligam a automação sem
parar o serviço (kill-switch em arquivo, `~/.cedro-sched-disable`).

## Requisitos

Python 3, `python3-dbus`, `python3-gi`, BlueZ, `xset`, `ss` (iproute2).
Todos padrão em qualquer desktop Linux moderno — nada instalado via pip.
