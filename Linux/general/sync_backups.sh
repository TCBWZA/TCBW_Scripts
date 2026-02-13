#!/bin/bash

# Deletes files in destination that no longer exist in source

SOURCE="/mnt/sysdata_backups/"
DEST="/mnt/nmedia/DATA/sysdata_backups/"

# Check if destination is mounted 
if ! mountpoint -q "/mnt/nmedia"; then 
    echo "ERROR: $DEST is not mounted. Aborting sync." 
    exit 1 
fi

rsync -avh --modify-window=5 --itemize-changes --progress --delete "$SOURCE" "$DEST"
