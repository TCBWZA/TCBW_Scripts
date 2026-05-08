#!/bin/bash

# Deletes files in destination that no longer exist in source

SOURCE="/main/media/Video/Movies/"
DEST="/mnt/nmedia/media/Video/Movies"

# Trigger automount and fail fast if remote is offline
if ! timeout 10s ls /mnt/nmedia >/dev/null 2>&1; then
    echo "ERROR: Remote share unavailable. Aborting sync."
    exit 1
fi

# Confirm mount succeeded
if ! grep -qs "/mnt/nmedia" /proc/mounts; then
    echo "ERROR: /mnt/nmedia did not mount. Aborting."
    exit 1
fi
# Deletes files in destination that no longer exist in source
# parameters are to support copying to cifs mounted exFAT
rsync -avh --modify-window=5 --itemize-changes --progress --delete "$SOURCE" "$DEST"
