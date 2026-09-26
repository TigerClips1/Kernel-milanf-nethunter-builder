#!/system/bin/sh

MODE=/sys/devices/platform/soc/4e00000.ssusb/mode
DATA=/sys/devices/platform/soc/4e00000.ssusb/usb_data_enabled
TYPEC_ROLE=/sys/class/typec/port0/data_role
LOG=/data/local/tmp/nethunter-usb-role.log

usb_log() {
    echo "$(date) $*" >> "$LOG" 2>/dev/null
}

usb_cable_present() {
    [ "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" = "1" ] && return 0
    [ "$(cat /sys/class/power_supply/usb/present 2>/dev/null)" = "1" ] && return 0
    [ "$(cat /sys/class/power_supply/charger/online 2>/dev/null)" = "1" ] && return 0
    return 1
}

usb_host_role() {
    [ -r "$TYPEC_ROLE" ] && grep -q '\[host\]' "$TYPEC_ROLE" 2>/dev/null
}

usb_data_requested() {
    usb_config="$(getprop sys.usb.config 2>/dev/null)"
    case "${usb_config}" in
        none) return 1 ;;
        "")
            usb_functions="$(dumpsys usb 2>/dev/null \
                | sed -n 's/^[[:space:]]*current_functions=\([^[:space:]]*\).*$/\1/p' \
                | head -n 1)"
            case "${usb_functions}" in
                *ADB*|*MTP*|*PTP*|*RNDIS*|*MIDI*|*NCM*|*ACM*) return 0 ;;
            esac
            return 1
            ;;
    esac
    return 0
}

(
    last_status=
    while true; do
        if [ -e "$MODE" ] && [ "$(cat "$MODE" 2>/dev/null)" = "none" ] \
            && usb_cable_present && usb_data_requested && ! usb_host_role; then
            if [ -e "$DATA" ]; then
                case "$(cat "$DATA" 2>/dev/null)" in
                    disabled|0|false)
                        echo 1 > "$DATA" 2>/dev/null
                        case "$(cat "$DATA" 2>/dev/null)" in
                            disabled|0|false)
                                if [ "$last_status" != data-blocked ]; then
                                    usb_log "USB role recovery skipped: usb_data_enabled could not be enabled"
                                    last_status=data-blocked
                                fi
                                sleep 3
                                continue
                                ;;
                        esac
                        ;;
                esac
            fi

            echo peripheral > "$MODE" 2>/dev/null
            if [ "$(cat "$MODE" 2>/dev/null)" = "peripheral" ]; then
                if [ "$last_status" != repaired ]; then
                    usb_log "USB role recovered: none -> peripheral"
                fi
                last_status=repaired
            elif [ "$last_status" != write-failed ]; then
                usb_log "USB role recovery failed; mode remains $(cat "$MODE" 2>/dev/null)"
                last_status=write-failed
            fi
        else
            last_status=
        fi
        sleep 3
    done
) >/dev/null 2>&1 &