#!/bin/bash
# ============================================================
#  Shrink an LXC rootfs that is a RAW disk image on dir storage
#  (e.g. ssd2). For LVM-backed rootfs use shrinkvol.sh instead.
#
#  Usage:  ./shrink_boot_disk.sh [OPTIONS] <VMID> [NEW_SIZE]
#    VMID      container id (required, read from /etc/pve/lxc)
#    NEW_SIZE  target size, e.g. 48G (prompted if omitted)
#    -d        dry run: preflight + plan + used-space check, no changes
#    --debug   bash -x trace for every command
#    --help    show help and exit
#
#  Method: stop the CT, loopback-attach the raw image, e2fsck + resize2fs
#  down to the target, detach, then truncate the file to the real
#  filesystem size and update the container conf. Runs entirely on the
#  Proxmox host; the guest never needs SSH access.
#
#  WARN: stops the running container. Always back up first.
#  USE AT YOUR OWN RISK.
# ============================================================
set -uo pipefail

LOOPDEV=""
interrupted=0
trap 'interrupted=1' INT TERM
trap 'cleanup' EXIT

cleanup() {
    if [[ -n "$LOOPDEV" && -b "$LOOPDEV" ]]; then
        losetup -d "$LOOPDEV" 2>/dev/null
        LOOPDEV=""
    fi
    if [[ "${interrupted:-0}" -eq 1 ]]; then
        echo "Interrupted -- cleanup done, CT left stopped."
    fi
}

size_to_bytes() {
    local spec="$1" num suffix
    num="${spec%[GMKm]}"
    suffix="${spec: -1}"
    case "$suffix" in
        K) echo $(( num * 1024 )) ;;
        M) echo $(( num * 1024 * 1024 )) ;;
        G) echo $(( num * 1024 * 1024 * 1024 )) ;;
        m) echo $(( num * 1000 * 1000 )) ;;
    esac
}

usage() {
    local rc="${1:-1}"
    echo "Usage: $0 [OPTIONS] <VMID> [NEW_SIZE]"
    echo
    echo "Shrink an LXC rootfs that is a RAW disk image on dir storage."
    echo
    echo "Arguments:"
    echo "  VMID       container id (required, read from /etc/pve/lxc/<VMID>.conf)"
    echo "  NEW_SIZE   target size, e.g. 48G (prompted if omitted)"
    echo
    echo "Options:"
    echo "  -d         dry run: preflight + plan + used-space check, no changes"
    echo "  --debug    bash -x trace for every command"
    echo "  --help     show this help and exit"
    exit "$rc"
}

# Parse flags; positional args stay <VMID> [NEW_SIZE]
DRY_RUN=false
DEBUG=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) DRY_RUN=true; shift ;;
        --debug) DEBUG=true; shift ;;
        --help) usage 0 ;;
        *) break ;;
    esac
done
[[ "$DEBUG" == true ]] && set -x

VMID="${1:-}"
NEW_SIZE="${2:-}"
CONF="/etc/pve/lxc/$VMID.conf"

if [[ -z "$VMID" ]]; then
    usage 1
fi
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root on the Proxmox host. Aborting."
    exit 1
fi

# Preflight: all required tools must exist before we stop anything
for tool in stat pvesm pct losetup e2fsck resize2fs tune2fs truncate; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: required tool '$tool' not found. Aborting."
        exit 1
    fi
done
if [[ ! -f "$CONF" ]]; then
    echo "ERROR: $CONF not found. Aborting."
    exit 1
fi

# Read the rootfs line and declared size from the container config
rootfs_line=$(grep -E '^rootfs:' "$CONF")
if [[ -z "$rootfs_line" ]]; then
    echo "ERROR: no rootfs line in $CONF. Aborting."
    exit 1
fi
volid=$(echo "$rootfs_line" | awk '{print $2}' | cut -d, -f1)
declared_size=$(echo "$rootfs_line" | grep -o 'size=[0-9][0-9]*[GMKm]' | cut -d= -f2)
raw_path=$(pvesm path "$volid")

if [[ -z "$raw_path" || ! -e "$raw_path" ]]; then
    echo "ERROR: cannot resolve raw image path for '$volid'. Aborting."
    exit 1
