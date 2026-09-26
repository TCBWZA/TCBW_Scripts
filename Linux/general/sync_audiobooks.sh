#!/bin/bash
set -uo pipefail

### --- CONFIGURATION --- ###
SOURCE="/main/media/audiobooks/"
DEST="/mnt/nmedia/Media/audiobooks"
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

# Deletes files in destination that no longer exist in source
# An unchecked rsync reported a failed copy as success.
if ! rsync -avh --no-perms --no-owner --no-group --delete --itemize-changes --progress --exclude='*.tmp' "$SOURCE" "$DEST"; then
    echo "ERROR: rsync failed for $SOURCE -> $DEST. Not reporting success." >&2
    if [ "$MOUNTED_BY_SCRIPT" = true ]; then
        umount "$MOUNT" || echo "WARN: Failed to unmount $MOUNT."
    fi
    exit 1
fi

# Determine actual device backing $MOUNT
DEV=$(lsblk -no NAME,MOUNTPOINT \
    | sed 's/^[^a-zA-Z0-9]*//' \
    | awk -v m="$MOUNT" '$2==m{print "/dev/"$1; exit}')

# An unresolved device must fail rather than skip the flush.
if [ -z "$DEV" ]; then
    echo "ERROR: could not resolve the device backing $MOUNT -- not flushing, not unmounting." >&2
    exit 1
fi

echo "Flushing write buffers on $DEV..."
sync
blockdev --flushbufs "$DEV"

if [ "$MOUNTED_BY_SCRIPT" = true ]; then
    echo "Unmounting $MOUNT (mounted by this script)..."
    umount "$MOUNT" || echo "WARN: Failed to unmount $MOUNT."
else
    echo "$MOUNT left mounted (was already mounted)."
fi