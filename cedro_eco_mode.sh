#!/bin/bash
# cedro_eco_mode.sh — confina TODO o sistema aos E-cores da CPU (economia de energia).
#
# Topologia é DETECTADA em tempo real via /sys/devices/cpu_core/cpus e
# /sys/devices/cpu_atom/cpus — exposição nativa do kernel (Linux 5.16+) para
# CPUs híbridas Intel (Alder Lake e mais novas), sem parsing de lscpu nem
# valores fixos. Isso é o que torna este script portável entre máquinas
# diferentes: cada uma detecta os próprios ranges de P-cores/E-cores.
#
# Usa `systemctl set-property --runtime system.slice user.slice AllowedCPUs=...`
# (SEM sudo — ver polkit/49-cedro-eco-mode.rules) — o cgroup raiz de verdade
# (-.slice) NÃO tem cpuset.cpus gravável (invariante do kernel: a raiz sempre
# vê todos os cores), então miramos os dois filhos diretos que cobrem
# praticamente tudo (serviços + sessões de usuário). --runtime = NÃO
# sobrevive a reboot, sem drop-in permanente. Reversível a qualquer momento
# com `off`.
#
# Uso: cedro_eco_mode.sh on|off|status [--execute]
#   Sem --execute, on/off só imprimem o comando (dry-run).

set -euo pipefail

detect_topology() {
    if [[ -r /sys/devices/cpu_core/cpus && -r /sys/devices/cpu_atom/cpus ]]; then
        PCORES=$(cat /sys/devices/cpu_core/cpus)
        ECORES=$(cat /sys/devices/cpu_atom/cpus)
    else
        echo "ERRO: esta CPU nao expoe /sys/devices/cpu_core e /sys/devices/cpu_atom." >&2
        echo "Isso significa que nao e uma CPU hibrida Intel (Alder Lake ou mais nova)" >&2
        echo "com P-cores/E-cores distintos, ou o kernel e anterior ao 5.16." >&2
        echo "Modo eco nao tem o que fazer aqui: nao ha E-cores para confinar o sistema." >&2
        exit 1
    fi
    ALLCORES=$(cat /sys/devices/system/cpu/online)
}

usage() { echo "Uso: $0 on|off|status [--execute]" >&2; exit 2; }

[[ $# -ge 1 ]] || usage
action="$1"; shift || true
execute=0
[[ "${1:-}" == "--execute" ]] && execute=1

run() {
    if (( execute )); then
        "$@"
    else
        echo "[dry-run] $*"
        echo "[dry-run] use --execute para aplicar de fato"
    fi
}

case "$action" in
    on)
        detect_topology
        echo "Restringindo o sistema inteiro aos E-cores ($ECORES). P-cores ($PCORES) ficam livres/ociosos."
        run systemctl set-property --runtime system.slice "AllowedCPUs=$ECORES"
        run systemctl set-property --runtime user.slice "AllowedCPUs=$ECORES"
        ;;
    off)
        detect_topology
        echo "Removendo restricao — sistema volta a usar todos os cores ($ALLCORES)."
        run systemctl set-property --runtime system.slice "AllowedCPUs=$ALLCORES"
        run systemctl set-property --runtime user.slice "AllowedCPUs=$ALLCORES"
        ;;
    status)
        detect_topology
        cur_sys=$(systemctl show -p AllowedCPUs --value system.slice 2>/dev/null)
        cur_usr=$(systemctl show -p AllowedCPUs --value user.slice 2>/dev/null)
        is_full() { [[ -z "$1" || "$1" == "$ALLCORES" ]]; }
        if is_full "$cur_sys" && is_full "$cur_usr"; then
            echo "Modo eco: DESLIGADO (sem restricao, todos os cores disponiveis: $ALLCORES)"
        else
            echo "Modo eco: LIGADO — system.slice AllowedCPUs=$cur_sys | user.slice AllowedCPUs=$cur_usr"
        fi
        ;;
    *) usage ;;
esac
