#!/bin/bash

# Deletes files in destination that no longer exist in source

SOURCE="/main/media/Video/TV/"
DEST="/mnt/emedia/Media/Video/TV"

# Check if destination is mounted 
if ! mountpoint -q "/mnt/emedia"; then 
    echo "ERROR: $DEST is not mounted. Aborting sync." 
    exit 1 
fi

rsync -avh --size-only --no-times --no-perms --omit-dir-times --modify-window=5 --itemize-changes --progress --delete --exclude='*.tmp' "$SOURCE" "$DEST"
