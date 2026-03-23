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
- Encodes with `hevc_vaapi`.
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

### clean_compressUHD_qsv_x265_aac.ps1

PowerShell compression script specialised for 4K / UHD content using Intel Quick Sync Video. Targets `.mkv`, `.mp4`, and `.ts` files 8 GB or larger (4K content threshold).

**What it does:**

- Same track filtering and compression logic as `clean_compress_qsv_x265_aac.ps1` but with a 4K-specific bitrate threshold of 20 Mbps and H.265 profile 6.2.
- Only processes files where the video stream is 3840 pixels wide or wider.
- Encodes with `hevc_qsv` at QP 24, profile 6.2.
- Replaces original only if the new file is smaller.
- Runs parallel jobs (configurable).

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-MAX_JOBS` | No | `2` | Maximum number of parallel encoding jobs |
| `-DEBUG` | No | `$false` | Enable verbose debug output |

**Execution:**

```powershell
# Run with defaults
Set-Location "Z:\Media\Movies"
.\clean_compressUHD_qsv_x265_aac.ps1

# Limit to 1 job (lower resource usage)
.\clean_compressUHD_qsv_x265_aac.ps1 -MAX_JOBS 1

# Run with debug output
.\clean_compressUHD_qsv_x265_aac.ps1 -DEBUG $true
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

### find_corrupt.ps1

PowerShell utility that recursively scans a directory for corrupt MKV files using `ffprobe`. Logs results to an optional CSV file and uses Radarr to delete and re-download flagged movies.

**What it does:**

- Runs `ffprobe` on each MKV file to detect corruption (non-zero exit code, or output containing `Invalid`, `error`, or `failed`).
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
.\find_corrupt.ps1 -Help

# Audit mode -- detect corrupt files, make no changes
.\find_corrupt.ps1 -Root "Z:\Media\Movies" -Audit

# Scan and log corrupt files to CSV (Radarr replacement also runs)
.\find_corrupt.ps1 -Root "Z:\Media\Movies" -CsvFile ".\corrupt.csv"

# Full production run with all logs and custom Radarr URL
.\find_corrupt.ps1 `
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

## Encoding Settings (Compression Scripts)

| Setting | Value |
|---|---|
| Video codec (AMD/VAAPI) | `hevc_vaapi` |
| Video codec (Intel QSV) | `hevc_qsv` |
| Quality (ffmpeg) | QP 22 |
| Quality (UHD) | QP 24, profile 6.2 |
| Video bitrate target | 1800 kbps |
| Video bitrate max | 2000 kbps |
| UHD bitrate threshold | 20 Mbps |
| Audio codec | AAC |
| Audio bitrate (stereo) | 160 kbps |
| Container | Matroska (`.mkv`) |
