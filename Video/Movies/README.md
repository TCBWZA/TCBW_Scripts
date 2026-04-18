# Movies Video Scripts

Compression, deduplication, and maintenance scripts for movie content. Scripts convert video to x265 (HEVC) with AAC audio, detect and remove duplicates, and identify corrupt MKV files.

## DISCLAIMER

Use at your own risk. These scripts perform destructive operations on video files. Always test on non-critical files first and maintain backups of your original content before running any script.

---

## Requirements

### All Scripts

- `ffmpeg` / `ffprobe`: v4.0 or later, must be on system PATH.
  - Linux: `sudo apt install ffmpeg`
  - Windows: `winget install FFmpeg` or `choco install ffmpeg`
  - Verify: `ffmpeg -version`
- `jq`: JSON query utility (Bash scripts only).
  - Linux: `sudo apt install jq`
  - Windows: `scoop install jq` or `choco install jq`

### Bash Scripts (AMD GPU)

- Linux/Unix with Bash 5+
- AMD GPU with VAAPI support (`/dev/dri/renderD128` must be accessible)

### PowerShell Scripts

- PowerShell 7.0 or later
- `HandBrakeCLI` is not required by any script in this folder

---

## Skip File Behaviour

All scripts respect two skip markers:

| Marker | Location | Effect |
|---|---|---|
| `.skip` | Parent movie directory | The entire movie directory is skipped. No files inside are processed. |
| `.skip_<basename>` | Movie directory | That specific file is skipped. The basename is the full filename without extension. |

Example: to skip `The.Movie.(2020).mkv`, create `.skip_The.Movie.(2020)` in the same directory.

Scripts automatically create a `.skip_<basename>` marker when a transcode produces a file that is not smaller than the original, preventing repeated failed attempts on that file.

---

## Scripts

### compress_amd_x265_aac.sh

Batch video compression script using AMD GPU hardware acceleration (VAAPI) via `ffmpeg`. Targets `.mkv`, `.mp4`, and `.ts` files that are 5 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, and video bitrate.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Performs two-pass interlace/telecine detection (metadata fast pass, then deep frame scan).
- Encodes with `hevc_vaapi` at QP 22, VBR 1800k / max 2000k.
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs.

No command-line parameters. Run from within the target directory or modify the path constants at the top of the script.

**Execution:**

```bash
cd /mnt/media/Movies
./compress_amd_x265_aac.sh
```

---

### compress_amd_x265_aac.ps1

PowerShell wrapper for AMD VAAPI-based compression workflows. Provides the same logic as `compress_amd_x265_aac.sh` for use on systems where PowerShell is preferred.

**What it does:**

- Targets `.mkv` files 5 GB or larger.
- Checks codec and bitrate; converts files that are not HEVC+AAC or exceed 2.5 Mbps.
- Interlace detection via `ffprobe` stream metadata.
- Encodes with `hevc_amf` via AMD VCE (`-hwaccel dxva2`).
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs (configurable via `$MaxJobs` at top of script).

No command-line parameters. Edit the threshold constants at the top of the script before running.

**Execution:**

```powershell
Set-Location "Z:\Media\Movies"
.\compress_amd_x265_aac.ps1
```

---

### compress_qsv_x265_aac.ps1

PowerShell compression script using Intel Quick Sync Video (QSV) encoding. Targets `.mkv` and `.ts` files 5 GB or larger.

**What it does:**

- Checks codec, audio codec, and bitrate; converts files that are not HEVC+AAC or exceed 2.5 Mbps.
- Interlace detection via `ffprobe`.
- Encodes with `hevc_qsv`.
- Configurable optional temporary directory (`$TempDir`) for intermediate files.
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs (configurable via `$MaxJobs` at top of script).

No command-line parameters. Edit the threshold and path constants at the top of the script before running.

**Execution:**

```powershell
Set-Location "Z:\Media\Movies"
.\compress_qsv_x265_aac.ps1
```

---

### clean_compress_amd_x265_aac.sh

Bash compression script with intelligent audio and subtitle track filtering. Targets `.mkv`, `.mp4`, and `.ts` files 5 GB or larger.

