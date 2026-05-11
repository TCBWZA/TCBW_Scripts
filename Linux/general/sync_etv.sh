#!/bin/bash

# Deletes files in destination that no longer exist in source

SOURCE="/main/media/Video/TV/"
DEST="/mnt/emedia/Media/Video/TV"

# Trigger automount and fail fast if remote is offline
if ! timeout 10s ls /mnt/emedia >/dev/null 2>&1; then
    echo "ERROR: Remote share unavailable. Aborting sync."
    exit 1
fi

# Confirm mount succeeded
if ! grep -qs "/mnt/emedia" /proc/mounts; then
    echo "ERROR: /mnt/emedia did not mount. Aborting."
    exit 1
fi
# Deletes files in destination that no longer exist in source
# parameters are to support copying to cifs mounted exFAT
rsync -avh --size-only --no-times --no-perms --no-owner --no-group --no-times --omit-dir-times  --itemize-changes --progress --delete "$SOURCE" "$DEST"
