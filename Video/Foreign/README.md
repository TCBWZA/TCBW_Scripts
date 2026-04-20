# Foreign Language Video Scripts

Compression and deduplication scripts for foreign-language content. Scripts convert video to x265 (HEVC) with AAC audio and remove duplicate files.

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
- `HandBrakeCLI` (required by `hbcompress_amd_x265_aac.ps1` and `hbcompress_qsv_x265_aac.ps1`):
  - Windows: `winget install HandBrake.HandBrakeCLI` or `choco install handbrake-cli`
  - Verify: `HandBrakeCLI --version`

---

## Skip File Behaviour

All compression scripts respect two skip markers:

| Marker | Location | Effect |
|---|---|---|
| `.skip` | Parent directory | The entire parent directory is skipped. No files inside are processed. |
| `.skip_<basename>` | File directory | That specific file is skipped. The basename is the full filename without extension. |

Example: to skip `Film.Title.mkv`, create `.skip_Film.Title` in the same directory.

Scripts automatically create a `.skip_<basename>` marker when a transcode produces a file that is not smaller than the original.

---

## Scripts

### compress_amd_x265_aac.sh

Batch video compression script using AMD GPU hardware acceleration (VAAPI) via `ffmpeg`. Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` (single JSON call via `jq`) to determine video codec, audio codec, and video bitrate.
- Skips AV1-encoded files entirely.
- Fast remux path: files already HEVC+AAC under 2.5 Mbps are remuxed (stream copy, no re-encode) rather than transcoded.
- Converts remaining files that are not HEVC or that exceed 2.5 Mbps video bitrate.
- Interlace detection:
  - Fast pass: reads `field_order` from stream metadata.
  - Deep scan: runs `idet` filter (200 frames) only when metadata is inconclusive.
- Uses software decode with VAAPI encode only (`hevc_vaapi`); avoids hardware decode to support any input codec.
- Encodes at QP 20 with audio stream-copied (original audio preserved).
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
cd /mnt/media/Foreign
./compress_amd_x265_aac.sh

# With debug output
./compress_amd_x265_aac.sh --debug
```

---

### compress_qsv_x265_aac.ps1

PowerShell compression script using Intel Quick Sync Video (QSV) encoding. Targets `.mkv`, `.ts`, and `.mp4` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, and video bitrate.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Interlace detection via `ffprobe` stream metadata.
- Encodes with `hevc_qsv`.
- Optional temporary directory for intermediate files (set `$TempDir` at the top of the script).
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs (configurable via `$MaxJobs` at top of script).

No command-line parameters. Edit the threshold and path constants at the top of the script before running.

**Execution:**

```powershell
Set-Location "Z:\Media\Foreign"
.\compress_qsv_x265_aac.ps1
```

---

### hbcompress_qsv_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with Intel Quick Sync Video (QSV) encoding. Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, resolution, and video bitrate.
- Skips files already encoded as HEVC that are under 2.5 Mbps. Audio codec is not checked; all audio is copied without re-encoding.
- Skips 4K (UHD) and AV1-encoded files.
- Skips files with no video stream or no audio stream.
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt duration, problematic subtitle codecs); automatically remuxes broken containers before transcoding.
- Detects file locks before and after encoding; skips files currently open by other processes.
- Performs deferred interlace detection (only when transcoding is required): skips the first 5 minutes to avoid credits, analyzes 200 frames for interlace or telecine patterns. HEVC input skips this step.
- Applies `--deinterlace=slower` for interlaced content; `--detelecine --deinterlace=slower` for suspected telecine.
- Encodes with HandBrakeCLI using `qsv_h265` encoder at quality RF 24, `--encoder-preset medium`.
- Copies all audio tracks and subtitles without language filtering (`--audio all --aencoder copy`, `--subtitle copy`).
- Writes to a temporary file; atomically replaces the original only if the output is smaller and non-empty.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts.
- Supports upward recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Updates the terminal title during encoding to show the current file name.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Debug` | No | | Enable verbose debug output with timestamps |

**Execution:**

```powershell
Set-Location "Z:\Media\Foreign"
.\hbcompress_qsv_x265_aac.ps1