**What it does:**

- All the same compression logic as `compress_amd_x265_aac.sh`.
- Adds intelligent track filtering: keeps only English-language (`eng`) and untagged (`und`) audio and subtitle streams; removes foreign-language variants.
- Dynamic stream discovery works correctly even when tracks are not in standard order.
- Encodes with `hevc_vaapi` at QP 22, VBR 1800k / max 2000k.

No command-line parameters.

**Execution:**

```bash
cd /mnt/media/Movies
./clean_compress_amd_x265_aac.sh
```

---

### clean_compress_qsv_x265_aac.ps1

PowerShell compression script with intelligent audio and subtitle track filtering, using Intel Quick Sync Video. Targets `.mkv`, `.mp4`, and `.ts` files 5 GB or larger.

**What it does:**

- All the same compression logic as `compress_qsv_x265_aac.ps1`.
- Adds intelligent track filtering: keeps only English (`eng`) and untagged (`und`) audio and subtitle streams.
- Dynamic stream discovery.
- Encodes with `hevc_qsv`.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-MAX_JOBS` | No | `2` | Maximum number of parallel encoding jobs |
| `-DEBUG` | No | `$false` | Enable verbose debug output |

**Execution:**

```powershell
# Run with defaults (2 parallel jobs)
Set-Location "Z:\Media\Movies"
.\clean_compress_qsv_x265_aac.ps1

# Override parallel job count
.\clean_compress_qsv_x265_aac.ps1 -MAX_JOBS 4

# Run with debug output
.\clean_compress_qsv_x265_aac.ps1 -DEBUG $true
```

---

### hbcompress_amd_x265_aac.ps1

PowerShell compression script using AMD GPU (AMF/VCE) hardware acceleration with MKV container repair, file-lock detection, and atomic replacement. Targets `.mkv`, `.mp4`, and `.ts` files 1 GB or larger.

**What it does:**

- Checks video codec, audio codec, and bitrate; converts files not already HEVC+AAC or exceeding 2.5 Mbps.
- Two-pass interlace detection: fast metadata check first, then idet frame scan skipping the first 5 minutes to avoid intros/credits.
- MKV container health check: broken containers (bad timestamps, problematic subtitle codecs, corrupt duration) are remuxed before transcoding.
- File-lock detection: files currently open by other processes are skipped.
- Atomic replacement: writes to a temp file and swaps in place only when the result is smaller and valid.
- 4K (UHD) and AV1 guards: those files are skipped automatically.
- `.skip` directory marker and `.skip_<basename>` per-file marker support.
- Encodes with `hevc_amf` via AMD VCE.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Debug` | No | | Enable verbose debug output |

**Execution:**

```powershell
Set-Location "Z:\Media\Movies"
.\hbcompress_amd_x265_aac.ps1

# Run with debug output
.\hbcompress_amd_x265_aac.ps1 -Debug
```

---

### dedup.ps1

Recursively scans movie directories for duplicate video files and removes them, keeping the best copy. Also removes associated sidecar files for deleted duplicates.

**What it does:**

- Scans each movie folder for multiple video files (`.mkv`, `.mp4`, `.avi`, `.ts`).
- When duplicates are found, keeps the best file using this priority:
  - File type: `MKV > MP4 > AVI > TS`
  - File size: largest file wins when file types are equal.
- Deletes duplicate files along with any associated sidecar files (`.nfo`, `.srt`, `.jpg`, `.trickplay`, etc.) and orphaned `trickplay` folders.
- Outputs a summary report listing files kept, files deleted, and sidecars removed.
- Audit mode (`-Audit`) previews all planned deletions without making any changes.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Audit` | No | | Dry-run mode; no files are deleted. Prints what would be removed. |

**Execution:**

```powershell
# Audit mode -- preview what would be deleted (recommended before first real run)
.\dedup.ps1 -Audit

