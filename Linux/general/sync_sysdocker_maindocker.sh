#!/bin/bash
set -uo pipefail

### --- CONFIGURATION --- ###
CTID=100

SOURCE="/mnt/sysdata_docker/"
DEST="/mnt/main_docker/"
### ---------------------- ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

# Detect if container is running
is_container_running() {
    pct status "$CTID" | grep -q "running"
}

# Wait for LXC teardown by watching the mount namespace
wait_for_lxc_teardown() {
    local ctpid
    ctpid=$(pct pid "$CTID" 2>/dev/null || true)

    if [ -z "$ctpid" ]; then
        return 0
    fi

    log "Waiting for LXC teardown (PID $ctpid)..."
    while [ -e "/proc/$ctpid/ns/mnt" ]; do
        sleep 1
    done
    log "LXC teardown complete."
}

### --- STOP CONTAINER IF NEEDED --- ###
ORIGINALLY_RUNNING=false

log "Checking container state..."
if is_container_running; then
    log "Container $CTID is running. Stopping it..."
    ORIGINALLY_RUNNING=true
    pct stop "$CTID"
else
    log "Container $CTID is already stopped."
fi

wait_for_lxc_teardown

### --- ZFS DESTINATION CHECK --- ###
if ! mountpoint -q "$DEST"; then
    fail "$DEST is not mounted (ZFS dataset missing)."
fi

log "Destination ZFS dataset is mounted."

### --- RSYNC --- ###
log "Starting rsync from $SOURCE to $DEST..."
rsync -avh --itemize-changes --progress --delete "$SOURCE" "$DEST"
log "Sync complete."

### --- RESTORE CONTAINER STATE --- ###
if [ "$ORIGINALLY_RUNNING" = true ]; then
    log "Starting container $CTID..."
    pct start "$CTID"
    log "Container $CTID started."
else
    log "Container was originally stopped. Leaving it stopped."
fi

log "All done."
