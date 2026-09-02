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
    local ranges="$1" part lo hi n parts
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

# ALLCORES sozinho — NUNCA falha, sem depender de a CPU ser hibrida. `off` (o
# caminho de restauracao/failsafe) usa só isto: o resgate de "volta tudo ao
# normal" nao pode ficar refem de deteccao de P/E-core nem da validacao por
# frequencia abaixo, ou o proprio failsafe vira um jeito novo de travar preso
# no modo eco.
detect_allcores() {
    ALLCORES=$(cat /sys/devices/system/cpu/online)
}

# Deteccao de P-cores/E-cores + validacao cruzada por frequencia. Só usada por
# `on` (que precisa saber qual lado confinar) e por `status` (só de forma
# informativa, com degradacao graciosa). Retorna 1 (nao "exit") em caso de
# falha — quem chama decide se isso é fatal ou so um "sem info extra".
detect_pe_topology() {
    if [[ -r /sys/devices/cpu_core/cpus && -r /sys/devices/cpu_atom/cpus ]]; then
        PCORES=$(cat /sys/devices/cpu_core/cpus)
        ECORES=$(cat /sys/devices/cpu_atom/cpus)
    else
        echo "ERRO: esta CPU nao expoe /sys/devices/cpu_core e /sys/devices/cpu_atom." >&2
        echo "Isso significa que nao e uma CPU hibrida Intel (Alder Lake ou mais nova)" >&2
        echo "com P-cores/E-cores distintos, ou o kernel e anterior ao 5.16." >&2
        echo "Modo eco nao tem o que fazer aqui: nao ha E-cores para confinar o sistema." >&2
        return 1
    fi

    # Validacao cruzada por frequencia: nao confia cegamente no nome do grupo
    # sysfs (cpu_core/cpu_atom) — confirma que o grupo P realmente TEM a
    # frequencia maxima mais alta antes de decidir qual lado confinar. Isso
    # protege a portabilidade pra outras maquinas: se a deteccao por nome
    # estiver errada (bug de kernel, topologia atipica), aborta em vez de
    # confinar o lado de alta potencia por engano.
    # Defaults: se a validacao de frequencia for pulada (AVISO abaixo), estas
    # ficam vazias — quem usa detect_pe_topology precisa checar antes de
    # imprimir, em vez de assumir que sempre vem preenchida.
    PCORES_PEAK_CPUS=""
    PCORES_PEAK_MHZ=""

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
        return 1
    else
        PCORES_PEAK_CPUS=$(sed 's/^/cpu/; s/,/, cpu/g' <<< "$p_max_list")
        PCORES_PEAK_MHZ=$(( p_max / 1000 ))
    fi
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
        detect_allcores
        detect_pe_topology || exit 1
        echo "Restringindo o sistema inteiro aos E-cores ($ECORES). P-cores ($PCORES) ficam livres/ociosos."
        if [[ -n "$PCORES_PEAK_CPUS" ]]; then
            echo "Nucleos de maior potencia entre os P-cores: $PCORES_PEAK_CPUS (${PCORES_PEAK_MHZ}MHz max) — ociosos durante o modo eco."
        fi
        # --no-ask-password: se o polkit nao autorizar silenciosamente (regra
        # nao carregada, polkitd reiniciando), falha em ms com "Interactive
        # authentication required" em vez de abrir um dialogo de senha na
        # tela grafica e deixar um systemctl orfao pendurado (visto em
        # producao 02/09, 14:56-14:58 — journal do polkit confirma).
        if ! run systemctl set-property --runtime --no-ask-password system.slice "AllowedCPUs=$ECORES"; then
            echo "ERRO: falha ao confinar system.slice — abortando sem tocar user.slice." >&2
            exit 1
        fi
        if ! run systemctl set-property --runtime --no-ask-password user.slice "AllowedCPUs=$ECORES"; then
            echo "ERRO: falha ao confinar user.slice — desfazendo system.slice pra nao deixar" >&2
            echo "o sistema num estado misto (so metade confinada aos E-cores)." >&2
            run systemctl set-property --runtime --no-ask-password system.slice "AllowedCPUs=$ALLCORES"
            exit 1
        fi
        ;;
    off)
        # Caminho de restauracao/failsafe — so precisa saber "todos os cores".
        # Nao chama detect_pe_topology de proposito: isso teria que funcionar
        # mesmo se a validacao de topologia falhar, senao o proprio resgate
        # vira um novo jeito de travar preso no modo eco.
        detect_allcores
        echo "Removendo restricao — sistema volta a usar todos os cores ($ALLCORES)."
        # Tenta os dois slices independente do resultado do primeiro — este e
        # o caminho de resgate, maximizar quantos cores voltam importa mais
        # que abortar cedo (set -e nao se aplica aqui de proposito, por isso
        # o "|| { ...; }" em vez de deixar a falha propagar).
        ok=1
        run systemctl set-property --runtime --no-ask-password system.slice "AllowedCPUs=$ALLCORES" \
            || { echo "ERRO: falha ao restaurar system.slice" >&2; ok=0; }
        run systemctl set-property --runtime --no-ask-password user.slice "AllowedCPUs=$ALLCORES" \
            || { echo "ERRO: falha ao restaurar user.slice" >&2; ok=0; }
        (( ok )) || exit 1
        ;;
    status)
        detect_allcores
        cur_sys=$(systemctl show -p AllowedCPUs --value system.slice 2>/dev/null)
        cur_usr=$(systemctl show -p AllowedCPUs --value user.slice 2>/dev/null)
        is_full() { [[ -z "$1" || "$1" == "$ALLCORES" ]]; }
        if is_full "$cur_sys" && is_full "$cur_usr"; then
            echo "Modo eco: DESLIGADO (sem restricao, todos os cores disponiveis: $ALLCORES)"
        else
            echo "Modo eco: LIGADO — system.slice AllowedCPUs=$cur_sys | user.slice AllowedCPUs=$cur_usr"
        fi
        if detect_pe_topology; then
            if [[ -n "$PCORES_PEAK_CPUS" ]]; then
                echo "P-cores: $PCORES | E-cores: $ECORES | nucleo(s) de maior potencia: $PCORES_PEAK_CPUS (${PCORES_PEAK_MHZ}MHz max)"
            else
                echo "P-cores: $PCORES | E-cores: $ECORES"
            fi
        fi
        ;;
    *) usage ;;
esac
