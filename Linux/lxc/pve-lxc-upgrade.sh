#!/bin/bash

echo "Host update"

apt update && apt upgrade -y

echo "Starting LXC update process..."

JOBS=3
CTIDS=$(pct list | awk 'NR>1 {print $1}')

# Temp file to track containers started by this script
STARTED_FILE="/tmp/lxc-started-$$.list"
: > "$STARTED_FILE"

update_container() {
    CTID="$1"
    LOGFILE="/var/log/lxc-update-$CTID.log"
    STARTED_FILE="$2"

    echo "----------------------------------------"
    echo "Updating container $CTID"

    if pct status "$CTID" | grep -q "stopped"; then
        echo "Container $CTID was stopped. Starting..."
        pct start "$CTID"
        echo "$CTID" >> "$STARTED_FILE"
        sleep 60
    fi

    echo "Running updates inside container $CTID"
    pct exec "$CTID" -- bash -c "apt-get update && apt-get -y upgrade && apt-get -y autoremove" \
        > "$LOGFILE" 2>&1

    if pct exec "$CTID" -- test -f /var/run/reboot-required; then
        echo "Reboot required for container $CTID. Rebooting..."
        pct exec "$CTID" -- reboot
        sleep 10
    fi

    echo "Finished updating container $CTID"
}

export -f update_container

for CTID in $CTIDS; do
    bash -c "update_container $CTID $STARTED_FILE" &

    while (( $(jobs -r | wc -l) >= JOBS )); do
        sleep 1
    done
done

wait

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

