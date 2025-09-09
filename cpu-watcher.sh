#!/usr/bin/env bash
# cpu-watcher.sh
# Minimal CPU Temperature & Usage Watcher for Arch Linux
# Logs to journald, minimal desktop notifications (only danger-level)
set -euo pipefail

### CONFIG ###
SERVICE_NAME="cpu-watcher"
SERVICE_PATH="$HOME/.config/systemd/user/$SERVICE_NAME.service"
SCRIPT_PATH="$(realpath "$0")"

TEMP_CRIT=90              # °C threshold for critical temp alert
CPU_USAGE_THRESHOLD=95    # % threshold for CPU usage
CPU_USAGE_DURATION=20     # seconds of sustained load before alert
CHECK_INTERVAL=5          # seconds between checks
COOLDOWN=120              # seconds before repeating same alert

# === STATE ===
declare -A last_temp_alert
last_cpu_alert=0
high_usage_time=0
HAVE_PIDSTAT=false
HAVE_NOTIFY_SEND=false

### LOGGING + NOTIFICATION ###
log() {
    echo "$*" | systemd-cat -t "$SERVICE_NAME"
}

notify_user() {
    local msg="$1"
    log "$msg"  # Log the message always

    # Send desktop notification only if notify-send exists
    if [[ "$HAVE_NOTIFY_SEND" != false ]]; then
        notify-send -u critical "⚠️ CPU Watcher" "$msg" 2>/dev/null || true
    fi
}

### DEPENDENCY INSTALLER ###
ask_install() {
    local pkg="$1"
    local bin="$2"

    # Non-interactive (systemd service) skip
    if [[ -n "${INVOCATION_ID:-}" ]]; then
        log "⚠️ Dependency '$bin' (from '$pkg') missing. Install manually: sudo pacman -S $pkg"
        return 1
    fi

    echo "Dependency '$bin' (from package '$pkg') is missing."
    read -rp "👉 Install '$pkg' now? [Y/n] " ans
    ans="${ans,,}"              # lowercase
    ans="${ans//[[:space:]]/}"  # strip spaces

    if [[ -z "$ans" || "$ans" == "y" || "$ans" == "yes" ]]; then
        if ! command -v pacman >/dev/null 2>&1; then
            log "❌ pacman not found. Cannot install '$pkg'."
            return 1
        fi

        if ! sudo pacman -S --noconfirm "$pkg"; then
            log "❌ Failed to install '$pkg'. Some features may be disabled."
            return 1
        fi

        # Verify binary exists after install
        if ! command -v "$bin" >/dev/null 2>&1; then
            log "❌ '$bin' still missing after attempted install."
            return 1
        fi

        log "✅ Successfully installed '$pkg'."
        return 0
    else
        log "⚠️ Skipped installing '$pkg'. Some features may be disabled."
        return 1
    fi
}

