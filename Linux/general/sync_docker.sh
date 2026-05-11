#!/bin/bash
set -uo pipefail

### --- CONFIGURATION --- ###
CTID=100
REMOTE_HOST="192.168.0.10"

SOURCE="/mnt/sysdata_docker/"
DEST="/mnt/nmedia/DATA/sysdata_docker/"

PING_TRIES=2
PING_TIMEOUT=1

AUTOMOUNT_TRY_TIMEOUT=10
AUTOMOUNT_WAIT_SECONDS=60
### ---------------------- ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

### --- CHECK REMOTE HOST --- ###
log "Checking if remote host $REMOTE_HOST is reachable..."
if ! ping -c "$PING_TRIES" -W "$PING_TIMEOUT" "$REMOTE_HOST" >/dev/null 2>&1; then
    fail "Remote host $REMOTE_HOST is offline. Aborting sync."
fi
log "Remote host is reachable."


# Detect if container is running
is_container_running() {
    pct status "$CTID" | grep -q "running"
}

# Wait for LXC teardown by watching the mount namespace
wait_for_lxc_teardown() {
    local ctpid
    ctpid=$(pct pid "$CTID" 2>/dev/null || true)

    # If no PID, container is already fully stopped
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
# Changes to testing if the automount worked
# while an lxc is shutting down the mount is blocked.
# logic tests to see if the locks have been removed and that the
# remote machine is online. if ping fails nothing will work so fail

ORIGINALLY_RUNNING=false

log "Checking container state..."
if is_container_running; then
    log "Container $CTID is running. Stopping it..."
    ORIGINALLY_RUNNING=true
    pct stop "$CTID"
else
    log "Container $CTID is already stopped."
fi

# Wait for teardown to finish
wait_for_lxc_teardown

### --- WAIT FOR AUTOMOUNT --- ###
log "Waiting for automount on $DEST to be ready..."
SECONDS_WAITED=0

while true; do
    # Try to trigger automount
    if timeout "$AUTOMOUNT_TRY_TIMEOUT" ls "$DEST" >/dev/null 2>&1; then
        # Confirm mount succeeded
        if grep -qs "$DEST" /proc/mounts; then
            log "Automount is active."
            break
        fi
    fi

    if (( SECONDS_WAITED >= AUTOMOUNT_WAIT_SECONDS )); then
        fail "Automount did not become ready within ${AUTOMOUNT_WAIT_SECONDS}s."
    fi

    sleep 1
    (( SECONDS_WAITED++ ))
done

### --- RSYNC --- ###
# Deletes files in destination that no longer exist in source
# parameters are to support copying to cifs mounted exFAT
log "Starting rsync from $SOURCE to $DEST..."
rsync -avh --size-only --no-times --no-perms --no-owner --no-group --no-times --omit-dir-times --modify-window=5 --itemize-changes --progress --delete "$SOURCE" "$DEST"
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