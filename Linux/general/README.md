# Linux / general

Utility scripts for the Proxmox host. All scripts are intended to run directly on the **Proxmox host** unless noted otherwise.

> **LXC UID mapping note:** Proxmox unprivileged LXC containers map container UIDs to a host offset of 100000. Container UID **1000** therefore appears on the host as UID **101000**. Scripts that set ownership (e.g. `setperm.sh`) use UID **1000** and are designed to run **inside the container** where the mapping is transparent. If you run them on the host against a path owned by the container, use UID **101000** instead.

---

## Requirements

Install once on the Proxmox host before running these scripts:

```bash
# rsync - required by all sync_*.sh scripts
apt install rsync

# pigz - parallel gzip for backup_docker.sh (recommended)
apt install pigz

# zstd - alternative compressor for backup_docker.sh
apt install zstd
```

`pct` is part of Proxmox VE and is already present on any Proxmox host. `tar`, `gzip`, `find`, and standard coreutils (`chown`, `chmod`) are pre-installed on Debian/Ubuntu. `lsblk`, `blockdev`, and `mountpoint` are part of `util-linux`, which is pre-installed on Debian/Ubuntu. `lvm2` is required by `shrinkvol.sh` (run `apt install lvm2`).

---

## Common behavior

All `sync_*.sh` and `backup_*.sh` scripts skip files with a `.tmp` extension (`--exclude='*.tmp'` for rsync; `--exclude='*.tmp'` for tar).

The media/video sync scripts use local Promox paths (`/main/media/...`) for sources and `/mnt/nmedia` mount for destinations, running on the Proxmox host.

---

## Scripts

### sync.sh

Orchestrator that calls media and system sync scripts in sequence. Run this instead of the individual scripts when doing a full backup pass. Also wraps a USB power-off cycle around the sync jobs.

```bash
./sync.sh
```

Scripts called (in order):
1. `sync_backups.sh`
2. `sync_docker.sh`
3. `sync_anime.sh`
4. `sync_audiobooks.sh`
5. `sync_books.sh`
6. `sync_movies.sh`
7. `sync_sysdocker_maindocker.sh`
8. `sync_tv.sh`

---

### sync_tv.sh

Rsyncs the TV library from `/main/media/Video/TV/` to `/mnt/nmedia/Media/Video/TV`. Checks that `/mnt/nmedia` is mounted before syncing. Uses rsync `--inplace`. Flushes write buffers on the backing block device for `/mnt/nmedia` before returning.

```bash
./sync_tv.sh
```

**Requirements:** `rsync`, `util-linux` (`lsblk`, `blockdev`)

---

### sync_etv.sh

Rsyncs the TV library from `/main/media/Video/TV/` to `/mnt/emedia/Media/Video/TV`. Secondary/emergency backup to the emedia mount. Checks that `/mnt/emedia` is mounted before syncing. Not included in the `sync.sh` orchestrator; run manually when syncing to emedia.

```bash
./sync_etv.sh
```

**Requirements:** `rsync`

---

### sync_movies.sh

Rsyncs the movie library from `/main/media/Video/Movies/` to `/mnt/nmedia/Media/Video/Movies`. Checks that `/mnt/nmedia` is mounted and flushes the backing block device before returning.

```bash
./sync_movies.sh
```

**Requirements:** `rsync`, `util-linux` (`lsblk`, `blockdev`)

---

### sync_anime.sh

Rsyncs the anime library from `/main/media/Video/Anime/` to `/mnt/nmedia/Media/Video/Anime`. Checks that `/mnt/nmedia` is mounted and flushes the backing block device before returning.

```bash
./sync_anime.sh
```

**Requirements:** `rsync`, `util-linux` (`lsblk`, `blockdev`)

---

### sync_audiobooks.sh

Rsyncs the audiobook library from `/main/media/audiobooks/` to `/mnt/nmedia/Media/audiobooks`. Checks that `/mnt/nmedia` is mounted and flushes the backing block device before returning.

