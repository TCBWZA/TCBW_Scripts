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

- Inspects each file with `ffprobe` (single JSON call via `jq`) to determine video codec, audio codec, video bitrate, field order, and frame rate.
- Skips AV1-encoded files entirely.
- Container repair remux: files already in the desired format (HEVC+AAC under 2.5 Mbps, progressive) are checked for container anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors). Broken containers are remuxed (stream copy) into a clean MKV; clean files are skipped without re-encoding.
- Converts remaining files that are not HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Three-stage interlace and telecine detection:
  - **Fast pass**: reads `field_order` from stream metadata. Hard interlace flags (`tt`, `bb`, `tb`, `bt`) resolve immediately to `interlaced`; `progressive` flag resolves immediately to `progressive`.
  - **Slow pass** (when metadata is inconclusive): runs `ffprobe -show_frames` on a 200-frame window at the 5-minute mark (falls back to start of file for shorter content). Counts frames with `interlaced_frame=1`. If mixed interlaced/progressive frames are found at a ~29.97 fps source rate the file is classified as `telecine` (NTSC 3:2 pulldown); otherwise `interlaced`. If the frames scan fails entirely the status is `unknown`.
  - **PAL idet fallback**: if the slow pass reports `progressive` but the source frame rate is in the PAL range (~25 fps), runs `ffmpeg -vf idet` for 200 frames and analyses the Multi Frame Detection pixel-level counts. If the TFF+BFF ratio is 30% or greater the file is reclassified as `interlaced`. This catches BBC and other European broadcast content that is encoded without bitstream interlace flags.
- Applies the appropriate filter chain for each detection result:
  - `interlaced`: `bwdif=mode=send_frame` - deinterlaces to progressive
  - `telecine`: `fieldmatch=order=tff:combmatch=full,yadif=deint=interlaced,decimate` - inverse telecine (IVTC) restoring original ~23.976 fps progressive frames
  - `unknown`: `bwdif=mode=send_frame` - conservative fallback
  - `progressive`: no filter
- Encodes with `hevc_vaapi` at QP 24, audio re-encoded as AAC at 160 kbps, subtitle streams filtered to English (`eng`) and undefined (`und`).
- Replaces original only if the new file is smaller; otherwise creates a `.skip_<basename>` marker.
- Sets ownership to `1000:1000` and permissions to `666` after each replacement.
- Supports recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Runs up to 2 parallel encoding jobs.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output |

**Execution:**

```bash
# Run from within the TV directory to compress all eligible files
cd /mnt/media/TV
./compress_amd_x265_aac.sh

# With debug output
./compress_amd_x265_aac.sh --debug
```

---

### compress_amd_x265_aac.ps1

PowerShell compression script using AMD GPU hardware acceleration (`hevc_amf` via `dxva2`). Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, video bitrate, and field order.
- Skips files already encoded as HEVC+AAC that are under 2.5 Mbps and are progressive.
- Skips 4K (UHD) content (filename and height checks).
- Files tagged `[Cleaned]` or `[Trans]` are deleted automatically.
- Detects interlacing via `ffmpeg idet` filter (200 frames, skipping first 5 minutes); applies `yadif` deinterlace filter when interlacing is detected.
- Encodes with `hevc_amf` at 1800k target / 2000k max bitrate.
- All audio and subtitle streams are copied without modification.
- Writes to a temporary file; atomically replaces the original only if the output is smaller.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts.
- Supports `.skip` directory markers and per-file `.skip_<basename>` markers.
- Runs up to 2 parallel encoding jobs (configurable via `$MaxJobs`).

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` / `-d` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\compress_amd_x265_aac.ps1

# Enable debug output
.\compress_amd_x265_aac.ps1 -Debug
```

---

### compress_qsv_x265_aac.ps1

