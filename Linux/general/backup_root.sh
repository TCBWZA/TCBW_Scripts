#!/bin/bash

SOURCE="/root"
DEST="/mnt/nmedia/pve/root-backup.tar.gz"

# Check if destination is mounted 
if ! mountpoint -q "/mnt/nmedia"; then 
    echo "ERROR: $DEST is not mounted. Aborting backup." 
    exit 1
fi

tar -czpf $DEST $SOURCE
