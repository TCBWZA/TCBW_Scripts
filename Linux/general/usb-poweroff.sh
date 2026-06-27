#!/bin/bash

MOUNT="/mnt/nmedia"
DEVICE="/dev/sdk"

# If already unmounted, skip
if ! mountpoint -q "$MOUNT"; then
    echo "Drive already unmounted — skipping poweroff."
    exit 0
fi

echo "Unmounting $MOUNT..."
if ! umount "$MOUNT"; then
	echo "ERROR: unmount failed."
	exit 1
fi

# If device disappeared already, skip
if [ ! -b "$DEVICE" ]; then
    echo "Block device already gone — nothing to power off."
    exit 0
fi

echo "Powering off USB HDD..."
if ! udisksctl power-off -b "$DEVICE"; then
	echo "Error: drive did not power off."
	exit 1
fi

echo "Drive powered off."