# Perform actual deduplication
.\dedup.ps1
```

---

### findcorrupt.ps1

PowerShell utility that recursively scans a directory for corrupt MKV files using `ffprobe`. Logs results to an optional CSV file and uses Radarr to delete and re-download flagged movies.

**What it does:**

- Runs `ffprobe` on each MKV file to detect two categories of problem:
  - **Corruption** - non-zero `ffprobe` exit code, or output containing `Invalid`, `error`, or `failed`.
  - **No audio** - file has zero audio streams (treated as corrupt for replacement purposes).
- Parses the movie title and year from the filename (expects `Title (Year).mkv` format) to match against Radarr.
- Prints the path of each corrupt file to the console.
- Optionally writes corrupt file paths to a CSV log.
- Calls the Radarr API to delete the movie file, re-monitor the movie, and trigger a `MovieSearch` command.
- Logs movies that cannot be matched in Radarr to a separate missing-movies log.
- Audit mode (`-Audit`) performs no destructive actions; prints what would have happened instead.
- Radarr integration is always active. The script verifies Radarr connectivity at startup and exits with error code 3 if Radarr is unreachable. Use `-Audit` to scan without triggering replacements.
- Exits with a structured exit code:
  - `0`: Completed, no corrupt files found.
  - `1`: One or more corrupt files detected.
  - `2`: `ffprobe` missing or inaccessible.
  - `3`: Radarr API error or unreachable.
  - `4`: Unexpected exception.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Root` | No | `.\` | Root directory to scan for MKV files |
| `-CsvFile` | No | | CSV log file path (leave empty to disable CSV logging) |
| `-Append` | No | | Append to CSV instead of overwriting |
| `-Audit` | No | | Dry-run mode; no deletions or Radarr API calls (connectivity check still runs) |
| `-RadarrUrl` | No | `http://docker:7878` | Radarr base URL |
| `-RadarrLogFile` | No | `D:\Work\RadarrLog.txt` | Log file for Radarr actions |
| `-MissingMovieLog` | No | `D:\Work\MissingMovies.txt` | Log file for unmatched movies |
| `-Help` / `-ShowHelp` / `-?` | No | | Show built-in help |

**Configuration:**

Set `$RadarrApiKey` inside the script before running:

```powershell
$RadarrApiKey = "YOUR_API_KEY_HERE"
```

**Execution:**

```powershell
# Show built-in help
.\findcorrupt.ps1 -Help

# Audit mode -- detect corrupt files, make no changes
.\findcorrupt.ps1 -Root "Z:\Media\Movies" -Audit

# Scan and log corrupt files to CSV (Radarr replacement also runs)
.\findcorrupt.ps1 -Root "Z:\Media\Movies" -CsvFile ".\corrupt.csv"

# Full production run with all logs and custom Radarr URL
.\findcorrupt.ps1 `
    -Root "Z:\Media\Movies" `
    -CsvFile "D:\Logs\corrupt.csv" `
    -RadarrUrl "http://192.168.1.100:7878" `
    -RadarrLogFile "D:\Logs\RadarrLog.txt" `
    -MissingMovieLog "D:\Logs\MissingMovies.txt"
