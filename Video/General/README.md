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
- `ffprobe` (on `PATH`): required by `listuhd.sh` and `compress_amd_x265_aac.sh`.
- `mkvmerge` and `mkvextract` (from MKVToolNix): required by `apply-metadata.sh`, which uses them to read existing tags and `mkvpropedit` to write new ones. The bash compressor also calls `mkvmerge` for its stream-copy remux path.
- `jq` (on `PATH`): required by `compress_amd_x265_aac.sh`.
- `bc` (on `PATH`): required by `compress_amd_x265_aac.sh` for its size comparisons.

### PowerShell Scripts

- `HandBrakeCLI` (on `PATH`) and its importable user presets, for the two `hb *.json` profile files below.

### HandBrake Presets

The two JSON files in this folder are HandBrakeCLI user presets. The name a script passes to `--preset` is the `PresetName` field **inside** the JSON, which does not match the filename:

| File | `PresetName` | Used by |
|---|---|---|
| `hb 1080 profile.json` | `1080p AMD x265` | `Video/Foreign/hbcompress_amd_x265_aac.ps1` |
| `hb 1080p SDR AMD profile.json` | `1080p SDR AMD x265` | `Video/TV/hbcompress_1080p_amd_x265_aac.ps1` |

Both are HandBrake preset-list exports (`PresetList` array, `VersionMajor` 72) using `vce_h265` at quality 28, `main` profile, level 5.1, VFR, and a 1920x1080 picture. Audio falls back to `av_aac` for anything not in the copy mask. They differ in the copy mask: `hb 1080 profile.json` also copies `ac3`, `eac3`, `truehd`, `dts`, and `dtshd`, while the SDR variant copies only `aac` and `dtshd`. Both keep audio in `und`/`eng`/`jpn`/`kor`/`zho` and subtitles in `und`/`eng`/`jpn`, and both select `bt709` with limited range.

To change what those two compressors encode, edit the preset, not the script: the scripts pass `--preset` and add no encoder, quality, audio, or subtitle arguments of their own.

---

## Scripts

### fixSpecials.ps1

PowerShell utility that normalises `Specials` folders in a show library by renaming them to `Season 00` (the standard Jellyfin/Plex naming). Runs recursively from the current directory.

**What it does:**

- Walks all subdirectories looking for folders named exactly `Specials`.
- If no `Season 00` sibling exists: renames `Specials` to `Season 00`.
- If `Season 00` already exists: moves all files and subdirectories from `Specials` into `Season 00`, merging contents.
- Removes `Specials` after a successful merge (only if it is empty after moving).
- Writes a timestamped audit log (`specials_audit_<timestamp>.log`) in the working directory.
- Dry-run mode (`-DryRun`) previews all planned operations without making any changes.

**Parameters:**

| Parameter | Description |
|---|---|
| `-DryRun` | Preview mode; no files or directories are modified |
| `-Debug` | Enables verbose debug output with timestamps |

**Execution:**

```powershell
# Dry-run preview
.\fixSpecials.ps1 -DryRun

# Apply changes
.\fixSpecials.ps1
```

---

### dircleanup.sh

Bash equivalent of `dircleanup.ps1`. Removes orphaned trickplay directories, stale `.skip_<basename>` markers, and dangling `.nfo` sidecar files from a media library directory tree.

**What it does:**

- **Trickplay directories**: Directories named `trickplay` with no video files (`.mkv`, `.mp4`, `.avi`, `.ts`) in the parent directory are removed. Directories matching `<basename>.trickplay` where no video with that base name exists in the same directory are also removed.
- **Stale `.skip` markers**: Files matching `.skip_<basename>` are removed when no video file with that base name exists in the same directory.
- **Dangling NFO sidecars**: Files matching `<basename>.nfo` are removed when no video file with that base name exists in the same directory. Generic library-level NFO names (`movie.nfo`, `movies.nfo`, `tvshow.nfo`, `series.nfo`, `show.nfo`) are never removed.
- Respects `.skip` directory markers: directories containing a `.skip` file and all their subdirectories are excluded from processing.

**Parameters:**

| Parameter | Description |
|---|---|
| `--root <dir>` | Root directory to scan. Defaults to `.` |
| `--audit` | Preview mode; no files or directories are removed |
| `--debug` | Enable verbose debug output |

**Execution:**

```bash
# Always audit first to review planned removals
./dircleanup.sh --root <media-root>/Movies --audit

# Perform live cleanup
./dircleanup.sh --root <media-root>/Movies

# Run from current directory
./dircleanup.sh --audit
```

---

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
.\dircleanup.ps1 -Root "<media-root>\Movies" -Audit

