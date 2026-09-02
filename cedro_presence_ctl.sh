#!/bin/bash
# cedro_presence_ctl.sh — inspeção/operação do Presence Power Save.
# Não decide nada, só lê o que o daemon já escreveu e formata.
#
# Uso: cedro_presence_ctl.sh status | log [N] | pause | resume

set -euo pipefail

STATE=~/.cedro-presence-state
LOG=~/cedro_presence.log
KILL=~/.cedro-sched-disable         # kill-switch global da casa (compartilhado com cedro_eco_watchdog.sh)
UNIT=cedro-presence.service

usage() { echo "Uso: $0 status | log [N] | pause | resume" >&2; exit 2; }

get() { sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -1; }

hms() {
    local s=$1
    [[ -z "$s" || "$s" == "-" ]] && { echo "-"; return; }
    printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
}

case "${1:-}" in
    status)
        active=$(systemctl --user is-active "$UNIT" 2>/dev/null || echo "inativo")
        since=$(systemctl --user show -p ActiveEnterTimestamp --value "$UNIT" 2>/dev/null)
        echo "Presence Power Save: unit $active${since:+ (desde $since)}"

        if [[ ! -f "$STATE" ]]; then
            echo "  (sem estado ainda — daemon nao rodou um tick completo)"
        else
            modo=$(get mode); alvo=$(get alvo); real=$(get real); held=$(get held_by)
            bt=$(get bt); usb=$(get usb); screen=$(get screen); rd=$(get rd_active); rd_peer=$(get rd_peer)
            absent_since=$(get absent_since); applied_at=$(get applied_at)

            echo "  Modo: $modo"
            [[ "$bt" == "True" ]] && bt_str="conectado" || bt_str="desconectado"
            [[ "$usb" == "True" ]] && usb_str="presente" || usb_str="ausente"
            echo "  Celular   BT: $bt_str   USB: $usb_str"

            if [[ "$rd" == "True" ]]; then
                echo "  RustDesk: ATIVO  peer $rd_peer"
            elif [[ -n "$rd_peer" && "$rd_peer" != "-" ]]; then
                echo "  RustDesk: sessao aberta mas em espera (ultimo peer ativo: $rd_peer)"
            else
                echo "  RustDesk: sem sessao"
            fi

            [[ "$screen" == "True" ]] && echo "  Tela (DPMS): On" || echo "  Tela (DPMS): Off/Standby"

            if [[ -n "$absent_since" && "$absent_since" != "-" ]]; then
                now=$(date +%s)
                dur=$(( now - absent_since ))
                if (( dur < 600 )); then
                    echo "  Janela de tolerancia: $(hms $((600-dur))) restantes"
                else
                    echo "  Janela de tolerancia: EXPIRADA"
                fi
            else
                echo "  Janela de tolerancia: n/a (presenca ativa)"
            fi

            echo "  --> Alvo: $alvo   Estado real: $real   segurado por: $held"
        fi

        if [[ -f "$KILL" ]]; then
            echo "  Kill-switch: ATIVO ($KILL) — automacao pausada"
        else
            echo "  Kill-switch: ausente"
        fi
        if [[ -f ~/.cedro-eco-armed ]]; then
            echo "  cedro_eco_watchdog: ARMADO — Presence Power Save esta cedendo controle"
        else
            echo "  cedro_eco_watchdog: nao armado"
        fi
        echo "  cedro_eco_mode.sh status:"
        ~/cedro_eco_mode.sh status 2>/dev/null | sed 's/^/    /'
        ;;

    log)
        n="${2:-30}"
        [[ -f "$LOG" ]] && tail -n "$n" "$LOG" || echo "(log ainda nao existe: $LOG)"
        ;;

    pause)
        touch "$KILL"
        echo "kill-switch criado ($KILL) — Presence Power Save (e o watchdog) ficam passivos ate voce rodar 'resume'"
        ;;

    resume)
        if [[ -f "$KILL" ]]; then
            rm -f "$KILL"
            echo "kill-switch removido — automacao volta a decidir no proximo tick"
        else
            echo "kill-switch ja nao existia — nada a fazer"
        fi
        ;;

    *) usage ;;
esac
