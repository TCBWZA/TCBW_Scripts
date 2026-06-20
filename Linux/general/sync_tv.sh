#!/bin/bash

# Deletes files in destination that no longer exist in source

SOURCE="/main/media/Video/TV/"
DEST="/mnt/nmedia/Media/Video/TV"

# Trigger automount and fail fast if remote is offline
if ! timeout 10s ls /mnt/nmedia >/dev/null 2>&1; then
    echo "ERROR: Remote share unavailable. Aborting sync."
    exit 1
fi

# Confirm mount succeeded
if ! grep -qs "/mnt/nmedia" /proc/mounts; then
    echo "ERROR: /mnt/nmedia did not mount. Aborting."
    exit 1
fi

rsync -avh --size-only --no-times --no-perms --no-owner --no-group --omit-dir-times --itemize-changes --progress --delete --inplace "$SOURCE" "$DEST"

# Determine actual device backing /mnt/nmedia
DEV=$(lsblk -no NAME,MOUNTPOINT \
    | sed 's/^[^a-zA-Z0-9]*//' \
    | awk '$2=="/mnt/nmedia"{print "/dev/"$1; exit}')

echo "Flushing write buffers on $DEV..."
sync
blockdev --flushbufs "$DEV"