```bash
./sync_audiobooks.sh
```

**Requirements:** `rsync`, `util-linux` (`lsblk`, `blockdev`)

---

### sync_books.sh

Rsyncs the book library from `/main/media/books/` to `/mnt/nmedia/Media/books`. Checks that `/mnt/nmedia` is mounted and flushes the backing block device before returning.

```bash
./sync_books.sh
```

**Requirements:** `rsync`, `util-linux` (`lsblk`, `blockdev`)

---

### sync_docker.sh

Stops LXC container 100 (if running), rsyncs the Docker data volume from `/mnt/sysdata_docker/` to `/mnt/nmedia/DATA/sysdata_docker/`, then restarts the container if it was originally running. Checks that `/mnt/nmedia` is mounted before syncing. Uses rsync `--inplace` with `--hard-links`. Flushes block device buffers on `/mnt/nmedia` before returning.

```bash
./sync_docker.sh
```

**Requirements:** `rsync`, `pct` (Proxmox host only)

---

### sync_backups.sh

Rsyncs system backup data from `/mnt/sysdata_backups/` to `/mnt/nmedia/DATA/sysdata_backups/`. Checks that `/mnt/nmedia` is mounted. Flushes block device buffers on `/mnt/nmedia` before returning.

```bash
./sync_backups.sh
```

**Requirements:** `rsync`, `util-linux` (`lsblk`, `blockdev`)

---

### backup_docker.sh

Stops LXC container 100 (if running), compresses `/mnt/sysdata_docker/` into a tar archive on `/mnt/nmedia/pve/`, then restarts the container if it was originally running. Moves any previous backup archive to a `hold/` subfolder before writing the new one. Supports three compressors via the `COMPRESSOR` variable at the top of the script.

| Value | Tool | Notes |
|---|---|---|
| `pigz` | pigz | Parallel gzip; recommended. Requires `pigz` to be installed. |
| `zstd` | zstd | Best compression ratio. Requires `zstd`. |
| `gzip` | gzip | Standard; no extra dependencies. |

Archive output names:
- pigz -> `/mnt/nmedia/pve/docker-backup.tar.gz`
- zstd -> `/mnt/nmedia/pve/docker-backup.tar.zst`
- gzip -> `/mnt/nmedia/pve/docker-backup.tar.gz`

All compressor paths use `ionice -c3 nice -n 19` to minimize system impact during backup.

```bash
./backup_docker.sh
```

**Requirements:** `pct` (Proxmox host only), plus whichever compressor is configured:

```bash
apt install pigz   # recommended
# or
apt install zstd
```

---

### backup_etc.sh

Archives `/etc` to `/mnt/nmedia/pve/etc-backup.tar.gz` using `tar`. Aborts if `/mnt/nmedia` is not mounted. Run on the Proxmox host to back up host configuration.

```bash
./backup_etc.sh
```

**Requirements:** `tar` (pre-installed on Debian/Ubuntu)

---

### backup_root.sh

Archives `/root` to `/mnt/nmedia/pve/root-backup.tar.gz` using `tar`. Aborts if `/mnt/nmedia` is not mounted. Run on the Proxmox host to back up the root home directory.

```bash
./backup_root.sh
```

**Requirements:** `tar` (pre-installed on Debian/Ubuntu)

---

### setperm.sh

Recursively sets ownership and permissions on a directory tree. Intended to run **inside an LXC container** (or on the Proxmox host for host-owned paths) to restore correct ownership after bulk file operations.

- Sets ownership to `1000:1000` on all directories and non-shell files
- Sets permissions to `666` on all non-shell files
- Sets permissions to `777` on all directories
- Shell scripts (`*.sh`) are excluded from ownership and permission changes
- Dry-run mode (`-n`) prints what would be done without making any changes

