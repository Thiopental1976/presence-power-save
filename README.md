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
janela de 10 minutos (ajustável via `PRESENCE_ABSENCE_WINDOW_S` no env, útil
pra encurtar durante teste em modo observador) é uma carência que protege
*só* o lado do celular (sinal de rádio pode cair por um instante) — não
protege o lado da tela.

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

**Limite conhecido**: o sinal de "sessão remota ativa" confia em qualquer
conexão TCP estabelecida na porta do RustDesk que ultrapasse o limiar de
`bytes_received` — não em uma sessão *autenticada*. Numa máquina exposta a
uma rede não confiável (sem VPN/Tailscale na frente), tráfego de
varredura/abuso nessa porta poderia, em teoria, ser lido como presença e
manter o sistema em energia total. Nesta implantação a porta só é
alcançável via Tailscale, o que fecha essa lacuna na prática — mas vale
como aviso para quem for adaptar isto rodando com a porta exposta direto na
internet.

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
ln -s "$(pwd)/cedro_eco_mode.sh"        ~/cedro_eco_mode.sh
ln -s "$(pwd)/cedro-presence.service"   ~/.config/systemd/user/cedro-presence.service

# Passo único, com root: autoriza `systemctl set-property` em system.slice/
# user.slice sem senha interativa (só essa ação, só essas duas units — ver
# comentário no arquivo da regra). Sem isto o daemon não consegue aplicar o
# modo eco, porque roda sem terminal e nunca chama sudo.
#
# Use `install`, não `cp`: polkitd roda como um usuário de sistema próprio
# (não root) e precisa conseguir LER o arquivo. Um `sudo cp` a partir de um
# diretório com permissão restrita (ex.: clone em pasta 0770) pode herdar o
# umask de root e sair 0640 — ilegível pro polkitd, com a regra falhando em
# silêncio (só aparece em `journalctl -u polkit` como "Error loading script").
sudo install -m 0644 -o root -g root polkit/49-cedro-eco-mode.rules /etc/polkit-1/rules.d/
sudo systemctl restart polkit
# Confirme que carregou: a linha abaixo NÃO deve aparecer.
sudo journalctl -u polkit -n 20 --no-pager | grep -i "error loading" && echo "regra NAO carregou, revise permissoes" || echo "regra carregada OK"

systemctl --user daemon-reload
systemctl --user enable --now cedro-presence.service

cedro_presence_ctl.sh status
cedro_presence_ctl.sh log 50
```

A unit sobe com `--execute` já ligado. Para rodar em modo observador
primeiro (recomendado: alguns dias, conferindo o log antes de deixar a
automação mexer em CPU de verdade), edite a unit e remova a flag.

O único ponto que efetivamente chama `systemctl set-property` é
`cedro_eco_mode.sh on|off|status [--execute]` — `on` restringe o sistema
aos E-cores, `off` remove a restrição. A topologia P-core/E-core é
**detectada em tempo real** via `/sys/devices/cpu_core/cpus` e
`/sys/devices/cpu_atom/cpus` (exposição nativa do kernel 5.16+ pra CPUs
híbridas Intel, Alder Lake em diante) — nada fixo no código, então o mesmo
script funciona em qualquer máquina híbrida sem editar nada. Numa CPU sem
essa distinção (a maioria das AMD, Intel pré-Alder-Lake), o script recusa
rodar com um erro explícito — não há E-cores pra confinar.

Antes de confiar nesses ranges, o script faz uma validação cruzada por
`cpuinfo_max_freq`: confirma que o grupo identificado como P-cores tem
frequência máxima maior que o grupo identificado como E-cores. Se não
tiver, aborta em vez de arriscar confinar o lado de alta potência por um
nome de grupo sysfs enganoso numa topologia atípica. De quebra, identifica
e loga qual CPU específica é o núcleo de maior potência entre os P-cores
(o "favorito" do Turbo Boost Max 3.0, quando existe).

Nem o daemon nem `cedro_eco_mode.sh` chamam `sudo` — a autorização vem de
uma regra polkit (`polkit/49-cedro-eco-mode.rules`) escopada só pra
`set-property` em `system.slice`/`user.slice`, restrita a quem já está no
grupo `sudo`. Isso existe porque o daemon roda como `systemd --user` sem
terminal: um `sudo` interativo travaria esperando senha que nunca chega, e
um NOPASSWD amplo em `/etc/sudoers.d` seria um privilégio bem mais largo
que o necessário.

**Risco residual da regra polkit** (aceito conscientemente, não é um bug):
ela autoriza qualquer verbo `set-property` nessas duas units, não só
`AllowedCPUs=...` — um processo malicioso rodando como o próprio usuário
(já teria que estar nessa posição pra explorar isto) poderia, por exemplo,
setar `MemoryMax=32M` ou `IPAddressDeny=any` sem senha, e sem o `--runtime`
usado por este projeto isso persistiria além do reboot. É uma superfície de
negação-de-serviço (nenhum caminho de execução de código), escopada a duas
units específicas — bem mais estreita que um NOPASSWD total, mas não é
"só liga/desliga E-cores". Quem adaptar isto pra outro uso deve manter essa
restrição em mente.

`cedro_presence_ctl.sh pause` / `resume` ligam/desligam a automação sem
parar o serviço (kill-switch em arquivo, `~/.cedro-sched-disable`).

## Requisitos

Python 3, `python3-dbus`, `python3-gi`, BlueZ, `xset`, `ss` (iproute2).
Todos padrão em qualquer desktop Linux moderno — nada instalado via pip.
