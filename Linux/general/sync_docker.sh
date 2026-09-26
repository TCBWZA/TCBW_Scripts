#!/bin/bash
set -uo pipefail

### --- CONFIGURATION --- ###
CTID=100

SOURCE="/mnt/sysdata_docker/"
DEST="/mnt/nmedia/DATA/sysdata_docker/"
MOUNT="/mnt/nmedia"
### ---------------------- ###

# Mount the target if needed. Remember whether THIS script mounted it so
# we only unmount targets we mounted; sync.sh powers the drive and keeps
# it mounted for the whole job sequence.
MOUNTED_BY_SCRIPT=false
if ! mountpoint -q "$MOUNT"; then
    echo "Mounting $MOUNT..."
    if ! mount "$MOUNT"; then
        echo "ERROR: Failed to mount $MOUNT. Aborting sync."
        exit 1
    fi
    MOUNTED_BY_SCRIPT=true
fi

ORIGINALLY_RUNNING=false

echo "Checking container state..."
if pct status $CTID | grep -q "running"; then
    echo "Container $CTID is running. Stopping it..."
    ORIGINALLY_RUNNING=true
    pct stop $CTID

    echo "Waiting for container to fully stop..."
    while pct status $CTID | grep -q "running"; do
        sleep 1
    done
else
    echo "Container $CTID is already stopped."
fi

# Deletes files in destination that no longer exist in source
# An unchecked rsync reported a failed copy as success.
SYNC_OK=true

if ! rsync -avhL --no-perms --no-owner --no-group --delete --itemize-changes --progress --exclude='*.tmp' "$SOURCE" "$DEST"; then
    echo "ERROR: rsync failed for $SOURCE -> $DEST. Not reporting success." >&2
    SYNC_OK=false
fi

# An unresolved device must fail rather than skip the flush.
if [ "$SYNC_OK" = true ]; then
    DEV=$(lsblk -no NAME,MOUNTPOINT \
        | sed 's/^[^a-zA-Z0-9]*//' \
        | awk -v m="$MOUNT" '$2==m{print "/dev/"$1; exit}')

    if [ -z "$DEV" ]; then
        echo "ERROR: could not resolve the device backing $MOUNT -- not flushing, not unmounting." >&2
        SYNC_OK=false
    else
        echo "Flushing write buffers on $DEV..."
        sync
        blockdev --flushbufs "$DEV"
    fi
fi

if [ "$SYNC_OK" = true ]; then
    echo "Sync complete."
fi

# Restore container state
if [ "$ORIGINALLY_RUNNING" = true ]; then
    echo "Starting container $CTID..."
    pct start $CTID
else
    echo "Container was originally stopped. Leaving it stopped."
fi

if [ "$MOUNTED_BY_SCRIPT" = true ]; then
    echo "Unmounting $MOUNT (mounted by this script)..."
    umount "$MOUNT" || echo "WARN: Failed to unmount $MOUNT."
else
    echo "$MOUNT left mounted (was already mounted)."
fi

[ "$SYNC_OK" = true ] || exit 1