fi
if [[ "$raw_path" != *.raw ]]; then
    echo "ERROR: '$raw_path' is not a raw image file."
    echo "       LVM-backed rootfs should be shrunk with shrinkvol.sh. Aborting."
    exit 1
fi

cur_bytes=$(stat -c%s "$raw_path")

if [[ -z "$NEW_SIZE" ]]; then
    read -r -p "New size (currently ${declared_size:-unknown}): " NEW_SIZE
fi
if ! [[ "$NEW_SIZE" =~ ^[0-9]+[GMKm]$ ]]; then
    echo "ERROR: '$NEW_SIZE' is not a valid size (e.g. 48G). Aborting."
    exit 1
fi

new_bytes=$(size_to_bytes "$NEW_SIZE")
if (( new_bytes >= cur_bytes )); then
    echo "ERROR: new size ($NEW_SIZE) is not smaller than current ($declared_size, $cur_bytes bytes). Aborting."
    exit 1
fi

echo "Target: CT $VMID"
echo "  rootfs:   $volid"
echo "  file:     $raw_path"
echo "  declared: $declared_size"
echo "  new:      $NEW_SIZE ($new_bytes bytes)"
echo

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN -- no changes made. Plan:"
    echo "  stop CT $VMID if running"
    echo "  e2fsck + resize2fs down to $NEW_SIZE via loopback"
    echo "  truncate $raw_path to real fs size, update $CONF"
    # Read-only feasibility check: target must hold the currently used space.
    # (resize2fs -P needs e2fsck -f first, which is unsafe while the CT runs,
    # so we estimate from tune2fs block counts instead.)
    bcount=$(tune2fs -l "$raw_path" | awk '/^Block count:/{print $3}')
    free=$(tune2fs -l "$raw_path" | awk '/^Free blocks:/{print $3}')
    bsize=$(tune2fs -l "$raw_path" | awk '/^Block size:/{print $3}')
    used_bytes=$(( (bcount - free) * bsize ))
    echo "  currently used: $(( used_bytes / 1024 / 1024 / 1024 ))G ($used_bytes bytes)"
    if (( new_bytes >= used_bytes )); then
        echo "  $NEW_SIZE fits used space."
    else
        echo "  WARNING: $NEW_SIZE is smaller than used space -- resize2fs would refuse!"
    fi
    exit 0
fi

read -r -p "This will STOP the running container. Continue? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

# Stop the container
if pct status "$VMID" | grep -q 'running'; then
    echo "Stopping CT $VMID..."
    pct stop "$VMID"
    pct wait "$VMID" 2>/dev/null || true
fi

# Loopback-attach the image
LOOPDEV=$(losetup --find --show "$raw_path") || { echo "ERROR: losetup failed. Aborting."; exit 1; }
echo "Attached $raw_path -> $LOOPDEV"

# Filesystem integrity before shrinking
echo "Checking filesystem..."
e2fsck -f "$LOOPDEV" || { echo "ERROR: e2fsck reported problems. Aborting."; exit 1; }

# Shrink the filesystem in place
echo "Shrinking filesystem to $NEW_SIZE..."
resize2fs "$LOOPDEV" "$NEW_SIZE" || { echo "ERROR: resize2fs failed. Aborting."; exit 1; }
sync

# Truncate the file to the real filesystem size so no slack is kept
fsblocks=$(tune2fs -l "$LOOPDEV" | awk '/^Block count:/{print $3}')
bsize=$(tune2fs -l "$LOOPDEV" | awk '/^Block size:/{print $3}')
fs_bytes=$(( fsblocks * bsize ))

losetup -d "$LOOPDEV"
LOOPDEV=""
echo "Detached"

echo "Truncating file to filesystem size ($fs_bytes bytes)..."
truncate -s "$fs_bytes" "$raw_path"

# Update the size recorded in the container config
echo "Updating $CONF size=$NEW_SIZE"
sed -i "s|\(rootfs:.*,size=\)[0-9][0-9]*[GMKm]|\1${NEW_SIZE}|" "$CONF"
grep '^rootfs:' "$CONF"

echo
echo "Done. Final file size: $(stat -c%s "$raw_path") bytes"
read -r -p "Start CT $VMID again? (y/N): " start
if [[ "$start" == "y" || "$start" == "Y" ]]; then
    pct start "$VMID"
fi
echo "Complete."