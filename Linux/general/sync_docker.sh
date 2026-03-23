#!/bin/bash

### --- CONFIGURATION --- ###
CTID=100
### ---------------------- ###

ORIGINALLY_RUNNING=false

echo "Checking container state..."
if pct status $CTID | grep -q "running"; then
    echo "Container $CTID is running. Stopping it..."
    ORIGINALLY_RUNNING=true
    pct stop $CTID

    echo "Waiting for container to fully stop..."
    while pct status $CTID | grep -q "running"; do
        sleep 1
    done
else
    echo "Container $CTID is already stopped."
fi


# Deletes files in destination that no longer exist in source

SOURCE="/mnt/sysdata_docker/"
DEST="/mnt/nmedia/DATA/sysdata_docker/"

# Check if destination is mounted 
if ! mountpoint -q "/mnt/nmedia"; then 
    echo "ERROR: $DEST is not mounted. Aborting sync." 
    exit 1
fi

rsync -avh --modify-window=5 --itemize-changes --progress --delete "$SOURCE" "$DEST"

echo "Sync complete."

# Restore container state
if [ "$ORIGINALLY_RUNNING" = true ]; then
    echo "Starting container $CTID..."
    pct start $CTID
else
    echo "Container was originally stopped. Leaving it stopped."
fi