check_deps() {
    missing_required=()   # Removed local scoping
    missing_optional=()
    declare -A dep_status

    # --- lm-sensors (required) ---
    if command -v sensors >/dev/null 2>&1; then
        dep_status["sensors"]="✅"
    else
        ask_install "lm-sensors" "sensors"
        if command -v sensors >/dev/null 2>&1; then
            dep_status["sensors"]="✅"
        else
            dep_status["sensors"]="❌"
            missing_required+=("sensors")
        fi
    fi

    # --- bc (required) ---
    if command -v bc >/dev/null 2>&1; then
        dep_status["bc"]="✅"
    else
        ask_install "bc" "bc"
        if command -v bc >/dev/null 2>&1; then
            dep_status["bc"]="✅"
        else
            dep_status["bc"]="❌"
            missing_required+=("bc")
        fi
    fi

    # --- notify-send (optional) ---
    if command -v notify-send >/dev/null 2>&1; then
        HAVE_NOTIFY_SEND=true
        dep_status["notify-send"]="✅"
    else
        HAVE_NOTIFY_SEND=false
        ask_install "libnotify" "notify-send"
        if command -v notify-send >/dev/null 2>&1; then
            HAVE_NOTIFY_SEND=true
            dep_status["notify-send"]="✅"
        else
            dep_status["notify-send"]="⚠️"
            missing_optional+=("notify-send")
        fi
    fi

    # --- pidstat (optional) ---
    if command -v pidstat >/dev/null 2>&1; then
        HAVE_PIDSTAT=true
        dep_status["pidstat"]="✅"
    else
        HAVE_PIDSTAT=false
        ask_install "sysstat" "pidstat"
        if command -v pidstat >/dev/null 2>&1; then
            HAVE_PIDSTAT=true
            dep_status["pidstat"]="✅"
        else
            dep_status["pidstat"]="⚠️"
            missing_optional+=("pidstat")
        fi
    fi

    # --- Summary ---
    echo
    echo "Dependency Summary:"
    printf "%-15s %-10s %-10s\n" "Package/Binary" "Critical?" "Status"
    printf "%-15s %-10s %-10s\n" "---------------" "--------" "------"

    printf "%-15s %-10s %-10s\n" "sensors" "Yes" "${dep_status["sensors"]}"
    printf "%-15s %-10s %-10s\n" "bc" "Yes" "${dep_status["bc"]}"
    printf "%-15s %-10s %-10s\n" "notify-send" "No" "${dep_status["notify-send"]}"
    printf "%-15s %-10s %-10s\n" "pidstat" "No" "${dep_status["pidstat"]}"
    echo

    # --- Warnings ---
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        log "❌ Missing required packages: ${missing_required[*]}. Watcher may fail."
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log "⚠️ Missing optional packages: ${missing_optional[*]}. Some features disabled."
    fi

    if [[ ${#missing_required[@]} -eq 0 && ${#missing_optional[@]} -eq 0 ]]; then
        log "✅ All dependencies satisfied."
    fi
}

### MONITOR LOOP ###
get_core_labels() {
    sensors | awk -F: '/Core [0-9]+:|Package id [0-9]+:/ {
        gsub(/^[ \t]+|°C.*$/,"",$1); print $1
    }' | sort -u
}

get_temp() {
    local label="$1"
    local temp
    temp=$(sensors | awk -v l="$label" -F: '
        $1 ~ l { gsub(/[^0-9.]/,"",$2); print $2; exit }
    ')
    [[ -z "$temp" ]] && temp=$(sensors | grep -oP '\d+\.\d+(?=°C)' | head -1)
    echo "$temp"
}

get_cpu_usage() {
    read -r idle1 total1 < <(awk '/^cpu / {idle=$5; total=$2+$3+$4+$5+$6+$7+$8; print idle,total}' /proc/stat)
    sleep "$CHECK_INTERVAL"
    read -r idle2 total2 < <(awk '/^cpu / {idle=$5; total=$2+$3+$4+$5+$6+$7+$8; print idle,total}' /proc/stat)

    local idle=$((idle2 - idle1))
    local total=$((total2 - total1))
    (( total <= 0 )) && total=1  # avoid division by zero

    local usage
    usage=$(echo "scale=2; (1 - $idle/$total)*100" | bc -l)
    echo "$usage"
}

get_top_process() {
    if [[ "$HAVE_PIDSTAT" == true ]]; then
        local top
        top=$(pidstat -u 1 1 2>/dev/null | awk 'NR>3 {printf "%s (%s%%) %s\n",$3,$7,$8}' | sort -k2 -nr | head -1)
        [[ -z "$top" ]] && top="N/A"
        echo "$top"
    else
        echo "N/A"
    fi
}

send_temp_alert() {
    local label="$1"
    local temp="$2"
    local now=$(date +%s)
    local last=${last_temp_alert[$label]:-0}
    (( now - last < COOLDOWN )) && return

    local msg="🔥 CPU Overheating! $label: ${temp}°C"

    log "$msg"  # always log
    [[ "$HAVE_NOTIFY_SEND" == true ]] && notify_user "$msg" || true

    last_temp_alert[$label]=$now
}

send_cpu_alert() {
    local usage="$1"
    local now=$(date +%s)

    # Respect cooldown
    (( now - last_cpu_alert < COOLDOWN )) && return

    # Get top process safely
    local top_proc
    top_proc=$(get_top_process)
    [[ -z "$top_proc" ]] && top_proc="N/A"

    local msg="⚠️ Sustained CPU Load: ${usage}% | Top culprit: $top_proc"

    log "$msg"  # always log
    [[ "$HAVE_NOTIFY_SEND" == true ]] && notify_user "$msg" || true

    last_cpu_alert=$now
}

run_watcher() {
    check_deps
    log "Watcher started"
    trap 'log "Watcher stopped"; exit 0' SIGINT SIGTERM EXIT

    mapfile -t cores < <(get_core_labels)
    [[ ${#cores[@]} -eq 0 ]] && cores=("CPU")

    local high_start=0

    while true; do
    # --- TEMP MONITOR ---
        for core in "${cores[@]}"; do
            local temp
            temp=$(get_temp "$core" || echo "")
            if [[ "$temp" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$temp >= $TEMP_CRIT" | bc -l) )); then
                send_temp_alert "$core" "$temp"
            fi
        done

        # --- CPU USAGE MONITOR ---
        local cpu_inst
        cpu_inst=$(get_cpu_usage)
        if (( $(echo "$cpu_inst >= $CPU_USAGE_THRESHOLD" | bc -l) )); then
            if (( high_start == 0 )); then
                high_start=$(date +%s)
            elif (( $(date +%s) - high_start >= CPU_USAGE_DURATION )); then
                send_cpu_alert "$cpu_inst"
                high_start=0
            fi
        else
            high_start=0
        fi
    done
}


### SERVICE MANAGEMENT ###
install_service() {
    # Check dependencies first
    echo
    echo "Checking dependencies before installation..."
    check_deps

    # Abort if required dependencies are missing
    if [[ ${#missing_required[@]} -gt 0 ]]; then
        echo "❌ Cannot install service. Missing required dependencies: ${missing_required[*]}"
        echo "Please install them manually and rerun --install."
        return 1
    fi

    # # --- Prepare service folder ---
    mkdir -p "$(dirname "$SERVICE_PATH")"
    mkdir -p "$HOME/.local/bin"

    # --- Copy script to local bin ---
    cp "$0" "$HOME/.local/bin/cpu-watcher.sh"
    chmod +x "$HOME/.local/bin/cpu-watcher.sh"

    # --- Write systemd user service ---
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Minimal CPU Temperature & Usage Watcher
After=graphical.target

[Service]
ExecStart="$HOME/.local/bin/cpu-watcher.sh" --run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    # --- Reload systemd, enable & start service ---
    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"

    echo "✅ Installed and started $SERVICE_NAME"

    # --- First-time notification if notify-send available ---
    if [[ "$HAVE_NOTIFY_SEND" == true ]]; then
        notify-send -u normal "CPU Watcher Installed" \
                    "✅ CPU Watcher has been installed and is running as a user service."
    fi
}

uninstall_service() {
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_PATH"
    rm -f "$HOME/.local/bin/cpu-watcher.sh"
    systemctl --user daemon-reload
    echo "✅ Uninstalled $SERVICE_NAME"
}

service_status() {
    systemctl --user status "$SERVICE_NAME" --no-pager
}

show_help() {
    echo "Usage: $0 [--install | --uninstall | --run | --status]"
    echo
    echo "  --install    Install and start as a user service"
    echo "  --uninstall  Stop and remove the user service"
    echo "  --run        Run the watcher in the foreground"
    echo "  --status     Show service status"
}

### MAIN ENTRY ###
case "${1:-}" in
    --install) install_service ;;
    --uninstall) uninstall_service ;;
    --status) service_status ;;
    --run|"") run_watcher ;;
    -h|--help) show_help ;;
    *) echo "Unknown option: $1"; show_help; exit 1 ;;
esac
