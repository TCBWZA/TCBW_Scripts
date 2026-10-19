#!/bin/bash

MOUNT="/mnt/nmedia"

# If already unmounted, skip
if ! mountpoint -q "$MOUNT"; then
    echo "Drive already unmounted -- skipping poweroff."
    exit 0
fi

# Resolve the backing device while the mount is still visible: lsblk mountpoint
# match gives the partition (same pattern as the sync_* scripts), PKNAME gives
# the whole disk that udisksctl power-off acts on. An unpartitioned mount has
# no parent, so it falls back to the resolved device itself.
PART=$(lsblk -no NAME,MOUNTPOINT \
    | sed 's/^[^a-zA-Z0-9]*//' \
    | awk -v m="$MOUNT" '$2==m{print "/dev/"$1; exit}')

if [[ -z "$PART" ]]; then
    echo "ERROR: could not resolve the device backing $MOUNT." >&2
    exit 1
fi

DISK=$(lsblk -ndo PKNAME "$PART")
DISK=${DISK:+/dev/$DISK}
DISK=${DISK:-$PART}

echo "Flushing write buffers on $DISK..."
sync
if ! blockdev --flushbufs "$DISK"; then
    echo "WARN: flush failed on $DISK." >&2
fi

echo "Unmounting $MOUNT..."
if ! umount "$MOUNT"; then
	echo "ERROR: unmount failed." >&2
	exit 1
fi

# If device disappeared already, skip
if [[ ! -b "$DISK" ]]; then
    echo "Block device already gone -- nothing to power off."
    exit 0
fi

echo "Powering off USB HDD..."
if ! udisksctl power-off -b "$DISK"; then
	echo "Error: drive did not power off." >&2
	exit 1
fi

echo "Drive powered off."
