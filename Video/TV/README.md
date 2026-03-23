# TV Shows Video Scripts

Compression, deduplication, and maintenance scripts for TV show content. Scripts convert video to x265 (HEVC) with AAC audio, detect and remove duplicates, flag foreign-language-only files, and identify corrupt MKV files.

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
- `HandBrakeCLI` (required by `hbcompress_*` scripts):
  - Windows: `winget install HandBrake.HandBrakeCLI` or `choco install handbrake-cli`
  - Verify: `HandBrakeCLI --version`

---

## Skip File Behaviour

All scripts respect two skip markers:

| Marker | Location | Effect |
|---|---|---|
| `.skip` | Parent show directory | The entire show directory is skipped. No files inside are processed. |
| `.skip_<basename>` | Episode directory | That specific file is skipped. The basename is the full filename without extension. |

Example: to skip `Show.S01E01.mkv`, create `.skip_Show.S01E01` in the same directory.

Scripts automatically create a `.skip_<basename>` marker when a transcode produces a file that is not smaller than the original, preventing repeated failed attempts on that file.

---

## Scripts

### compress_amd_x265_aac.sh

Batch video compression script using AMD GPU hardware acceleration (VAAPI) via `ffmpeg`. Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine its video codec, audio codec, and video bitrate.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Performs two-pass interlace/telecine detection:
  - Fast pass: reads `field_order` from stream metadata.
  - Deep scan: runs `idet` filter and `repeat_pict` frame analysis (skips first 5 minutes of content, analyzes 200 frames) only when metadata is inconclusive.
- Applies the correct deinterlace filter: `bwdif` for interlaced, `fieldmatch+decimate+bwdif` for telecine.
- Encodes with `hevc_vaapi` at QP 22, VBR 1800k / max 2000k.
- Transcodes to a `.tmp` file first; replaces the original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs.
- Cleans up temporary files on success, failure, or interruption.

**Execution:**

```bash
# Run from within the TV directory to compress all eligible files
cd /mnt/media/TV
./compress_amd_x265_aac.sh
```

---

### fscompress_amd_x265_aac.sh

Variant of `compress_amd_x265_aac.sh` that forces conversion on any file 1 GB or larger, regardless of codec or bitrate. Also includes more detailed multi-channel audio handling.

**What it does:**

- Same interlace/telecine detection as `compress_amd_x265_aac.sh`.
- Forces conversion for any file at or above the minimum size threshold (1 GB by default).
- Handles multi-channel audio:
  - 2-channel: AAC stereo at 160 kbps
  - 6-channel: AAC 5.1 at 384 kbps
  - 8-channel: downnmixed to AAC 5.1 at 384 kbps
  - Other: AAC at 256 kbps with original channel layout
- Encodes with `hevc_vaapi` at QP 22, VBR 1800k / max 2000k.
- Replaces original only if the new file is smaller; otherwise creates a `.skip_<basename>` marker.
- Runs up to 2 parallel encoding jobs.

**Execution:**

```bash
# Run from within the TV directory
cd /mnt/media/TV
./fscompress_amd_x265_aac.sh
```

---

### hbcompress_amd_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with AMD GPU encoding. Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine its video codec, audio codec, and video bitrate.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Performs interlace detection via `ffprobe` frame metadata.
- Applies `--deinterlace=slower` for interlaced content; `--detelecine --deinterlace=slower` for unknown/telecine content.
- Encodes with HandBrakeCLI using `amd_h265` encoder at quality 24, stereo AAC at 160 kbps.
- Transcodes to a temporary file first; replaces the original only if the new file is smaller.
- Creates a `.skip_<basename>` marker when a new file is not smaller.

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\hbcompress_amd_x265_aac.ps1
```

---

### hbcompress_qsv_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with Intel Quick Sync Video (QSV) encoding. Functionally identical to `hbcompress_amd_x265_aac.ps1` but targets Intel QSV hardware.

**What it does:**

- Same logic as `hbcompress_amd_x265_aac.ps1` but uses `qsv_h265` as the encoder.
- Optimized interlace detection: skips the first 5 minutes (9000 frames at ~30 fps) to avoid credits and intros, then analyzes 20 frames.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Applies `--deinterlace=slower` for interlaced; `--detelecine --deinterlace=slower` for unknown/telecine.
- Encodes at HandBrake quality 24, stereo AAC at 160 kbps.
- Replaces original only if the new file is smaller; otherwise creates a `.skip_<basename>` marker.

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\hbcompress_qsv_x265_aac.ps1
```

