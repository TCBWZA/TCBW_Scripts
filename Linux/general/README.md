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

`pct` is part of Proxmox VE and is already present on any Proxmox host. `tar`, `gzip`, `find`, and standard coreutils (`chown`, `chmod`) are pre-installed on Debian/Ubuntu.

---

## Common behavior

All `sync_*.sh` and `backup_*.sh` scripts skip files with a `.tmp` extension (`--exclude='*.tmp'` for rsync; `--exclude='*.tmp'` for tar).

---

## Scripts

### sync.sh

Orchestrator that calls all nmedia sync scripts in sequence. Run this instead of the individual sync scripts when doing a full backup pass to nmedia.

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
7. `sync_tv.sh`

---

### sync_tv.sh

Rsyncs the TV library from `/main/media/Video/TV/` to `/mnt/nmedia/Media/Video/TV`. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_tv.sh
```

**Requirements:** `rsync`

---

### sync_etv.sh

Rsyncs the TV library from `/main/media/Video/TV/` to `/mnt/emedia/Media/Video/TV`. Secondary/emergency backup to the emedia mount. Aborts if `/mnt/emedia` is not mounted. Not included in the `sync.sh` orchestrator; run manually when syncing to emedia.

```bash
./sync_etv.sh
```

**Requirements:** `rsync`

---

### sync_movies.sh

Rsyncs the movie library from `/main/media/Video/Movies/` to `/mnt/nmedia/media/Video/Movies`. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_movies.sh
```

**Requirements:** `rsync`

---

### sync_anime.sh

Rsyncs the anime library from `/main/media/Video/Anime/` to `/mnt/nmedia/Media/Video/Anime`. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_anime.sh
```

**Requirements:** `rsync`

---

### sync_audiobooks.sh

Rsyncs the audiobook library from `/main/media/audiobooks/` to `/mnt/nmedia/Media/audiobooks`. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_audiobooks.sh
```

**Requirements:** `rsync`

---

### sync_books.sh

Rsyncs the book library from `/main/media/books/` to `/mnt/nmedia/Media/books`. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_books.sh
```

**Requirements:** `rsync`

---

### sync_backups.sh

Rsyncs system backup data from `/mnt/sysdata_backups/` to `/mnt/nmedia/DATA/sysdata_backups/`. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_backups.sh
```

**Requirements:** `rsync`

---

### sync_docker.sh

Stops LXC container 100 (if running), rsyncs the Docker data volume from `/mnt/sysdata_docker/` to `/mnt/nmedia/DATA/sysdata_docker/`, then restarts the container if it was originally running. Aborts if `/mnt/nmedia` is not mounted.

```bash
./sync_docker.sh
```

**Requirements:** `rsync`, `pct` (Proxmox host only)

---

### backup_docker.sh

Stops LXC container 100 (if running), compresses `/mnt/sysdata_docker` into a tar archive on `/mnt/nmedia/pve/`, then restarts the container if it was originally running. Moves any previous backup to a `hold/` subfolder before writing the new one.

Supports three compressors - configure the `COMPRESSOR` variable at the top of the script:

| Value | Tool | Notes |
|---|---|---|
| `pigz` | pigz | Parallel gzip; recommended. Requires `pigz` to be installed. |
| `zstd` | zstd | Best compression ratio. Requires `zstd`. |
| `gzip` | gzip | Standard; no extra dependencies. |

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

---

### backup_root.sh

Archives `/root` to `/mnt/nmedia/pve/root-backup.tar.gz` using `tar`. Aborts if `/mnt/nmedia` is not mounted. Run on the Proxmox host to back up the root home directory.

```bash
./backup_root.sh
```

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
