#!/bin/bash
set -uo pipefail

SOURCE="/etc"
DEST="/mnt/nmedia/pve/etc-backup.tar.gz"

echo "=== POWERING ON USB DRIVE ==="
usb-poweron.sh

# Check if destination is mounted
if ! mountpoint -q "/mnt/nmedia"; then
    echo "ERROR: $DEST is not mounted. Aborting backup."
    exit 1
fi

# Stage, verify, then promote: writing straight to $DEST truncated the last good backup in place.
STAGE="${DEST}.inprogress"
rm -f -- "$STAGE"

BACKUP_OK=false

if tar -czpf "$STAGE" --exclude='*.tmp' "$SOURCE" && tar -tzf "$STAGE" > /dev/null 2>&1; then
    mv -f -- "$STAGE" "$DEST"
    echo "Backup complete: $DEST"
    BACKUP_OK=true
else
    echo "ERROR: /etc backup failed or failed verification -- previous backup left in place." >&2
    rm -f -- "$STAGE"
fi

echo "=== POWERING OFF USB DRIVE ==="
usb-poweroff.sh

if [ "$BACKUP_OK" = true ]; then
    exit 0
fi

exit 1
