#!/bin/bash

# Deletes files in destination that no longer exist in source

SOURCE="/main/media/Video/Movies/"
DEST="/mnt/nmedia/media/Video/Movies"

# Check if destination is mounted 
if ! mountpoint -q "/mnt/nmedia"; then 
    echo "ERROR: $DEST is not mounted. Aborting sync." 
    exit 1 
fi

rsync -avh --modify-window=5 --itemize-changes --progress --delete "$SOURCE" "$DEST"
