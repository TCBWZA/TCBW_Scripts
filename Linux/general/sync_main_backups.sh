#!/bin/bash
set -uo pipefail

### --- CONFIGURATION --- ###
CTID=100

SOURCE="/mnt/sysdata_backups/"
DEST="/mnt/main_backups/"
### ---------------------- ###

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

### --- ZFS DESTINATION CHECK --- ###
if ! mountpoint -q "$DEST"; then
    fail "$DEST is not mounted (ZFS dataset missing)."
fi

log "Destination ZFS dataset is mounted."

### --- RSYNC --- ###
log "Starting rsync from $SOURCE to $DEST..."
# An unchecked rsync reported a failed copy as success.
if rsync -avh --itemize-changes --progress --delete --exclude='*.tmp' "$SOURCE" "$DEST"; then
    log "Sync complete."
else
    log "ERROR: rsync failed for $SOURCE -> $DEST. Not reporting success."
    exit 1
fi

echo "Flushing write buffers..."
sync

log "All Done."
