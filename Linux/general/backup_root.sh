#!/bin/bash

SOURCE="/root"
DEST="/mnt/nmedia/pve/root-backup.tar.gz"

echo "=== POWERING ON USB DRIVE ==="
usb-poweron.sh

# Check if destination is mounted
if ! mountpoint -q "/mnt/nmedia"; then
    echo "ERROR: $DEST is not mounted. Aborting backup."
    exit 1
fi

tar -czpf $DEST --exclude='*.tmp' $SOURCE

echo "=== POWERING OFF USB DRIVE ==="
usb-poweroff.sh
