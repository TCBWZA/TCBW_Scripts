#!/bin/bash

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
rsync -avh --no-perms --no-owner --no-group --delete --itemize-changes --progress --exclude='*.tmp' "$SOURCE" "$DEST"

# Determine actual device backing $MOUNT
DEV=$(lsblk -no NAME,MOUNTPOINT \
    | sed 's/^[^a-zA-Z0-9]*//' \
    | awk -v m="$MOUNT" '$2==m{print "/dev/"$1; exit}')

echo "Flushing write buffers on $DEV..."
sync
blockdev --flushbufs "$DEV"

if [ "$MOUNTED_BY_SCRIPT" = true ]; then
    echo "Unmounting $MOUNT (mounted by this script)..."
    umount "$MOUNT" || echo "WARN: Failed to unmount $MOUNT."
else
    echo "$MOUNT left mounted (was already mounted)."
fi