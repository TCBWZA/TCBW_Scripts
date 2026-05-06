#!/bin/bash

# Deletes files in destination that no longer exist in source
# parameters are to support copying to cifs mounted exFAT

SOURCE="/main/media/Video/Movies/"
DEST="/mnt/nmedia/media/Video/Movies"

# Check if destination is mounted 
if ! mountpoint -q "/mnt/nmedia"; then 
    echo "ERROR: $DEST is not mounted. Aborting sync." 
    exit 1 
fi

rsync -avh --size-only --no-times --no-perms --omit-dir-times --modify-window=5 --itemize-changes --progress --delete --exclude='*.tmp' "$SOURCE" "$DEST"