PowerShell compression script using Intel Quick Sync Video (QSV) hardware acceleration (`hevc_qsv`). Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, video bitrate, and field order.
- Skips files already encoded as HEVC+AAC that are under 2.5 Mbps and are progressive.
- Container repair remux: already-compliant files with container anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors) are remuxed (stream copy) into a clean MKV; clean files are skipped without re-encoding.
- Skips 4K (UHD) content (filename and height checks).
- Files tagged `[Cleaned]` or `[Trans]` are deleted automatically.
- Handles MP4 `mov_text` subtitles by converting them to SRT before remuxing into MKV.
- Detects interlacing via `ffmpeg idet` filter (200 frames, skipping first 5 minutes); applies `deinterlace_qsv` hardware filter when interlacing is detected.
- Encodes with `hevc_qsv` at 1800k target / 2000k max bitrate.
- All audio and subtitle streams are copied without modification.
- Writes to a temporary file; atomically replaces the original only if the output is smaller.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts.
- Supports `.skip` directory markers and per-file `.skip_<basename>` markers.
- Runs up to 2 parallel encoding jobs (configurable via `$MaxJobs`).

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` / `-d` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\compress_qsv_x265_aac.ps1

# Enable debug output
.\compress_qsv_x265_aac.ps1 -Debug
```

---

### hbcompress_amd_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with AMD VCE hardware encoding. Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, resolution, and video bitrate.
- Skips files already encoded as HEVC+AAC that are under 2.5 Mbps.
- Skips 4K (UHD) and AV1-encoded files.
- Skips files with no video stream or no audio stream.
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors such as non-monotonic timestamps, truncated streams, or missing moov atom); automatically remuxes broken containers before transcoding.
- Detects file locks before and after encoding; skips files currently open by other processes.
- Performs deferred interlace detection (only when transcoding is required): skips the first 5 minutes to avoid credits, analyzes 200 frames for interlace or telecine patterns. HEVC input skips this step.
- Applies `--deinterlace=slower` for interlaced content; `--detelecine --deinterlace=slower` for suspected telecine.
- Encodes with HandBrakeCLI using `vce_h265` encoder at quality RF 24, stereo AAC at 160 kbps.
- Filters subtitle streams to English (`eng`) and undefined (`und`) language tracks; other subtitle languages are dropped.
- Writes to a temporary file; atomically replaces the original only if the output is smaller and non-empty.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts.
- Supports recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Updates the terminal title during encoding to show the current file name.

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` / `-d` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\hbcompress_amd_x265_aac.ps1

# Enable debug output
.\hbcompress_amd_x265_aac.ps1 -Debug
```

---

### hbcompress_qsv_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with Intel Quick Sync Video (QSV) hardware encoding. Functionally identical to `hbcompress_amd_x265_aac.ps1` but targets Intel QSV hardware.

**What it does:**

- Same logic and feature set as `hbcompress_amd_x265_aac.ps1`.
- Uses `qsv_h265` as the HandBrake encoder with `--encoder-preset medium`.
- Skips 4K (UHD) and AV1-encoded files.
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors such as non-monotonic timestamps, truncated streams, or missing moov atom); automatically remuxes broken containers before transcoding.
- Detects file locks before and after encoding.
- Performs deferred interlace detection with the same frame-skip logic.
- Filters subtitle streams to English and undefined language tracks.
- Atomically replaces originals; creates `.skip_<basename>` markers when output is not smaller.

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` / `-d` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "Z:\Media\TV"
.\hbcompress_qsv_x265_aac.ps1

# Enable debug output
.\hbcompress_qsv_x265_aac.ps1 -Debug
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

### remux.ps1

PowerShell container-repair script that remuxes MKV files with detected structural anomalies, without re-encoding. Targets `.mkv` files only.

**What it does:**

- Checks each MKV for container problems using `ffprobe`: invalid `start_time` values, corrupt duration fields, or problematic subtitle codecs.
- Remuxes only files with detected anomalies; clean files are left untouched.
- Uses `ffmpeg` stream copy (no re-encode) to write a new, clean MKV container.
- Detects file locks before and after the remux operation.
- Atomically replaces the original when the new file is non-empty and successfully written.
- Supports recursive `.skip` directory markers and per-file `.skip_<basename>` markers.

**Parameters:**

| Parameter | Description |
|---|---|
| `-Root` | Root directory to scan. Defaults to the current working directory. |
| `-EnableDebug` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
.\remux.ps1

# Run on a specific directory with debug output
.\remux.ps1 -Root "Z:\Media\TV" -EnableDebug
```

