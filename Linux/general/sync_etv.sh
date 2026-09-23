#!/bin/bash

### --- CONFIGURATION --- ###
SOURCE="/main/media/Video/TV/"
DEST="/mnt/emedia/Media/Video/TV"
MOUNT="/mnt/emedia"
### ---------------------- ###

# emedia uses a systemd automount unit. Accessing the path triggers the
# mount; only unmount is skipped because systemd owns it and idle-times
# it out after 300s (see /etc/fstab).
MOUNTED_TIMEOUT=10

# Trigger automount and fail fast if remote is offline
if ! timeout ${MOUNTED_TIMEOUT}s ls "$MOUNT" >/dev/null 2>&1; then
    echo "ERROR: Remote share unavailable. Aborting sync."
    exit 1
fi

# Confirm mount succeeded
if ! grep -qs "$MOUNT" /proc/mounts; then
    echo "ERROR: $MOUNT did not mount. Aborting."
    exit 1
fi

# emedia is a CIFS SMB share (DriveE on the LAN), not the direct-attached
# NTFS drive, so it keeps the SMB-era metadata flags.
rsync -avh --size-only --no-times --no-perms --no-owner --no-group --omit-dir-times --itemize-changes --progress --delete --inplace --exclude='*.tmp' "$SOURCE" "$DEST"

echo "Flushing write buffers..."
sync