#!/usr/bin/env python3
"""cedro_presence_daemon.py — Presence Power Save.

Alterna o servidor entre energia total (todos os cores) e economia (só
E-cores) com base em três sinais:

  - Bluetooth do celular conectado (evento D-Bus/BlueZ, latência ~ms)
  - USB do celular presente (poll leve em sysfs)
  - Sessão RustDesk efetivamente em uso, não apenas aberta (taxa de
    bytes recebidos no socket, canal de input)

Regra (arquitetura desenhada pelo Fable 5, 02/09/2026 — ver README.md):

    alvo = FULL  <=>  (tela ligada OU rustdesk ativo)
                      E (presente OU ausente há menos de 10 min)

Presença do celular é NECESSÁRIA mas não SUFICIENTE: com a tela apagada
e ocioso, cai pra economia mesmo com o celular por perto. RustDesk
realmente ativo conta como presença E como atividade ao mesmo tempo —
um operador remoto não depende do monitor físico estar aceso.

Esse daemon NUNCA mexe em AllowedCPUs diretamente. O único mecanismo de
efeito é `cedro_eco_mode.sh on/off --execute` — mesmo script usado pelo
toggle manual e pelo cedro_eco_watchdog.sh. Convergência é sempre feita
comparando com o estado REAL do cgroup (`systemctl show AllowedCPUs`),
nunca com uma variável interna — assim uma intervenção manual não
deixa o daemon dessincronizado.

Config obrigatória via variável de ambiente (ver presence.env.example):
  PRESENCE_BT_MAC      MAC do celular pareado, ex: AA:BB:CC:DD:EE:FF
  PRESENCE_USB_VENDOR  idVendor USB de 4 hex do celular, ex: 04e8

Convenção da casa: sem --execute, roda em modo OBSERVADOR — mede tudo,
decide tudo, loga o que faria, mas nunca chama sudo. Recomendado rodar
alguns dias em observador antes de ligar --execute de verdade.
"""
import argparse
import glob
import os
import re
import socket
import subprocess
import sys
import time
from pathlib import Path

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

HOME = Path.home()
ECO_MODE_SH = HOME / "cedro_eco_mode.sh"
KILL_SWITCH = HOME / ".cedro-sched-disable"       # convenção da casa, reusada sem alterar semântica
WATCHDOG_ARMED = HOME / ".cedro-eco-armed"        # do cedro_eco_watchdog.sh — só lido, nunca escrito
STATE_FILE = HOME / ".cedro-presence-state"
LOG_FILE = HOME / "cedro_presence.log"
LOG_MAX_BYTES = 5 * 1024 * 1024

ABSENCE_WINDOW_S = int(os.environ.get("PRESENCE_ABSENCE_WINDOW_S", "600"))
# 10 min por padrão — carência SÓ do lado do celular, nunca do lado da tela.
# Ajustável via PRESENCE_ABSENCE_WINDOW_S no env (ex.: 30 pra testar em modo
# observador sem esperar 10min por ciclo) sem tocar no valor de produção.
TICK_SECONDS = 10                 # poll de USB/tela/RustDesk. BT é event-driven, não depende disto.

BLUEZ = "org.bluez"
OM_IFACE = "org.freedesktop.DBus.ObjectManager"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
DEVICE_IFACE = "org.bluez.Device1"

# Portas TCP do RustDesk (ID/registro/conexão direta). Fonte autoritativa é a
# PORTA, não o nome do processo: o `--service` roda como root e o `ss` do
# usuário não resolve nome de processo alheio. Ver retrospectiva.md.
RUSTDESK_PORTS = {"21115", "21116", "21117", "21118", "21119"}
RUSTDESK_RX_THRESHOLD_PER_TICK = 512  # bytes, calibrado: piso de keepalive medido = 16B/2s (~80B/tick)


def log(msg):
    linha = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    try:
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > LOG_MAX_BYTES:
            LOG_FILE.rename(LOG_FILE.with_name(LOG_FILE.name + ".old"))
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(linha + "\n")
    except OSError:
        pass
    print(linha, flush=True)  # também vai pro journal (SyslogIdentifier=cedro-presence)