> **UID context:** Inside a container, UID 1000 is the standard unprivileged user. On the Proxmox host, that same user appears as UID **101000** due to LXC namespace mapping (host offset 100000 + container UID). Run `setperm.sh` inside the container unless you specifically want to change host-side ownership.

```bash
# Dry-run preview (no changes made)
./setperm.sh -n /path/to/directory

# Apply changes
./setperm.sh /path/to/directory

# Apply to current directory
./setperm.sh
```

---

### sync_main_backups.sh

Rsyncs primary host-level backup targets from `/mnt/sysdata_backups/` to `/mnt/main_backups/`. Checks that the destination ZFS dataset is mounted before syncing. Use this when you want a focused backup pass without triggering the full media sync sequence.

```bash
./sync_main_backups.sh
```

**Requirements:** `rsync`, ZFS dataset mounted at `/mnt/main_backups/`

---

### sync_sysdocker_maindocker.sh

Stops LXC container 100 (if running), rsyncs system Docker data from `/mnt/sysdata_docker/` to `/mnt/main_docker/`, then restarts the container if it was originally running. Checks that the ZFS destination dataset at `/mnt/main_docker/` is mounted before syncing. Waits for LXC mount-namespace teardown before accessing container volumes.

```bash
./sync_sysdocker_maindocker.sh
```

**Requirements:** `rsync`, `pct` (Proxmox host only), ZFS dataset mounted at `/mnt/main_docker/`

---

### lxc-upgrade.sh

Performs package upgrades for all running or stopped LXC containers on the Proxmox host. Stops any running containers, detects the package manager inside each container (apt, apk, dnf, yum, pacman, or xbps), runs the appropriate update command, and restarts any containers it started. Containers detected as needing an APT reboot are rebooted in place. Runs container updates in parallel with up to **3 concurrent jobs** at once.

```bash
./lxc-upgrade.sh
```

**Requirements:** `pct` (Proxmox host), log output saved to `/var/log/lxc-update-<CTID>.log`

---

### shrinkvol.sh

Interactive utility that performs safe volume shrinking steps for a specified LXC container logical volume. Prompts for the container VMID and the new size. Potentially destructive; read the script and take backups before running.

- Stops the container if running
- Finds and activates the logical volume (`vm-<VMID>-disk-0`)
- Runs `lvreduce -r` to simultaneously reduce the LV and resize the filesystem
- Deactivates the LV, updates `/etc/pve/lxc/<VMID>.conf`, and optionally restarts the container

```bash
./shrinkvol.sh
```

**Requirements:** `lvm2` (`lvdisplay`, `lvreduce`, `lvchange`), `resize2fs` or the filesystem's resize tool, `pct` (Proxmox host), run as root. The script is fully interactive and requires terminal input.

---

### showswap.sh

Displays the top 10 processes consuming swap, sorted by swap usage (descending). Outputs PID, command name, and swap usage in MB per process.

```bash
./showswap.sh
```

**Requirements:** none (reads `/proc/<pid>/status` directly)

---

### usb-poweroff.sh / usb-poweron.sh

Small helpers to toggle USB-powered devices (power off / power on). `usb-poweroff.sh` unmounts `/mnt/nmedia` and calls `udisksctl power-off` on `/dev/sdk`.

`usb-poweron.sh` performs a logical reset of the AMD XHCI PCI controller (`0000:30:00.4`), waits for the block device with UUID `5422D89122D87986` to reappear (up to 20 seconds), then mounts it back to `/mnt/nmedia`. This reset sequence handles AMD USB controller quirks with certain USB hubs.

You will need to update the `DEVICE`, `UUID`, and `XHCI` variables in each script to match your system hardware.

These should be on your path e.g. `/usr/local/sbin`

```bash
./usb-poweroff.sh
./usb-poweron.sh
```

**Requirements:** `udisksctl` or equivalent, `sudo` or root privileges, write access to `/sys/bus/pci/drivers/xhci_hcd/*` (Proxmox host)