# Perform live cleanup
.\dircleanup.ps1 -Root "<media-root>\Movies"

# Run from current directory
.\dircleanup.ps1 -Audit
```

---

### organize-chapters.ps1

Recursively moves `*_chapters.xml` files into a `chapters/` subdirectory within each folder that contains them.

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
.\organize-chapters.ps1 -Root "<media-root>\Movies" -DryRun
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
Set-Location "<media-root>\TV"
.\setairdate.ps1

# Dry-run preview
.\setairdate.ps1 -DryRun

# With debug output
.\setairdate.ps1 -DryRun -Debug
```

---

### dedup.ps1

Recursively scans TV show directories for duplicate episodes and removes them, keeping the best copy. Also removes associated sidecar files for deleted episodes. Supported episode-code patterns include `S##E##`, `S##E###`, `##x##`, `#x##`, and `##x###`.

**Important:** do not use this on Movies. A movie folder can intentionally hold both a 4K (2160p) and a 1080p encode of the same film; the priority-based logic would delete one of the intentional copies.

**What it does:**

- Scans all files recursively for episode codes.
- Groups files by episode code within the same directory.
- When duplicates are found, keeps the best file using this priority:
  - File type: `MKV > MP4 > TS > AVI`
  - File size: largest file wins when file types are equal.
- Deletes duplicate files along with any associated sidecar files (`.nfo`, `.srt`, `.jpg`, `.trickplay`, etc.).
- Outputs a summary report listing episodes kept, episodes deleted, and sidecar files removed.
- Audit mode (`-Audit`) previews all planned deletions without making any changes.

**Execution:**

```powershell
# Audit mode -- preview what would be deleted (recommended before first real run)
.\dedup.ps1 -Audit

# Perform actual deduplication
.\dedup.ps1
```

---

### compress_amd_x265_aac.sh

Batch video compression script using AMD GPU hardware acceleration (VAAPI) via `ffmpeg`. Targets `.mkv`, `.mp4`, and `.ts` files 950 MB or larger.

This file is byte-identical to `Video/TV/compress_amd_x265_aac.sh` and `Video/Foreign/compress_amd_x265_aac.sh`. The three copies are deliberately kept separate; do not collapse or deduplicate them.

**What it does:**

- Pre-flight checks for `ffprobe`, `ffmpeg`, `jq`, `bc`, and `mkvmerge`.
- Skips AV1-encoded files.
- Files already HEVC+AAC under 2.5 Mbps are not transcoded; whether they get a container-repair remux (stream copy) depends on `-r`.
- Interlace detection: reads `field_order` from stream metadata first, then a deep `idet` scan (~1000 frames from the 5-minute mark) when metadata is inconclusive.
- Encodes at QP 28 with `hevc_vaapi`; audio is stream-copied.
- Replaces the original only if the new file is **more than 10% smaller** (`new_size * 10 < orig_size * 9`), which is a double-compression guard.
- Skips UHD and AV1 sources.
- Supports recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Runs 1 encoding job at a time.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output |
| `-r` / `--remux-check` | Remux already-compliant files for container repair instead of leaving them untouched. Requires AAC audio. Off by default |

**Execution:**

```bash
cd <media-root>
./compress_amd_x265_aac.sh

# With debug output
./compress_amd_x265_aac.sh --debug
```

---

### listuhd.sh

Small read-only helper that prints the paths of any MKV whose coded height is above 1080p. It changes nothing.

**What it does:**

- Scans `.mkv` files only, via `find -iname '*.mkv'`. It does not look at `.mp4` or `.ts`.
- Reads the coded height of the first video stream with `ffprobe` (so 1088 counts as 1088, not 1080).
- Prints any file whose height is greater than 1100. Anything at or below 1100 is treated as not-UHD, which means true 1080p encodes that happen to be coded at 1088 are still excluded.
- Requires only `ffprobe`.

**Execution:**

```bash
# Scan the current directory tree
./listuhd.sh

# Output is a plain list of paths, one per line
./listuhd.sh > uhd.txt
```

---

### fixunnamedvideo.sh

Renames the single extension-less file in a release-group folder to match the folder name plus `.mkv`. This is a repair step for downloads that arrive with the video file unnamed.

**What it does:**

- Scans `--root` for directories whose name ends in one of the given suffixes (default `AnoZu`, i.e. the release group).
- Skips any folder that already contains a recognised video file, so a healthy release is never touched.
- Skips a folder unless it contains **exactly one** extension-less file. Zero or more than one is ambiguous and is skipped with a reason.
- Renames that file to `<foldername>.mkv`. The target container is always `.mkv`; the input extension is never used as the name source.
- Refuses to overwrite: if the target already exists the folder is skipped.
- Uses `mv -n` and then verifies the result, reporting `ERROR:` if the rename did not take.
- Iterates with process substitution rather than a pipe, because a piped `while` would discard the state it sets.