---

### apply-episode-metadata.sh

Bash utility that reads episode metadata from `.nfo` sidecar files and writes it into MKV container tags using `mkvpropedit`.

**What it does:**

- Reads title, plot, episode number, and other fields from `<basename>.nfo` files.
- Falls back to `movie.nfo` in the same directory if the episode NFO is missing a show title.
- Falls back to the parent directory name as the series title if NFO files are unavailable.
- Preserves file modification timestamps (`mtime`) after writing tags.
- Dry-run mode (`--dry-run`) previews all changes without modifying any files.
- Optional audit log (`--audit-log <path>`) records all changes made.

**Requirements:**

- `mkvtoolnix` (`mkvpropedit`, `mkvinfo`)
- `xmlstarlet`
- Bash 4+

**Execution:**

```bash
# Apply metadata (current directory)
./apply-episode-metadata.sh

# Dry-run preview
./apply-episode-metadata.sh --dry-run

# With debug output
./apply-episode-metadata.sh --debug

# Write audit log
./apply-episode-metadata.sh --audit-log "./audit.log"
```

---

### Apply-EpisodeMetadata.ps1

PowerShell equivalent of `apply-episode-metadata.sh`. Reads episode metadata from `.nfo` sidecar files and writes it into MKV container tags using `mkvpropedit`.

**What it does:**

- Reads title, plot, episode number, and other fields from `<basename>.nfo` files.
- Supports multi-episode NFOs by merging titles, plots, and episode number ranges.
- Falls back to `movie.nfo` or the parent directory name when the show title is missing from NFO.
- Preserves file creation time and last-write time after each tag-write operation.
- Dry-run mode (`-DryRun`) performs all processing steps but does not modify any MKV files.
- Optional audit log records all changes and, when `-Debug` is active, debug messages too.

**Parameters:**

| Parameter | Description |
|---|---|
| `-DryRun` | Preview mode; no MKV files are modified. |
| `-Debug` | Enables verbose debug output to the console (and audit log if enabled). |
| `-AuditLogPath` | Path to the audit log file. Logging is disabled when empty or omitted. |

**Requirements:**

- `mkvtoolnix` (`mkvpropedit`)
- PowerShell 7+

**Execution:**

```powershell
# Apply metadata (current directory)
.\Apply-EpisodeMetadata.ps1

# Dry-run preview
.\Apply-EpisodeMetadata.ps1 -DryRun

# With debug output
.\Apply-EpisodeMetadata.ps1 -Debug

# Write audit log
.\Apply-EpisodeMetadata.ps1 -AuditLogPath ".\audit.log"
```

---

> **setairdate.sh / setairdate.ps1** have moved to [Video/General/](../General/README.md).

---

> **organize-chapters.sh / organize-chapters.ps1** have moved to [Video/General/](../General/README.md).

---

## Encoding Settings (Compression Scripts)

| Setting | Value |
|---|---|
| Video codec (AMD/VAAPI) | `hevc_vaapi` |
| Video codec (Intel QSV via HandBrake) | `qsv_h265` |
| Video codec (AMD via HandBrake) | `vce_h265` |
| Quality (ffmpeg) | QP 24 |
| Quality (HandBrake) | RF 24 |
| Video bitrate target | 1800 kbps |
| Video bitrate max | 2000 kbps |
| Audio codec | AAC |
| Audio bitrate (stereo) | 160 kbps |
| Audio bitrate (5.1) | 384 kbps |
| Container | Matroska (`.mkv`) |
