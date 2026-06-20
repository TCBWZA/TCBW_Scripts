#!/bin/bash

### --- CONFIGURATION --- ###
CTID=100
### ---------------------- ###

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

SOURCE="/mnt/sysdata_docker/"
DEST="/mnt/nmedia/DATA/sysdata_docker/"

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

rsync -avhL --size-only --no-times --no-perms --no-owner --no-group --omit-dir-times --modify-window=5 --itemize-changes --progress --delete "$SOURCE" "$DEST"

echo "Sync complete."

# Determine actual device backing /mnt/nmedia
DEV=$(lsblk -no NAME,MOUNTPOINT \
    | sed 's/^[^a-zA-Z0-9]*//' \
    | awk '$2=="/mnt/nmedia"{print "/dev/"$1; exit}')

echo "Flushing write buffers on $DEV..."
sync
blockdev --flushbufs "$DEV"

# Restore container state
if [ "$ORIGINALLY_RUNNING" = true ]; then
    echo "Starting container $CTID..."
    pct start $CTID
else
    echo "Container was originally stopped. Leaving it stopped."
fi
