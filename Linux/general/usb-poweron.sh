#!/bin/bash

MOUNT="/mnt/nmedia"
UUID="5422D89122D87986"
XHCI="0000:30:00.4"

echo "Resetting AMD XHCI controller at $XHCI..."

# Logical controller reset (equivalent to unplug/replug)
echo "$XHCI" > /sys/bus/pci/drivers/xhci_hcd/unbind
sleep 1
echo "$XHCI" > /sys/bus/pci/drivers/xhci_hcd/bind
sleep 3

echo "Waiting for block device with UUID $UUID to reappear..."

DEVICE=""
for i in {1..20}; do
    DEV=$(blkid | grep "$UUID" | awk -F: '{print $1}')
    if [ -n "$DEV" ]; then
        DEVICE="$DEV"
        echo "Detected device: $DEVICE"
        break
    fi
    sleep 1
done

if [ -z "$DEVICE" ]; then
    echo "ERROR: Device with UUID $UUID did not reappear."
    exit 1
fi

echo "Mounting $MOUNT..."
mount "$MOUNT"

if mountpoint -q "$MOUNT"; then
    echo "SUCCESS: Drive mounted at $MOUNT"
else
    echo "ERROR: Mount failed."
    exit 1
fi