```

**Radarr integration:**

Set `$RadarrApiKey` and configure `-RadarrUrl`. The script always verifies Radarr connectivity before scanning. When a corrupt file is found (and not in `-Audit` mode), the script:

1. Parses the movie title and year from the filename.
2. Looks up the movie in Radarr by title and year.
3. Deletes the movie file record from Radarr.
4. Re-monitors the movie.
5. Dispatches a `MovieSearch` command so Radarr queues a replacement download.

Movies that cannot be matched in Radarr are written to the missing-movies log for manual review.

Use `-Audit` first to verify which files are flagged as corrupt before running a live replacement pass.

---

### remuxmp4.sh

Bash script that remuxes MP4 files into MKV containers without re-encoding. Intended for files that are correctly encoded but in the wrong container.

**What it does:**

- Targets `.mp4` files between 500 MB and 5 GB. Files outside this range are skipped - files below 500 MB are too small to be movies, and files above 5 GB are left for the compress scripts to handle with a full transcode.
- Skips files where an MKV with the same base name already exists.
- Detects `mov_text` subtitles (an MP4-only format not valid in MKV) and automatically transcodes them to SRT; all other subtitle streams are stream-copied.
- Maps only English (`eng`) and undefined (`und`) language audio and subtitle streams. Falls back to all audio streams if none are tagged.
- Copies all video, audio, subtitle, and attachment streams (e.g. embedded TTF/OTF fonts) into a Matroska container.
- Writes to a `[Trans].tmp` temp file; on success, renames to `.mkv` and deletes the original `.mp4`.
- Preserves the original file modification time.
- After a successful remux, runs `apply-movie-metadata.sh` from the same directory to apply NFO metadata to the new MKV.
- Files with no audio streams are treated as corrupt: the file is deleted and a Radarr replacement search is triggered (same Radarr flow as `findcorrupt.ps1`).
- Respects `.skip` directory markers.

**Configuration:**

Edit the following constants near the top of the script before running:

```bash
RADARR_URL="http://docker:7878"
RADARR_API_KEY="YOUR_API_KEY_HERE"
RADARR_LOG="/tmp/remux_radarr.log"
MISSING_LOG="/tmp/remux_missing.log"
```

**Requirements:** `ffmpeg`, `ffprobe`, `jq`, `curl`, `python3` (for URL encoding; falls back to `sed` if unavailable).

**Execution:**

```bash
cd /mnt/media/Movies
./remuxmp4.sh

# Debug mode
./remuxmp4.sh --debug
```

---

### apply-movie-metadata.sh

Bash script that applies movie metadata from NFO sidecar files into MKV container tags using `mkvpropedit`.

**What it does:**

- Reads metadata from `<basename>.nfo` (preferred) or `movie.nfo` (fallback) for each MKV.
- Falls back to the directory name when no `<title>` element is found in the NFO.
- Writes title and year tags into the MKV container using `mkvpropedit`.
- Preserves the original file modification time after writing.
- Supports dry-run mode (`--dry-run`) and optional audit log output.
- Proxmox-safe: no process substitution, compatible with strict shell environments.

**Execution:**

```bash
cd /mnt/media/Movies
./apply-movie-metadata.sh

# Dry-run mode
./apply-movie-metadata.sh --dry-run
```

---

### Apply-MovieMetadata.ps1

PowerShell equivalent of `apply-movie-metadata.sh`. Applies movie metadata from NFO sidecar files into MKV container tags using `mkvpropedit`.

**What it does:**

- Reads metadata from `<basename>.nfo` (preferred) or `movie.nfo` (fallback) for each MKV.
- Falls back to the directory name when no `<title>` element is found.
- Writes title and year tags into the MKV container using `mkvpropedit`.
- Preserves the original `CreationTime` and `LastWriteTime` after writing.
- Supports dry-run mode (`-DryRun`) and optional audit log output (`-AuditLogPath`).
- Literal-path safe and deterministic.

**Requirements:** `mkvtoolnix` (`mkvpropedit`, `mkvinfo`) - install with `choco install mkvtoolnix`.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-DryRun` | No | | Process files but do not write any changes to disk |
| `-Debug` | No | | Enable verbose debug output |
| `-AuditLogPath` | No | `""` | Path to audit log file; logging is disabled when empty |

**Execution:**

```powershell
Set-Location "Z:\Media\Movies"
.\Apply-MovieMetadata.ps1

# Dry-run mode
.\Apply-MovieMetadata.ps1 -DryRun

# With audit log
.\Apply-MovieMetadata.ps1 -AuditLogPath ".\movie_audit.log"
```

---

## Encoding Settings (Compression Scripts)

| Setting | Value |
|---|---|
| Video codec (AMD/VAAPI) | `hevc_vaapi` |
| Video codec (Intel QSV) | `hevc_qsv` |
| Quality (ffmpeg) | QP 22 |
| Video bitrate target | 1800 kbps |
| Video bitrate max | 2000 kbps |
| Audio codec | AAC |
| Audio bitrate (stereo) | 160 kbps |
| Container | Matroska (`.mkv`) |
