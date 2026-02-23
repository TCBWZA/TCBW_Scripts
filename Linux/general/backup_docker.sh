#!/bin/bash

### --- CONFIGURATION --- ###
### Make sure to adjust these variables before running the script
### Confirm that all necessary tools (tar, pigz, zstd) are installed and available in the PATH

CTID=100
SOURCE="/sysdata_docker"
DEST="/mnt/nmedia/pve/docker-backup.tar"
COMPRESSOR="pigz"   # options: pigz | zstd | gzip
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

# Check mount
if ! mountpoint -q "/mnt/nmedia"; then
    echo "ERROR: /mnt/nmedia is not mounted. Aborting backup."
    if [ "$ORIGINALLY_RUNNING" = true ]; then pct start $CTID; fi
    exit 1
fi

mkdir -p /mnt/nmedia/pve/hold

# Move old backups
if ls ${DEST}* 1> /dev/null 2>&1; then
    mv -f ${DEST}* /mnt/nmedia/pve/hold
fi

echo "Running backup with compression: $COMPRESSOR"

case "$COMPRESSOR" in

    pigz)
        # Parallel gzip with low CPU + low IO priority
        ionice -c3 nice -n 19 tar -cf - "$SOURCE" \
            | ionice -c3 nice -n 19 pigz -9 > "${DEST}.gz"
        ;;

    zstd)
        # zstd with low priority (best compression)
        ionice -c3 nice -n 19 tar -cf - "$SOURCE" \
            | ionice -c3 nice -n 19 zstd -19 -T0 -o "${DEST}.zst"
        ;;

    gzip)
        # Standard gzip with low priority
        ionice -c3 nice -n 19 tar -czpf "${DEST}.gz" "$SOURCE"
        ;;

    *)
        echo "Unknown compressor: $COMPRESSOR"
        exit 1
        ;;
esac

echo "Backup complete."

# Restore container state
if [ "$ORIGINALLY_RUNNING" = true ]; then
    echo "Starting container $CTID..."
    pct start $CTID
else
    echo "Container was originally stopped. Leaving it stopped."
fi

echo "Done."
