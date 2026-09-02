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

# Expande um range tipo "0-15,20" numa lista de numeros de CPU, um por linha.
expand_range() {
    local ranges="$1" part lo hi n
    IFS=',' read -ra parts <<< "$ranges"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            lo=${part%-*}; hi=${part#*-}
            for ((n = lo; n <= hi; n++)); do echo "$n"; done
        else
            echo "$part"
        fi
    done
}

# Maior cpuinfo_max_freq (kHz) entre os CPUs do range dado. Imprime
# "freq cpu1,cpu2,..." — TODOS os CPUs empatados no topo, nao só o primeiro
# encontrado (num 13700K, por ex., os 4 threads dos 2 núcleos "favoritos"
# do Turbo Boost Max 3.0 empatam na frequência máxima, não é só um).
# freq=0 lista="" se nao conseguir ler nenhum — chamador decide o que fazer.
max_freq_khz() {
    local best=0 best_list="" n f v
    while read -r n; do
        f="/sys/devices/system/cpu/cpu$n/cpufreq/cpuinfo_max_freq"
        [[ -r "$f" ]] || continue
        v=$(cat "$f")
        if (( v > best )); then
            best=$v
            best_list="$n"
        elif (( v == best )); then
            best_list="$best_list,$n"
        fi
    done < <(expand_range "$1")
    echo "$best $best_list"
}

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

    # Validacao cruzada por frequencia: nao confia cegamente no nome do grupo
    # sysfs (cpu_core/cpu_atom) — confirma que o grupo P realmente TEM a
    # frequencia maxima mais alta antes de decidir qual lado confinar. Isso
    # protege a portabilidade pra outras maquinas: se a deteccao por nome
    # estiver errada (bug de kernel, topologia atipica), aborta em vez de
    # confinar o lado de alta potencia por engano.
    read -r p_max p_max_list <<< "$(max_freq_khz "$PCORES")"
    read -r e_max e_max_list <<< "$(max_freq_khz "$ECORES")"
    if [[ -z "$p_max_list" || -z "$e_max_list" ]]; then
        echo "AVISO: nao consegui ler cpuinfo_max_freq de algum grupo — pulando a" >&2
        echo "validacao cruzada de frequencia (seguindo so pelo nome sysfs)." >&2
    elif (( p_max <= e_max )); then
        echo "ERRO: o grupo detectado como P-cores ($PCORES, max ${p_max}kHz) NAO tem" >&2
        echo "frequencia maxima maior que o grupo E-cores ($ECORES, max ${e_max}kHz)." >&2
        echo "A deteccao de topologia esta inconsistente nesta maquina — abortando" >&2
        echo "por seguranca em vez de arriscar confinar o lado de alta potencia." >&2
        exit 1
    fi
    PCORES_PEAK_CPUS=$(sed 's/^/cpu/; s/,/, cpu/g' <<< "$p_max_list")
    PCORES_PEAK_MHZ=$(( p_max / 1000 ))
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
        echo "Nucleos de maior potencia entre os P-cores: $PCORES_PEAK_CPUS (${PCORES_PEAK_MHZ}MHz max) — ociosos durante o modo eco."
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
