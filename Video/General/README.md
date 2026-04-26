# General Video Utility Scripts

Shared utility scripts used across Movies, TV, and Foreign content hierarchies. These scripts are not tied to a specific content type and can be run against any video library directory.

## DISCLAIMER

Use at your own risk. Some scripts perform destructive operations on files. Always test with dry-run or audit mode first and maintain backups before running any script.

---

## Requirements

### All Scripts

- PowerShell 7.0 or later (PowerShell scripts)
- Bash 4+ (Bash scripts)

### Bash Scripts

- `xmlstarlet`: XML query utility.
  - Linux: `sudo apt install xmlstarlet`
- GNU coreutils (`stat -c`, `date -d`) or macOS equivalents.

---

## Scripts

### dircleanup.ps1

PowerShell utility that removes three categories of orphaned items from a media library directory tree: trickplay directories with no corresponding video file, stale `.skip_<basename>` markers for videos that no longer exist, and dangling `.nfo` sidecar files for videos that no longer exist.

**What it does:**

- **Trickplay directories**: Directories named `trickplay` with no video files (`.mkv`, `.mp4`, `.avi`, `.ts`) in the parent directory are removed. Directories matching `<basename>.trickplay` where no video with that base name exists in the same directory are also removed.
- **Stale `.skip` markers**: Files matching `.skip_<basename>` are removed when no video file with that base name exists in the same directory.
- **Dangling NFO sidecars**: Files matching `<basename>.nfo` are removed when no video file with that base name exists in the same directory. Generic library-level NFO names (`movie.nfo`, `movies.nfo`, `tvshow.nfo`, `series.nfo`, `show.nfo`) are never removed.
- Respects `.skip` directory markers: directories containing a `.skip` file and all their subdirectories are excluded from processing.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Root` | No | `.` | Root directory to scan |
| `-Audit` | No | | Preview mode; no files or directories are removed |
| `-Debug` | No | | Enable verbose debug output |

**Execution:**

```powershell
# Always audit first to review planned removals
.\dircleanup.ps1 -Root "Z:\Media\Movies" -Audit

# Perform live cleanup
.\dircleanup.ps1 -Root "Z:\Media\Movies"

# Run from current directory
.\dircleanup.ps1 -Audit
```

---

### organize-chapters.sh

Bash utility that recursively moves `*_chapters.xml` files into a `chapters/` subdirectory within each folder that contains them.

**What it does:**

- Walks the directory tree from the specified root.
- For each directory containing `*_chapters.xml` files, creates a `chapters/` subdirectory and moves all matching files into it.
- Skips directories containing a `.skip` marker file (and all their subdirectories).
- Skips any directory already named `chapters` to avoid redundant nesting.
- Dry-run mode (`--dry-run`) previews all planned moves without making any changes.
- Prints a summary of files moved and directories skipped.

**Parameters:**

| Parameter | Description |
|---|---|
| `--root <dir>` | Root directory to scan. Defaults to `.` |
| `--dry-run` | Preview mode; no files are moved |
| `--debug` | Enable verbose debug output |

**Execution:**

```bash
# Run from within a media directory
./organize-chapters.sh

# Dry-run preview
./organize-chapters.sh --dry-run

# Specify a root directory
./organize-chapters.sh --root /mnt/media/Movies --dry-run
```

---

### organize-chapters.ps1

PowerShell equivalent of `organize-chapters.sh`. Recursively moves `*_chapters.xml` files into a `chapters/` subdirectory within each folder that contains them.

**What it does:**

- Walks the directory tree from the specified root.
- For each directory containing `*_chapters.xml` files, creates a `chapters/` subdirectory and moves all matching files into it.
- Skips directories containing a `.skip` marker file (and all their subdirectories).
- Skips any directory already named `chapters` to avoid redundant nesting.
- Dry-run mode (`-DryRun`) previews all planned moves without making any changes.
- Prints a summary of files moved and directories skipped.

**Parameters:**

| Parameter | Description |
|---|---|
| `-Root <path>` | Root directory to scan. Defaults to `.` |
| `-DryRun` | Preview mode; no files are moved |
| `-Debug` | Enable verbose debug output |

**Execution:**

```powershell
# Run from within a media directory
.\organize-chapters.ps1

# Dry-run preview
.\organize-chapters.ps1 -DryRun

# Specify a root directory
.\organize-chapters.ps1 -Root "Z:\Media\Movies" -DryRun
```

---

### setairdate.sh

Bash utility that sets file timestamps on TV episode video and NFO file pairs based on the air date recorded in the NFO sidecar.

**What it does:**

- Recursively scans for MKV and MP4 video files.
- For each video, finds the matching `<basename>.nfo` and parses the `<aired>` element (YYYY-MM-DD format).
- Sets both the video file and the NFO file `mtime` to midday (12:00:00) on the aired date.
- Rejects NFO `<aired>` dates more than 30 days in the future as corrupt metadata (e.g. typos like `2038-01-01`); retroactively corrects files already stamped by a previous bad run.
- If no valid date is found in the NFO, falls back to the earliest existing `mtime` of the two files. If those timestamps are also more than 30 days in the future, uses the parent folder creation/birth date instead.
- A final guard skips (with a warning) any file whose fully resolved date is still more than 30 days in the future.
- Skips video files with no matching NFO.

**Requirements:**

- `xmlstarlet`
- Bash 4+
- GNU coreutils (`stat -c`, `date -d`) or macOS equivalents

**Parameters:**

| Parameter | Description |
|---|---|
| `--debug` | Enable verbose debug output |

**Execution:**

```bash
# Run from within the TV directory
./setairdate.sh

