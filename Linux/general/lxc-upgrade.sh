#!/bin/bash

echo "pve update"

apt update && apt upgrade -y && apt autoremove -y

echo "Starting LXC update process..."

JOBS=3
CTIDS=$(pct list | awk 'NR>1 {print $1}')

# Temp file to track containers started by this script
STARTED_FILE="/tmp/lxc-started-$$.list"
: > "$STARTED_FILE"

###############################################
# Detect package manager inside the container #
###############################################
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v apk >/dev/null 2>&1; then
        echo apk
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    elif command -v xbps-install >/dev/null 2>&1; then
        echo xbps
    else
        echo unknown
    fi
}

###############################################
# Run updates based on detected package mgr   #
###############################################
run_updates() {
    CTID="$1"
    PKG="$2"

    case "$PKG" in
        apt)
            pct exec "$CTID" -- bash -c "apt-get update && apt-get -y upgrade && apt-get -y autoremove"
            ;;
        apk)
            pct exec "$CTID" -- sh -c "apk update && apk upgrade"
            ;;
        dnf)
            pct exec "$CTID" -- bash -c "dnf -y upgrade"
            ;;
        yum)
            pct exec "$CTID" -- bash -c "yum -y update"
            ;;
        pacman)
            pct exec "$CTID" -- bash -c "pacman -Syu --noconfirm"
            ;;
        xbps)
            pct exec "$CTID" -- sh -c "xbps-install -Su -y"
            ;;
        *)
            echo "Unknown package manager in CT $CTID — skipping updates"
            ;;
    esac
}

###############################################
# Update a single container                   #
###############################################
update_container() {
    CTID="$1"
    LOGFILE="/var/log/lxc-update-$CTID.log"
    STARTED_FILE="$2"

    echo "----------------------------------------"
    echo "Updating container $CTID"

    # Start container if stopped
    if pct status "$CTID" | grep -q "stopped"; then
        echo "Container $CTID was stopped. Starting..."
        pct start "$CTID"
        echo "$CTID" >> "$STARTED_FILE"
        sleep 60
    fi

    # Detect package manager
    echo "Detecting package manager for CT $CTID..."
    PKG=$(pct exec "$CTID" -- bash -c "$(declare -f detect_pkg_manager); detect_pkg_manager")
    echo "Package manager detected: $PKG"

    # Run updates
    echo "Running updates inside container $CTID..."
    run_updates "$CTID" "$PKG" > "$LOGFILE" 2>&1

    # APT-only reboot detection
    if [[ "$PKG" == "apt" ]]; then
        if pct exec "$CTID" -- test -f /var/run/reboot-required; then
            echo "Reboot required for container $CTID. Rebooting..."
            pct exec "$CTID" -- reboot
            sleep 10
        fi
    fi

    echo "Finished updating container $CTID"
}

export -f update_container
export -f detect_pkg_manager
export -f run_updates

###############################################
# Parallel update execution                   #
###############################################
for CTID in $CTIDS; do
    bash -c "update_container $CTID $STARTED_FILE" &

    while (( $(jobs -r | wc -l) >= JOBS )); do
        sleep 1
    done
done

wait

###############################################
# Stop containers that were started by script #
###############################################
echo "----------------------------------------"
echo "Stopping containers that were started by this script..."

if [[ -s "$STARTED_FILE" ]]; then
    while read -r CTID; do
        echo "Stopping container $CTID"
        pct stop "$CTID"
    done < "$STARTED_FILE"
else
    echo "No containers were started by this script."
fi

rm -f "$STARTED_FILE"

echo "All LXC containers updated."
