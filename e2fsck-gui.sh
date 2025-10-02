#!/usr/bin/env bash
set -euo pipefail

APP_TITLE="e2fsck GUI"
LOG_FILE=""
STATUS_FILE=""
E2FSCK_PID=""
PATH="$PATH:/sbin:/usr/sbin"

cleanup() {
    local exit_code=$?
    if [[ -n "$E2FSCK_PID" ]]; then
        if kill -0 "$E2FSCK_PID" 2>/dev/null; then
            kill "$E2FSCK_PID" 2>/dev/null || true
        fi
    fi
    if [[ -n "$STATUS_FILE" && -f "$STATUS_FILE" ]]; then
        rm -f "$STATUS_FILE"
    fi
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

show_error() {
    local message=$1
    zenity --error --title "$APP_TITLE" --text "$message" 2>/dev/null || {
        printf 'Errore: %s\n' "$message" >&2
    }
}

require_commands() {
    local missing=()
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    if ((${#missing[@]})); then
        show_error "Comandi mancanti: ${missing[*]}"
        exit 1
    fi
}

maybe_install_zenity() {
    if command -v zenity >/dev/null 2>&1; then
        return
    fi

    printf 'zenity non trovato. Serve per mostrare la GUI.\n'

    local -a install_cmd=()
    if command -v apt-get >/dev/null 2>&1; then
        install_cmd=(apt-get install -y zenity)
    elif command -v apt >/dev/null 2>&1; then
        install_cmd=(apt install -y zenity)
    elif command -v dnf >/dev/null 2>&1; then
        install_cmd=(dnf install -y zenity)
    elif command -v zypper >/dev/null 2>&1; then
        install_cmd=(zypper install -y zenity)
    elif command -v pacman >/dev/null 2>&1; then
        install_cmd=(pacman -Sy --noconfirm zenity)
    elif command -v emerge >/dev/null 2>&1; then
        install_cmd=(emerge --ask=n zenity)
    fi

    if ((${#install_cmd[@]} == 0)); then
        printf 'Impossibile determinare il gestore pacchetti. Installa zenity manualmente e riprova.\n' >&2
        exit 1
    fi

    printf 'Eseguo: %s\n' "${install_cmd[*]}"
    read -r -p "Procedere? [y/N] " reply
    reply=${reply,,}
    if [[ $reply != y && $reply != yes ]]; then
        printf 'Installazione annullata. Installa zenity e rilancia lo script.\n'
        exit 1
    fi

    if ! "${install_cmd[@]}"; then
        printf 'Installazione fallita. Controlla loutput del gestore pacchetti.\n' >&2
        exit 1
    fi

    if ! command -v zenity >/dev/null 2>&1; then
        printf 'zenity continua a mancare dopo linstallazione.\n' >&2
        exit 1
    fi
}

ensure_root() {
    if [[ $EUID -eq 0 ]]; then
        return
    fi
    local -a env_export=(
        "DISPLAY=${DISPLAY:-}"
        "XAUTHORITY=${XAUTHORITY:-}"
        "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"
        "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}"
        "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-}"
        "GTK_THEME=${GTK_THEME:-}"
    )
    if command -v pkexec >/dev/null 2>&1; then
        exec pkexec env "${env_export[@]}" "$0" "$@"
    fi
    show_error "Eseguire lo script come root (sudo o pkexec)."
    exit 1
}

select_device() {
    local -a rows=()
    while IFS= read -r line; do
        unset NAME TYPE SIZE MOUNTPOINT FSTYPE
        eval "$line"
        local name="$NAME"
        local type="$TYPE"
        local size="$SIZE"
        local mount="${MOUNTPOINT:-}"
        local fstype="$FSTYPE"

        if [[ ! $fstype =~ ^ext[234]?$ ]]; then
            continue
        fi
        if [[ $type != part && $type != lvm && $type != disk ]]; then
            continue
        fi
        [[ -z $mount ]] && mount="--"
        rows+=("FALSE" "$name" "$size" "$fstype" "$mount")
    done < <(lsblk -P -o NAME,TYPE,SIZE,MOUNTPOINT,FSTYPE)

    if ((${#rows[@]} == 0)); then
        show_error "Nessuna partizione ext trovata."
        exit 1
    fi

    zenity --list --radiolist \
        --title "$APP_TITLE" \
        --text "Seleziona la partizione da controllare" \
        --column "Seleziona" --column "Dispositivo" --column "Dimensione" --column "File system" --column "Montato su" \
        "${rows[@]}"
}

ask_flags() {
    zenity --list --checklist \
        --title "$APP_TITLE" \
        --text "Scegli le opzioni di e2fsck" \
        --column "Usa" --column "Flag" --column "Descrizione" \
        FALSE "-n" "Solo lettura (nessuna modifica)" \
        FALSE "-y" "Risponde sempre si' (riparazione automatica)" \
        FALSE "-p" "Preen (riparazione automatica al boot)" \
        FALSE "-f" "Forza il controllo completo" \
        FALSE "-c" "Controllo dei blocchi danneggiati" \
        FALSE "-v" "Output verboso" \
        --separator=" "
}

ask_advanced() {
    zenity --forms \
        --title "$APP_TITLE" \
        --text "Opzioni aggiuntive (facoltative)" \
        --add-entry="Superblocco alternativo (-b)" \
        --add-entry="File di journaling esterno (-l)" \
        --add-entry="Flag extra (come stringa)"
}

confirm_run() {
    local device=$1
    local mountpoint=$2
    local flags=$3
    local extra=$4

    local summary="Dispositivo: <b>$device</b>\n"
    if [[ $mountpoint != "--" ]]; then
        summary+="Montato su: <b>$mountpoint</b>\nATTENZIONE: smontare prima di procedere!\n"
    fi
    summary+="Opzioni: <b>${flags:-(nessuna)}</b>\n"
    summary+="Extra: <b>${extra:-(nessuno)}</b>\n\nConfermi l'avvio di e2fsck?"

    zenity --question --title "$APP_TITLE" --text "$summary" --width=400 --height=200 --ok-label="Avvia" --cancel-label="Annulla" --markup
}

progress_stream() {
    local device=$1
    shift
    local -a cmd=("e2fsck" "-C" "0" "$@" "$device")

    LOG_FILE=$(mktemp -t e2fsck-gui-log-XXXXXX)
    STATUS_FILE=$(mktemp -t e2fsck-gui-status-XXXXXX)

    echo "#Preparazione in corso..." 

    set +e
    # Lanciamo e2fsck in un coprocess per leggere lo stream in tempo reale.
    coproc E2FSCK_PROCESS { stdbuf -oL "${cmd[@]}" 2>&1; }
    local coproc_pid=$COPROC_PID
    set -e

    E2FSCK_PID=$coproc_pid

    if [[ -z $coproc_pid ]]; then
        echo "#Impossibile avviare e2fsck" >&2
        echo 32 >"$STATUS_FILE"
        return
    fi

    trap 'if [[ -n "$E2FSCK_PID" ]]; then kill "$E2FSCK_PID" 2>/dev/null || true; fi' PIPE INT TERM

    local line
    while IFS= read -r line <&"${E2FSCK_PROCESS[0]}"; do
        printf '%s\n' "$line" >>"$LOG_FILE"
        line=${line//$'\r'/}
        if [[ $line =~ ([0-9]+(\.[0-9]+)?)% ]]; then
            local percent=${BASH_REMATCH[1]}
            printf '%d\n' "$(printf '%.0f' "$percent")" || break
        fi
        printf '#%s\n' "$line" || break
    done

    trap - PIPE INT TERM

    wait "$coproc_pid"
    local status=$?
    echo "$status" >"$STATUS_FILE"
    echo "100"
    echo "#Operazione completata (codice $status)"
}

run_check() {
    local device=$1
    shift
    local -a flags=("$@")

    set +e
    progress_stream "$device" "${flags[@]}" | zenity --progress --title "$APP_TITLE" --text "Inizializzazione..." --auto-close --no-cancel 2>/dev/null
    local progress_exit=$?
    set -e
    local status=1
    if [[ -f "$STATUS_FILE" ]]; then
        status=$(<"$STATUS_FILE")
    fi

    if (( progress_exit != 0 )); then
        if [[ -n "$E2FSCK_PID" && -e "/proc/$E2FSCK_PID" ]]; then
            kill "$E2FSCK_PID" 2>/dev/null || true
        fi
        show_error "Operazione annullata dall'utente."
        return 130
    fi

    case $status in
        0)
            zenity --info --title "$APP_TITLE" --text "Nessun errore trovato." 2>/dev/null || true
            ;;
        1)
            zenity --info --title "$APP_TITLE" --text "Errori corretti. E' consigliato un riavvio." 2>/dev/null || true
            ;;
        2)
            show_error "Errori corretti, ma e' richiesto un riavvio." ;;
        4)
            show_error "Errori non corretti. Controllare il log." ;;
        8)
            show_error "Errore operativo durante l'esecuzione di e2fsck." ;;
        16)
            show_error "Errore di utilizzo: controllare le opzioni fornite." ;;
        32)
            show_error "L'esecuzione e' stata interrotta dall'utente." ;;
        *)
            show_error "Terminato con codice sconosciuto: $status" ;;
    esac

    if [[ -f "$LOG_FILE" ]]; then
        zenity --text-info --title "$APP_TITLE - Log" --filename "$LOG_FILE" --ok-label "Chiudi" 2>/dev/null || true
    fi

    return "$status"
}

main() {
    ensure_root "$@"
    maybe_install_zenity
    require_commands zenity e2fsck lsblk stdbuf

    local device_output
    device_output=$(select_device) || exit 0
    [[ -z $device_output ]] && exit 0

    local device=$device_output
    local mountpoint="--"
    mountpoint=$(lsblk -no MOUNTPOINT "$device" 2>/dev/null | head -n1)
    [[ -z $mountpoint ]] && mountpoint="--"

    local selected_flags
    selected_flags=$(ask_flags) || exit 0
    local -a flag_array=()
    if [[ -n $selected_flags ]]; then
        read -r -a flag_array <<<"$selected_flags"
    fi

    local advanced
    advanced=$(ask_advanced) || true
    local -a extra_flags=()
    if [[ -n $advanced ]]; then
        IFS="|" read -r alt_sb journal extra <<<"$advanced"
        if [[ -n ${alt_sb// } ]]; then
            extra_flags+=("-b" "$alt_sb")
        fi
        if [[ -n ${journal// } ]]; then
            extra_flags+=("-l" "$journal")
        fi
        if [[ -n ${extra// } ]]; then
            local -a extra_array
            read -r -a extra_array <<<"$extra"
            extra_flags+=("${extra_array[@]}")
        fi
    fi

    local combined_flags=("${flag_array[@]}" "${extra_flags[@]}")

    confirm_run "$device" "$mountpoint" "${flag_array[*]}" "${extra_flags[*]}" || exit 0

    run_check "$device" "${combined_flags[@]}"
}

main "$@"