# With debug output
./setairdate.sh --debug
```

---

### setairdate.ps1

PowerShell equivalent of `setairdate.sh`. Sets file timestamps on TV episode video and NFO file pairs based on the NFO air date.

**What it does:**

- Recursively scans for MKV and MP4 video files.
- For each video, finds the matching `<basename>.nfo` and reads the `<aired>` element.
- Sets both the video file and the NFO file `CreationTime` and `LastWriteTime` to midday (12:00:00) on the aired date.
- Rejects NFO `<aired>` dates more than 30 days in the future as corrupt metadata (e.g. typos like `2038-01-01`); retroactively corrects files already stamped by a previous bad run.
- If no valid date is found in the NFO, falls back to the earliest existing timestamp across both files. If those timestamps are also more than 30 days in the future, uses the parent folder `CreationTime` instead.
- A final guard skips (with a warning) any file whose fully resolved date is still more than 30 days in the future.
- Skips video files with no matching NFO.
- Dry-run mode (`-DryRun`) performs all processing steps but writes no timestamp changes.

**Parameters:**

| Parameter | Description |
|---|---|
| `-DryRun` | Preview mode; no file timestamps are modified. |
| `-Debug` | Enables verbose debug output to the console. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\setairdate.ps1

# Dry-run preview
.\setairdate.ps1 -DryRun

# With debug output
.\setairdate.ps1 -DryRun -Debug
```

---

### setreleasedate.sh

Bash utility that sets file timestamps on movie video and NFO file pairs based on the release date recorded in the NFO sidecar.

**What it does:**

- Recursively scans for MKV and MP4 video files.
- For each video, finds `<basename>.nfo`; falls back to `movie.nfo` in the same directory if the named NFO is absent.
- Parses `<premiered>` (preferred, YYYY-MM-DD) or `<year>` (fallback, resolved to January 1 of that year).
- Sets both the video file and the NFO file `mtime` to midday (12:00:00) on the resolved date.
- Rejects NFO dates more than 30 days in the future as corrupt metadata (e.g. typos like `2038-01-01`). When the `<premiered>` year is suspect but `<year>` is earlier and valid, substitutes that year while keeping the original month and day.
- If no valid date is found in the NFO, falls back to the earliest existing `mtime` of the two files. If those timestamps are also more than 30 days in the future, uses the parent folder creation/birth date instead.
- A final guard skips (with a warning) any file whose fully resolved date is still more than 30 days in the future.
- Skips files in `extras` subdirectories and files with non-feature suffixes (`-trailer`, `-featurette`, `-behindthescenes`, etc.) - these are counted as **Filtered**, not Skipped.
- Skips video files with no matching NFO - these are counted as **Skipped (no NFO)** and optionally recorded via `--nonfo`.
- Summary line reports `Processed`, `Skipped (no NFO)`, `Filtered (extras/trailers)`, and `Errors` separately.

**Requirements:**

- `xmlstarlet`
- Bash 4+
- GNU coreutils (`stat -c`, `date -d`) or macOS equivalents

**Parameters:**

| Parameter | Description |
|---|---|
| `--debug` | Enable verbose debug output |
| `--nonfo <file>` | Append the path of each video with no matching NFO to `<file>` (created if absent; parent directory must exist) |

**Execution:**

```bash
# Run from within the Movies directory
./setreleasedate.sh

# With debug output
./setreleasedate.sh --debug

# Record files with no NFO
./setreleasedate.sh --nonfo /tmp/missing_nfo.txt

# Combined
./setreleasedate.sh --nonfo /tmp/missing_nfo.txt --debug
```

---

### setreleasedate.ps1

PowerShell equivalent of `setreleasedate.sh`. Sets file timestamps on movie video and NFO file pairs based on the release date in the NFO sidecar.

**What it does:**

- Recursively scans for MKV and MP4 video files.
- For each video, finds `<basename>.nfo`; falls back to `movie.nfo` in the same directory if the named NFO is absent.
- Reads `<premiered>` (preferred) or `<year>` (fallback, resolved to January 1 of that year).
- Sets both the video file and the NFO file `CreationTime` and `LastWriteTime` to midday (12:00:00) on the resolved date.
- Rejects NFO dates more than 30 days in the future as corrupt metadata (e.g. typos like `2038-01-01`). When the `<premiered>` year is suspect but `<year>` is earlier and valid, substitutes that year while keeping the original month and day.
- If no valid date is found in the NFO, falls back to the earliest existing timestamp across both files. If those timestamps are also more than 30 days in the future, uses the parent folder `CreationTime` instead.
- A final guard skips (with a warning) any file whose fully resolved date is still more than 30 days in the future.
- Skips files in `extras` subdirectories and files with non-feature suffixes (`-trailer`, `-featurette`, `-behindthescenes`, etc.) - these are counted as **Filtered**, not Skipped.
- Skips video files with no matching NFO - these are counted as **Skipped (no NFO)** and optionally recorded via `-NoNfo`.
- Summary line reports `Processed`, `Skipped (no NFO)`, `Filtered (extras/trailers)`, and `Errors` separately.

**Parameters:**

| Parameter | Description |
|---|---|
| `-DryRun` | Preview mode; no file timestamps are modified. |
| `-Debug` | Enables verbose debug output to the console. |
| `-NoNfo <path>` | Append the path of each video with no matching NFO to `<path>` (created if absent; parent directory must exist). Optional. |

**Execution:**

```powershell
# Run from within the Movies directory
Set-Location "Z:\Media\Movies"
.\setreleasedate.ps1

# Dry-run preview
.\setreleasedate.ps1 -DryRun

# With debug output
.\setreleasedate.ps1 -DryRun -Debug

# Record files with no NFO
.\setreleasedate.ps1 -NoNfo C:\temp\missing_nfo.txt

# Combined
.\setreleasedate.ps1 -NoNfo C:\temp\missing_nfo.txt -DryRun -Debug
```
