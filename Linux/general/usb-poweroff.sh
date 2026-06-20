#!/bin/bash

MOUNT="/mnt/nmedia"
DEVICE="/dev/sdk"

echo "Unmounting $MOUNT..."
umount "$MOUNT" 2>/dev/null

echo "Powering off USB HDD..."
udisksctl power-off -b "$DEVICE"

echo "Drive powered off."