---

### dedup.ps1

Recursively scans TV show directories for duplicate episodes and removes them, keeping the best copy. Also removes associated sidecar files for deleted episodes.

**What it does:**

- Scans all files recursively for episode codes matching `S##E##`, `S##E###`, `##x##`, `#x##`, or `##x###`.
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

### findforeign.sh

Bash utility that scans a directory tree for MKV files that contain only foreign-language audio tracks (no English or undetermined audio). Optionally logs results to a CSV file and can trigger Sonarr to replace flagged episodes.

**What it does:**

- Uses `ffprobe` to extract audio stream language tags from each MKV file.
- Flags files where no audio track has a language of `eng` or `und`.
- Optionally writes flagged file paths and detected languages to a CSV file.
- Optionally calls the Sonarr API to delete the episode file, re-monitor the episode, and trigger a new search.
- Skips directories containing a `.skip` file.
- Requires `ffprobe`, `jq`, and `curl`.

**Configuration:**

Edit the following variables at the top of the script before running:

```
SONARR_URL="http://your-sonarr-host:8989"
SONARR_API_KEY="YOUR_API_KEY_HERE"
```

**Execution:**

```bash
# Scan current directory, no logging
./findforeign.sh

# Scan a specific root directory
./findforeign.sh --root /mnt/media/TV

# Scan with CSV output
./findforeign.sh --root /mnt/media/TV --csv /tmp/foreign.csv

# Scan and trigger Sonarr replacement for flagged episodes
./findforeign.sh --root /mnt/media/TV --sonarr

# Full example with all options
./findforeign.sh --root /mnt/media/TV --csv /tmp/foreign.csv --sonarr
```

**Sonarr integration (Bash):**

Set `SONARR_URL` and `SONARR_API_KEY` inside the script. When `--sonarr` is passed the script will delete the episode file record in Sonarr, re-monitor the episode, and dispatch an `EpisodeSearch` command. All Sonarr actions are logged to `sonarr_log.csv` in the working directory.

---

### findforeign.ps1

PowerShell equivalent of `findforeign.sh`. Scans a directory tree for MKV files with foreign-only audio and optionally triggers Sonarr replacement.

**What it does:**

- Uses `ffprobe` to extract audio language tags.
- Flags files with no `eng` or `und` audio track.
- Writes flagged files to a mandatory CSV file.
- Optionally calls the Sonarr API to replace flagged episodes.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Root` | No | `.\` | Root directory to scan |
| `-CsvFile` | Yes | | Output CSV file path |
| `-Append` | No | | Append to existing CSV instead of overwriting |
| `-EnableSonarr` | No | | Enable Sonarr replacement workflow |
| `-SonarrUrl` | No | `http://docker:8989` | Sonarr base URL |
| `-SonarrLogFile` | No | `D:\Work\SonarrLog.txt` | Log file for Sonarr actions |

**Configuration:**

Set `$SonarrApiKey` inside the script before running:

```powershell
$SonarrApiKey = "YOUR_API_KEY_HERE"
```

**Execution:**

```powershell
# Scan current directory, write results to CSV
.\findforeign.ps1 -CsvFile ".\foreign.csv"

# Scan a specific directory
.\findforeign.ps1 -Root "Z:\Media\TV" -CsvFile ".\foreign.csv"

# Scan and trigger Sonarr replacement for flagged episodes
.\findforeign.ps1 -Root "Z:\Media\TV" -CsvFile ".\foreign.csv" -EnableSonarr

# Append results to existing CSV
.\findforeign.ps1 -Root "Z:\Media\TV" -CsvFile ".\foreign.csv" -Append
```

**Sonarr integration (PowerShell):**

Set `$SonarrApiKey` and optionally `-SonarrUrl` and `-SonarrLogFile`. When `-EnableSonarr` is passed the script will delete the episode file in Sonarr, re-monitor the episode, and dispatch an `EpisodeSearch` command. Results are logged to the file specified by `-SonarrLogFile`.

---

### findcorrupt.ps1

PowerShell utility that recursively scans a directory for corrupt MKV files using `ffprobe`. Optionally logs results to a CSV file and can trigger Sonarr to delete and re-download flagged episodes.

