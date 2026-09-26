#!/bin/bash
# pipefail matters: `tar | pigz` reports only pigz's status.
set -uo pipefail

### --- CONFIGURATION --- ###
### Make sure that pigz and other requirements are installed.

CTID=100
SOURCE="/mnt/sysdata_docker"
DEST="/mnt/nmedia/pve/docker-backup.tar"
COMPRESSOR="pigz"   # options: pigz | zstd | gzip
### ---------------------- ###

echo "=== POWERING ON USB DRIVE ==="
usb-poweron.sh

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

echo "Running backup with compression: $COMPRESSOR"

# Verify by decompressing and reading the index back; a truncated archive cannot.
verify_archive() {
    # Without the decompressor, tar reads an empty stream and exits 0.
    case "$COMPRESSOR" in
        pigz)  command -v pigz > /dev/null || return 1
               pigz -t -- "$1" > /dev/null 2>&1 || return 1
               pigz -d -c -- "$1" | tar -tf - > /dev/null 2>&1 ;;
        gzip)  command -v gzip > /dev/null || return 1
               tar -tzf "$1" > /dev/null 2>&1 ;;
        zstd)  command -v zstd > /dev/null || return 1
               zstd -t -- "$1" > /dev/null 2>&1 ;;
        *)     return 1 ;;
    esac
}

# Stage, verify, then promote: a failed run must not leave a truncated archive at $DEST.
STAGE="${DEST}.inprogress"
EXT=".gz"
OUT=""

case "$COMPRESSOR" in

    pigz)
        OUT="${STAGE}.gz"
        # Parallel gzip with low CPU + low IO priority
        ionice -c3 nice -n 19 tar -cf - --exclude='*.tmp' "$SOURCE" \
            | ionice -c3 nice -n 19 pigz -9 > "$OUT"
        ;;

    zstd)
        OUT="${STAGE}.zst"
        EXT=".zst"
        # zstd with low priority (best compression)
        ionice -c3 nice -n 19 tar -cf - --exclude='*.tmp' "$SOURCE" \
            | ionice -c3 nice -n 19 zstd -19 -T0 -o "$OUT"
        ;;

    gzip)
        OUT="${STAGE}.gz"
        # Standard gzip with low priority
        ionice -c3 nice -n 19 tar -czpf "$OUT" --exclude='*.tmp' "$SOURCE"
        ;;

    *)
        echo "Unknown compressor: $COMPRESSOR"
        exit 1
        ;;
esac

BACKUP_OK=false
rc=$?

if [[ $rc -ne 0 ]]; then
    echo "ERROR: backup command failed (exit $rc) -- previous backup left in place." >&2
elif [[ ! -s "$OUT" ]]; then
    echo "ERROR: backup produced an empty file -- previous backup left in place." >&2
elif ! verify_archive "$OUT"; then
    echo "ERROR: archive failed its integrity check -- previous backup left in place." >&2
else
    # Demote the old generation only now that the replacement is proven good.
    if ls ${DEST}* 1> /dev/null 2>&1; then
        mv -f ${DEST}* /mnt/nmedia/pve/hold
    fi
    mv -f -- "$OUT" "${DEST}${EXT}"
    echo "Backup complete: ${DEST}${EXT}"
    BACKUP_OK=true
fi

# Drop any partial staging file.
[[ $BACKUP_OK -eq true ]] || rm -f -- "$OUT"

# Restore container state
if [ "$ORIGINALLY_RUNNING" = true ]; then
    echo "Starting container $CTID..."
    pct start $CTID
else
    echo "Container was originally stopped. Leaving it stopped."
fi

echo "=== POWERING OFF USB DRIVE ==="
usb-poweroff.sh

if [ "$BACKUP_OK" = true ]; then
    echo "Done."
else
    echo "Done, but the backup FAILED." >&2
    exit 1
fi