def _child_env(**extra):
    """Ambiente para subprocessos filhos, SEM NOTIFY_SOCKET.

    Sem isto, qualquer subprocesso (xset, ss, systemctl, cedro_eco_mode.sh)
    herda a variável e o systemd às vezes atribui a notificação de watchdog
    ao PID do filho em vez do PID principal — visto na prática como "Got
    notification message from PID X, but reception only permitted for main
    PID Y" no journal, mesmo com NotifyAccess=main. sd_notify() é a ÚNICA
    função que deve falar com o NOTIFY_SOCKET.
    """
    env = dict(os.environ)
    env.pop("NOTIFY_SOCKET", None)
    env.update(extra)
    return env


def sd_notify(msg):
    addr = os.environ.get("NOTIFY_SOCKET")
    if not addr:
        return
    if addr.startswith("@"):
        addr = "\0" + addr[1:]
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
            s.connect(addr)
            s.sendall(msg.encode())
    except OSError:
        pass


def write_state(**kv):
    try:
        tmp = STATE_FILE.with_name(STATE_FILE.name + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            for k, v in kv.items():
                f.write(f"{k}={v}\n")
        tmp.rename(STATE_FILE)
    except OSError:
        pass


def usb_present(vendor_id):
    vendor_id = vendor_id.strip().lower()
    for p in glob.glob("/sys/bus/usb/devices/*/idVendor"):
        try:
            with open(p, encoding="ascii") as f:
                if f.read().strip().lower() == vendor_id:
                    return True
        except OSError:
            continue
    return False


_SCREEN_RE = re.compile(r"Monitor is (\w+)")


def screen_on():
    """Estado do DPMS via `xset q` — leitura PURA, nunca gera evento X.

    NUNCA trocar isto por xprintidle, xdotool ou `xset dpms force`: qualquer
    coisa que injete evento X reseta o próprio sinal que estamos lendo (foi
    o que aconteceu com o xprintidle desta casa — media 6ms de ociosidade
    com o operador provadamente ausente, porque uma sessão RustDesk estava
    injetando XTEST). `xset q` apenas consulta; não pode se auto-enganar.
    Falha de leitura ou DPMS desabilitado = fail-open (assume tela ligada).
    """
    env = _child_env()
    env.setdefault("DISPLAY", ":0")
    try:
        out = subprocess.run(["xset", "q"], env=env, capture_output=True,
                              text=True, timeout=5).stdout
    except (subprocess.TimeoutExpired, OSError):
        return True
    m = _SCREEN_RE.search(out)
    if not m:
        return True
    return m.group(1) == "On"


def _split_hostport(col):
    addr, _, port = col.rpartition(":")
    return addr, port


def rustdesk_sockets():
    """Sockets TCP ESTAB que parecem ser sessão RustDesk (porta 21115-21119,
    peer não-loopback), com bytes_received (canal de INPUT, cliente->servidor)
    extraído do tcp_info. bytes_sent é vídeo e fica alto mesmo parado — não
    serve como sinal (medido: ~24KB/2s em repouso). Retorna None se `ss`
    falhar (indeterminado; o chamador decide o fail-open)."""
    try:
        out = subprocess.run(["ss", "-tieH", "state", "established"], env=_child_env(),
                              capture_output=True, text=True, timeout=5).stdout
    except (subprocess.TimeoutExpired, OSError):
        return None
    linhas = out.splitlines()
    sessoes = []
    i = 0
    while i < len(linhas):
        cab = linhas[i]
        if not cab or cab[0] in " \t":
            i += 1
            continue
        cols = cab.split()
        info = ""
        if i + 1 < len(linhas) and linhas[i + 1][:1] in (" ", "\t"):
            info = linhas[i + 1]
            i += 2
        else:
            i += 1
        if len(cols) < 4:
            continue
        local_addr, local_port = _split_hostport(cols[2])
        peer_addr, peer_port = _split_hostport(cols[3])
        if local_port not in RUSTDESK_PORTS and peer_port not in RUSTDESK_PORTS:
            continue
        if peer_addr in ("127.0.0.1", "::1", "[::1]"):
            continue
        m = re.search(r"bytes_received:(\d+)", info)
        if not m:
            continue
        sessoes.append({
            "key": f"{local_addr}:{local_port}-{peer_addr}:{peer_port}",
            "peer": f"{peer_addr}:{peer_port}",
            "bytes_received": int(m.group(1)),
        })
    return sessoes


class BluetoothWatcher:
    """Observa a propriedade DINÂMICA `Connected` de org.bluez.Device1.

    `Paired` NUNCA é o sinal certo aqui: um celular pareado fica `Paired:
    yes` pra sempre, esteja o dono na sala ou a 400km. Confirmado neste
    servidor em 02/09/2026: Paired=true, Connected=false, com o Rodrigo
    comprovadamente ausente. Só `Connected` responde "ele está aqui agora".
    """

    def __init__(self, mac, on_change):
        self.mac = mac.strip().upper()
        self.on_change = on_change
        self.connected = False
        self.device_path = None
        self.bus = dbus.SystemBus()
        self.bus.add_signal_receiver(
            self._interfaces_added, dbus_interface=OM_IFACE,
            signal_name="InterfacesAdded", bus_name=BLUEZ)
        self.bus.add_signal_receiver(
            self._interfaces_removed, dbus_interface=OM_IFACE,
            signal_name="InterfacesRemoved", bus_name=BLUEZ)
        self.bus.watch_name_owner(BLUEZ, self._bluez_owner_changed)
        self._find_device()

    def _find_device(self):
        # Nunca hardcodar /org/bluez/hci0/...: o adaptador pode virar hci1
        # depois de um replug/reset. Resolve pelo endereço via ObjectManager.
        try:
            om = dbus.Interface(self.bus.get_object(BLUEZ, "/"), OM_IFACE)
            objetos = om.GetManagedObjects()
        except dbus.DBusException as e:
            log(f"sinal: bluez indisponivel ao resolver device ({e})")
            self.device_path = None
            return
        for path, ifaces in objetos.items():
            dev = ifaces.get(DEVICE_IFACE)
            if dev and str(dev.get("Address", "")).upper() == self.mac:
                self.device_path = str(path)
                self._subscribe(path)
                novo = bool(dev.get("Connected", False))
                if novo != self.connected:
                    self.connected = novo
                return
        self.device_path = None

    def _subscribe(self, path):
        self.bus.add_signal_receiver(
            self._properties_changed, dbus_interface=PROPS_IFACE,
            signal_name="PropertiesChanged", path=path, bus_name=BLUEZ)

    def _properties_changed(self, interface, changed, invalidated, **kwargs):
        if interface != DEVICE_IFACE or "Connected" not in changed:
            return
        novo = bool(changed["Connected"])
        if novo != self.connected:
            self.connected = novo
            log(f"sinal: bt {'conectou' if novo else 'desconectou'}")
            self.on_change()

    def _interfaces_added(self, path, ifaces):
        dev = ifaces.get(DEVICE_IFACE)
        if dev and str(dev.get("Address", "")).upper() == self.mac:
            self.device_path = str(path)
            self._subscribe(path)
            novo = bool(dev.get("Connected", False))
            if novo != self.connected:
                self.connected = novo
                log("sinal: bt device reapareceu no bus")
                self.on_change()

    def _interfaces_removed(self, path, ifaces):
        if path == self.device_path and DEVICE_IFACE in ifaces:
            self.device_path = None
            if self.connected:
                self.connected = False
                log("sinal: bt device sumiu do bus (adaptador caiu?)")
                self.on_change()

    def _bluez_owner_changed(self, new_owner):
        if new_owner:
            log("sinal: bluetoothd voltou ao bus, re-resolvendo device")
            self._find_device()
        else:
            self.device_path = None
            if self.connected:
                self.connected = False
                log("sinal: bluetoothd sumiu do bus")
                self.on_change()


class PresenceDaemon:
    def __init__(self, bt_mac, usb_vendor, execute):
        self.usb_vendor = usb_vendor
        self.execute = execute

        self.usb = False
        self.screen = True          # fail-open até a primeira medição real
        self.rd_active = False
        self.rd_peer = None
        self.rd_prev = {}           # key -> bytes_received da última amostra

        self.absent_since = None
        self.last_applied = None    # último alvo que ESTE daemon efetivamente aplicou
        self.passive = False        # cedendo a kill-switch ou ao watchdog

        self.bt_watcher = BluetoothWatcher(bt_mac, self._on_bt_change)

    @property
    def bt(self):
        return self.bt_watcher.connected

    @property
    def present(self):
        return self.bt or self.usb or self.rd_active

    def _on_bt_change(self):
        self.reevaluate()

    def held_by(self):
        partes = []
        if self.bt:
            partes.append("bluetooth")
        if self.usb:
            partes.append("usb")
        if self.rd_active:
            partes.append("rustdesk")
        if not partes and self._dentro_da_janela():
            partes.append("janela")
        return "+".join(partes) if partes else "-"

    def _dentro_da_janela(self):
        return self.absent_since is not None and (time.time() - self.absent_since) < ABSENCE_WINDOW_S

    def _sample_usb_screen(self):
        novo_usb = usb_present(self.usb_vendor)
        if novo_usb != self.usb:
            self.usb = novo_usb
            log(f"sinal: usb {'apareceu' if novo_usb else 'sumiu'}")

        novo_screen = screen_on()
        if novo_screen != self.screen:
            self.screen = novo_screen
            log(f"sinal: tela {'ligou' if novo_screen else 'apagou'}")

    def _sample_rustdesk(self):
        sessoes = rustdesk_sockets()
        if sessoes is None:
            # `ss` falhou: NÃO fail-open aqui. Um erro de parsing permanente
            # travando em "ativo" prenderia o servidor em FULL pra sempre
            # sem ninguém notar. Os outros sinais continuam mandando.
            if self.rd_active:
                log("sinal: rd indeterminado (falha ao ler sockets) — tratando como inativo")
            self.rd_active = False
            self.rd_peer = None
            return

        vivos = {s["key"] for s in sessoes}
        for key in list(self.rd_prev):
            if key not in vivos:
                del self.rd_prev[key]
                log(f"sinal: rd sessao encerrada ({key.split('-')[-1]})")

        ativo_agora = False
        peer_ativo = None
        for s in sessoes:
            key, rx = s["key"], s["bytes_received"]
            if key not in self.rd_prev:
                # peer novo conectando: conta como atividade imediata —
                # ninguém abre uma sessão RustDesk sem querer usar.
                self.rd_prev[key] = rx
                ativo_agora = True
                peer_ativo = s["peer"]
                log(f"sinal: rd nova sessao ({s['peer']}) — tratando como ativa")
                continue
            delta = rx - self.rd_prev[key]
            self.rd_prev[key] = rx
            if delta > RUSTDESK_RX_THRESHOLD_PER_TICK:
                ativo_agora = True
                peer_ativo = s["peer"]

        if ativo_agora != self.rd_active:
            log(f"sinal: rd {'ativo' if ativo_agora else 'em espera'}"
                + (f" peer={peer_ativo}" if peer_ativo else ""))
        self.rd_active = ativo_agora
        self.rd_peer = peer_ativo if ativo_agora else self.rd_peer

    def estado_real(self):
        def cur(slice_):
            try:
                return subprocess.run(
                    ["systemctl", "show", "-p", "AllowedCPUs", "--value", slice_],
                    env=_child_env(), capture_output=True, text=True, timeout=5,
                ).stdout.strip()
            except (subprocess.TimeoutExpired, OSError):
                return None

        sys_, usr_ = cur("system.slice"), cur("user.slice")
        if sys_ is None or usr_ is None:
            return None
        cheio = os.cpu_count()
        allcores = f"0-{cheio - 1}" if cheio else ""

        def is_full(v):
            return v in ("", allcores)

        return "FULL" if is_full(sys_) and is_full(usr_) else "ECO"

    def _run_eco_mode(self, acao):
        cmd = [str(ECO_MODE_SH), acao] + (["--execute"] if self.execute else [])
        try:
            subprocess.run(cmd, env=_child_env(), capture_output=True, text=True, timeout=15, check=True)
            return True
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, OSError) as e:
            log(f"ERRO: falha ao chamar cedro_eco_mode.sh {acao}: {e}")
            return False

    def reevaluate(self):
        agora = time.time()
        if self.present:
            if self.absent_since is not None:
                log("sinal: janela_cancelada (presenca retomada)")
            self.absent_since = None
        elif self.absent_since is None:
            self.absent_since = agora
            log("sinal: janela_iniciada (10min)")
        elif self._dentro_da_janela() is False and (agora - self.absent_since) < ABSENCE_WINDOW_S + TICK_SECONDS:
            # cruzou o limiar de 10min neste tick
            log("sinal: janela_expirada")

        if KILL_SWITCH.exists():
            if not self.passive:
                log(f"kill-switch presente ({KILL_SWITCH}) — restaurando FULL e entrando em modo passivo")
            if self._run_eco_mode("off"):
                self.last_applied = "FULL"
            self.passive = True
            write_state(alvo="FULL", real=self.estado_real() or "?", held_by="kill-switch",
                        bt=self.bt, usb=self.usb, screen=self.screen, rd_active=self.rd_active,
                        rd_peer=self.rd_peer or "-", mode="passivo(kill-switch)",
                        absent_since=int(self.absent_since) if self.absent_since else "-")
            return

        if WATCHDOG_ARMED.exists():
            if not self.passive:
                log(f"cedro_eco_watchdog armado ({WATCHDOG_ARMED}) — cedendo controle, modo passivo")
            self.passive = True
            write_state(alvo="?", real=self.estado_real() or "?", held_by="watchdog",
                        bt=self.bt, usb=self.usb, screen=self.screen, rd_active=self.rd_active,
                        rd_peer=self.rd_peer or "-", mode="passivo(watchdog)",
                        absent_since=int(self.absent_since) if self.absent_since else "-")
            return

        if self.passive:
            log("saiu do modo passivo — retomando controle normal")
            self.passive = False

        alvo = "FULL" if (self.screen or self.rd_active) and (self.present or self._dentro_da_janela()) else "ECO"
        real = self.estado_real()

        if real is None:
            log("AVISO: nao foi possivel ler estado real via systemctl — mantendo ultima acao")
        elif alvo != real:
            motivo = ("tela_apagada" if not self.screen and not self.rd_active
                       else "bt_conectou" if alvo == "FULL" and self.bt
                       else "rustdesk_ativo" if alvo == "FULL" and self.rd_active
                       else "usb_conectou" if alvo == "FULL" and self.usb
                       else "ausencia_confirmada" if alvo == "ECO"
                       else "janela_de_tolerancia")
            if self._run_eco_mode("off" if alvo == "FULL" else "on"):
                log(f"{real}->{alvo}  bt={'on' if self.bt else 'off'} usb={'on' if self.usb else 'off'} "
                    f"rd={'ativo' if self.rd_active else 'parado'} screen={'on' if self.screen else 'off'} "
                    f"held_by={self.held_by()} motivo={motivo}")
                self.last_applied = alvo

        write_state(
            alvo=alvo, real=real or "?", held_by=self.held_by(),
            bt=self.bt, usb=self.usb, screen=self.screen, rd_active=self.rd_active,
            rd_peer=self.rd_peer or "-", mode="execute" if self.execute else "observador",
            absent_since=int(self.absent_since) if self.absent_since else "-",
            applied_at=int(agora),
        )

    def tick(self):
        self._sample_usb_screen()
        self._sample_rustdesk()
        self.reevaluate()
        sd_notify("WATCHDOG=1")   # sai de dentro do tick da FSM, não de um timer à parte
        return True               # GLib: continuar repetindo

    def start(self):
        self._sample_usb_screen()
        self._sample_rustdesk()
        self.reevaluate()
        sd_notify("READY=1")
        log(f"Presence Power Save iniciado — modo {'execute' if self.execute else 'OBSERVADOR (sem --execute)'}")


def main():
    ap = argparse.ArgumentParser(description="Presence Power Save — governor de cores por presença")
    ap.add_argument("--execute", action="store_true",
                     help="aplica de verdade via cedro_eco_mode.sh; sem isto, só observa e loga")
    args = ap.parse_args()

    bt_mac = os.environ.get("PRESENCE_BT_MAC")
    usb_vendor = os.environ.get("PRESENCE_USB_VENDOR")
    if not bt_mac or not usb_vendor:
        log("FATAL: PRESENCE_BT_MAC e/ou PRESENCE_USB_VENDOR não configurados "
            "(ver presence.env.example e ~/.config/cedro-presence/env)")
        sys.exit(1)

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    daemon = PresenceDaemon(bt_mac, usb_vendor, execute=args.execute)
    daemon.start()

    GLib.timeout_add_seconds(TICK_SECONDS, daemon.tick)
    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
