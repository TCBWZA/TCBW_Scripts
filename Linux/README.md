# Linux Scripts

This folder contains utility scripts for Linux/Proxmox environments.

## Requirements

- **Proxmox VE**: 6.0 or later
- **Bash**: v4.0 or later
- **Root access**: Scripts must be run as root to manage containers
- **Standard utilities**: `pct`, `apt`, utilities commonly available on Debian-based systems

## Files

### pve-lxc-upgrade.sh
Automated LXC container update script for Proxmox VE. Updates the host system and all LXC containers in parallel with configurable job limits. Automatically handles container startup, package updates, and reboots when needed. Logs all operations to `/var/log/lxc-update-*.log`.

**Usage**: Run as root on Proxmox VE host.
