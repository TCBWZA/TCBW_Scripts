# Linux Scripts

This folder contains utility scripts for Linux/Proxmox environments.

## Requirements

- **Proxmox VE**: 6.0 or later
- **Bash**: v4.0 or later
- **Root access**: Scripts must be run as root to manage containers
- **Standard utilities**: `pct`, `apt`, utilities commonly available on Debian-based systems
- **`rsync`**: used by every `sync_*.sh` script
- **`tar`** plus a compressor: `pigz`, `zstd`, or `gzip` for the `backup_*.sh` scripts
- **`util-linux`**: `lsblk` and `blockdev`, used by the sync scripts to find the backing device and flush write buffers
- **`ionice` and `nice`**: used to keep backup and sync I/O off the critical path
- **`udisksctl`**: used to power the USB drive on and off
- **`pvesm` and LVM tools**: used by `shrinkvol.sh`; `lxc-upgrade.sh` and `shrink_boot_disk.sh` also drive `pct`

## Files

### lxc-upgrade.sh

Automated LXC container update script for Proxmox VE. Updates the host system and all LXC containers in parallel with configurable job limits. Automatically handles container startup, package updates, and reboots when needed. Where a container carries a community-scripts `/usr/bin/update` entrypoint, it is run unattended by pinning stdin to `/dev/null` and `TERM` to a working terminfo entry and bounding it with `timeout`, with the exit status checked so a failed or hung update is reported rather than silently passed. Addon update scripts are invoked directly, because the helper would otherwise skip them under `pct exec`. Stopping the containers the script started is bounded too, because a dead init can deadlock `pct stop` indefinitely and leave the remaining containers running. Logs all operations to `/var/log/lxc-update-*.log`.

**Usage**: Run as root on Proxmox VE host.

See [general/](general/README.md) for the full script inventory.