# With debug output
.\hbcompress_qsv_x265_aac.ps1 -Debug
```

---

### hbcompress_amd_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with AMD VCE hardware encoding. Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, resolution, and video bitrate.
- Skips files already encoded as HEVC that are under 2.5 Mbps. Audio codec is not checked; all audio is copied without re-encoding.
- Skips 4K (UHD) and AV1-encoded files.
- Skips files with no video stream or no audio stream.
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt duration, problematic subtitle codecs); automatically remuxes broken containers before transcoding.
- Detects file locks before and after encoding; skips files currently open by other processes.
- Performs deferred interlace detection (only when transcoding is required): skips the first 5 minutes to avoid credits, analyzes 200 frames for interlace or telecine patterns. HEVC input skips this step.
- Applies `--deinterlace=slower` for interlaced content; `--detelecine --deinterlace=slower` for suspected telecine.
- Encodes with HandBrakeCLI using `amd_h265` encoder at quality RF 24, `--encoder-preset balanced`.
- Copies all audio tracks and subtitles without language filtering (`--audio all --aencoder copy`, `--subtitle copy`).
- Writes to a temporary file; atomically replaces the original only if the output is smaller and non-empty.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts.
- Supports upward recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Updates the terminal title during encoding to show the current file name.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Debug` | No | | Enable verbose debug output with timestamps |

**Execution:**

```powershell
Set-Location "Z:\Media\Foreign"
.\hbcompress_amd_x265_aac.ps1

# With debug output
.\hbcompress_amd_x265_aac.ps1 -Debug
```

---

### deinterlace_qsv_x265_aac.ps1

PowerShell compression script using Intel Quick Sync Video (QSV) encoding via direct `ffmpeg`. Targets `.mkv` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, and field order.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Interlace detection: reads `field_order` metadata; falls back to a 500-frame `idet` filter scan.
- Applies `deinterlace_qsv` filter for interlaced content; `format=qsv` passthrough for progressive.
- Encodes with `hevc_qsv` at 1800k target / 2000k max, audio AAC at 160 kbps.
- Transcodes to a temporary file; replaces the original only if transcoding succeeds.
- Runs up to `$MaxJobs` (default 2) parallel encoding jobs via `Start-Job`.

No command-line parameters. Edit `$MaxJobs` at the top of the script to change parallelism.

**Execution:**

```powershell
Set-Location "Z:\Media\Foreign"
.\deinterlace_qsv_x265_aac.ps1
```

---

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

**Execution:**

```powershell
Set-Location "Z:\Media\Foreign"

# Dry-run preview
.\fixSpecials.ps1 -DryRun

# Apply changes
.\fixSpecials.ps1
```

---

### dedup.ps1

Recursively scans foreign-content directories for duplicate episode files and removes them, keeping the best copy. Also removes associated sidecar files for deleted duplicates.

**What it does:**

- Scans all files recursively for episode codes matching `S##E##`, `S##E###`, `##x##`, `#x##`, or `##x###`.
- Groups files by episode code within the same directory.
- When duplicates are found, keeps the best file using this priority:
  - File type: `MKV > MP4 > TS > AVI`
  - File size: largest file wins when file types are equal.
- Deletes duplicate files along with any associated sidecar files (`.nfo`, `.srt`, `.jpg`, `.trickplay`, etc.).
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

## Encoding Settings (Compression Scripts)

| Setting | Value |
|---|---|
| Video codec (AMD/VAAPI - bash) | `hevc_vaapi` |
| Video codec (AMD VCE - HandBrake) | `vce_h265` |
| Video codec (Intel QSV via HandBrake) | `qsv_h265` |
| Video codec (Intel QSV direct) | `hevc_qsv` |
| Quality (ffmpeg AMD) | QP 20 |
| Quality (HandBrake) | RF 24 |
| Video bitrate target (ffmpeg) | 1800 kbps |
| Video bitrate max (ffmpeg) | 2000 kbps |
| Audio codec (HandBrake / QSV scripts) | AAC |
| Audio (bash compress script) | Stream copy (original preserved) |
| Audio bitrate (stereo) | 160 kbps |
| Container | Matroska (`.mkv`) |