**What it does:**

- Runs `ffprobe` on each MKV file to detect corruption (non-zero exit code, or output containing `Invalid`, `error`, or `failed`).
- Prints the path of each corrupt file to the console.
- Optionally writes corrupt file paths to a CSV log.
- Optionally calls the Sonarr API to delete the episode file, re-monitor the episode, and dispatch an `EpisodeSearch` command.
- Logs series that cannot be matched in Sonarr to a separate missing-series log file.
- Audit mode (`-Audit`) performs no destructive actions; prints what would have happened instead.
- Exits with a structured exit code:
  - `0`: Completed, no corrupt files found.
  - `1`: One or more corrupt files detected.
  - `2`: `ffprobe` missing or inaccessible.
  - `3`: Sonarr API error.
  - `4`: Unexpected exception.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Root` | No | `.\` | Root directory to scan for MKV files |
| `-CsvFile` | No | | CSV log file path (leave empty to disable CSV logging) |
| `-Append` | No | | Append to CSV instead of overwriting |
| `-EnableSonarr` | No | | Enable Sonarr replacement workflow |
| `-Audit` | No | | Dry-run mode; no deletions or API calls |
| `-SonarrUrl` | No | `http://docker:8989` | Sonarr base URL |
| `-SonarrLogFile` | No | `D:\Work\SonarrLog.txt` | Log file for Sonarr actions |
| `-MissingSeriesLog` | No | `D:\Work\MissingSeries.txt` | Log file for unmatched series |
| `-Help` / `-ShowHelp` / `-?` | No | | Show built-in help |

**Configuration:**

Set `$SonarrApiKey` inside the script before running:

```powershell
$SonarrApiKey = "YOUR_API_KEY_HERE"
```

**Execution:**

```powershell
# Show built-in help
.\findcorrupt.ps1 -Help

# Audit mode -- print corrupt files, make no changes
.\findcorrupt.ps1 -Root "Z:\Media\TV" -Audit

# Scan and log corrupt files to CSV
.\findcorrupt.ps1 -Root "Z:\Media\TV" -CsvFile ".\corrupt.csv"

# Scan and trigger Sonarr replacement for corrupt episodes
.\findcorrupt.ps1 -Root "Z:\Media\TV" -EnableSonarr

# Full example: audit with CSV and custom Sonarr URL
.\findcorrupt.ps1 -Root "Z:\Media\TV" -CsvFile ".\corrupt.csv" -Audit -SonarrUrl "http://192.168.1.100:8989"

# Full production run with Sonarr and all logs
.\findcorrupt.ps1 `
    -Root "Z:\Media\TV" `
    -EnableSonarr `
    -CsvFile "D:\Logs\corrupt.csv" `
    -SonarrUrl "http://192.168.1.100:8989" `
    -SonarrLogFile "D:\Logs\SonarrLog.txt" `
    -MissingSeriesLog "D:\Logs\MissingSeries.txt"
```

**Sonarr integration:**

Set `$SonarrApiKey` and configure `-SonarrUrl`. The script verifies Sonarr connectivity before scanning. When a corrupt file is found and `-EnableSonarr` is active, the script:

1. Matches the file to a Sonarr series using the directory name.
2. Identifies the episode by parsing the `SxxExx` pattern in the filename.
3. Deletes the episode file record from Sonarr.
4. Re-monitors the episode.
5. Dispatches an `EpisodeSearch` command so Sonarr queues a replacement download.

Series that cannot be matched in Sonarr are written to the missing-series log for manual review.

Use `-Audit` first to verify matched series and episodes before running a live replacement pass.

---

## Encoding Settings (Compression Scripts)

| Setting | Value |
|---|---|
| Video codec (AMD/VAAPI) | `hevc_vaapi` |
| Video codec (Intel QSV via HandBrake) | `qsv_h265` |
| Video codec (AMD via HandBrake) | `amd_h265` |
| Quality (ffmpeg) | QP 22 |
| Quality (HandBrake) | RF 24 |
| Video bitrate target | 1800 kbps |
| Video bitrate max | 2000 kbps |
| Audio codec | AAC |
| Audio bitrate (stereo) | 160 kbps |
| Audio bitrate (5.1) | 384 kbps |
| Container | Matroska (`.mkv`) |