**Parameters:**

| Parameter | Description |
|---|---|
| `-r` / `--root <dir>` | Folder root to scan. **Set this** -- the script's built-in default is one machine's download path |
| `--suffix <text>` | Folder-name suffix to match; repeatable. Default `AnoZu` |
| `--audit` | Print what would be renamed, change nothing |
| `-d` / `--debug` | Verbose output |

**Execution:**

```bash
# Preview first -- this changes nothing
./fixunnamedvideo.sh --audit

# Then run it against your download root
./fixunnamedvideo.sh -r <media-root>/downloads/completed/Series
```

---

### apply-metadata.sh

Unified NFO-to-MKV-tag applier for both movies and episodes, which also remuxes and cleans up track names. It decides MOVIE vs EPISODE from the NFO's XML root element, so it replaces the retired `apply-episode-metadata.sh` and `apply-movie-metadata.sh` and their PowerShell equivalents.

**What it does:**

- Requires `xmlstarlet`, `mkvpropedit`, `mkvmerge`, `mkvextract`, `jq`, and `ffmpeg`.
- Reads `<basename>.nfo` for the title/plot, falling back to the folder-level `movie.nfo` for movies. Episode metadata comes from `episodedetails` (`showtitle`, `title`, `season`, `episode`, `aired`, `plot`); when `showtitle` is absent it resolves the series name from the parent folder.
- An unrecognised NFO root element is a warning and skips tagging for that file rather than failing the run.
- Parses XML BOM-safe, and excludes extras by filename suffix and Jellyfin extras directory, the same 8 suffixes and 13 directories the compressors use.
- **Remuxes when needed**: if `mkvmerge -J` fails, or a track UID is missing/zero/duplicated, the file is remuxed with `ffmpeg` to normalise it. The original mtime is preserved.
- **Cleans track names** by UID, stripping release-group and tracker junk (`[Erai-raws]`, `[SubsPlease]`, `[Judas]`, `[EMBER]`, `[NC-Raws]`, and similar) plus `CR `-style prefixes, and forces the video track name to `Video`.
- **Prevents double processing**: it reads the tags already on the file with `mkvextract` and skips the file when the existing series/show/season/episode/title (episodes) or title/description (movies) already match what the NFO says.
- Writes the container title and the full tag set with `mkvpropedit`, then restores the original mtime.

**Parameters:**

| Parameter | Description |
|---|---|
| `--dry-run` | Report what would change, change nothing |
| `--debug` | Verbose output |
| `--audit-log <file>` | Write an audit log to the given path |

**Execution:**

```bash
./apply-metadata.sh                   # apply to the current directory
./apply-metadata.sh --dry-run         # report what would change, change nothing
./apply-metadata.sh --debug           # verbose
./apply-metadata.sh --audit-log "./audit.log"
```

> **NFO caveat:** an NFO is not self-describing. The root element (`movie` vs `episodedetails`) is the only thing that decides how the file is treated, so a mis-named or mismatched NFO produces wrong tags on the right file. Use `--dry-run` on a new library first.

---

### sync_robo.ps1

Windows-side robocopy mirror of the media library, for when rsync is not an option (a plain SMB share, for example).

**What it does:**

- Mirrors source to destination with `/MIR`, which deletes destination files that are no longer in the source. That is the point of a mirror, but it means a wrong or unmounted source will empty the destination.
- `/FFT` for FAT/exFAT timestamp drift, `/Z` for restartable transfers, `/DCOPY:T` for directory timestamps, and `/COPY:DAT` so permissions, ownership, and ACLs are **not** copied.
- `/XA:SH` skips system and hidden files; `*.tmp` and `*.temp` are excluded.
- Dotfiles are included, because the exclusion uses `*` rather than `*.*`.
- `/R:1 /W:1` retries once after a 1 second wait.

**Parameters:**

| Parameter | Description |
|---|---|
| `-Source <path>` | Source to mirror from |
| `-Destination <path>` | Mirror destination |
| `-DryRun` | Report what would be copied without copying |
| `-Log` | Write robocopy output to a log file |

**Execution:**

```powershell
.\sync_robo.ps1 -Source "<media-root>" -Destination "<usb-share>\Video"

# Preview first
.\sync_robo.ps1 -Source "<media-root>" -Destination "<usb-share>\Video" -DryRun
```

> Because `-Destination` defaults to a second drive letter, set both paths explicitly. `/MIR` against an empty or wrong source is destructive.
