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
- `bc`: basic calculator (Bash scripts that branch on numeric thresholds).
  - Linux: `sudo apt install bc`

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
| `.skip` | Parent directory | The whole parent directory is skipped; no files inside are processed. |
| `.skip_<basename>` | File directory | That file is skipped. The basename is the full filename without extension. |

Example: to skip `Film.Title.mkv`, create `.skip_Film.Title` in the same directory.

Scripts automatically create a `.skip_<basename>` marker when a transcode is not smaller than the original, so the file is not re-attempted.

---

## Scripts

### compress_amd_x265_aac.sh

Batch video compression script using AMD GPU hardware acceleration (VAAPI) via `ffmpeg`. Targets `.mkv`, `.mp4`, and `.ts` files that are 950 MB or larger.

This file is byte-identical to `Video/TV/compress_amd_x265_aac.sh` and `Video/General/compress_amd_x265_aac.sh`. The three copies are deliberately kept separate: they are the same source, and the QP/language differences between folders live in the other scripts, not this one. Do not collapse or deduplicate them.

**What it does:**

- Inspects each file with `ffprobe` (single JSON call via `jq`) to determine video codec, audio codec, and video bitrate.
- Skips AV1-encoded files entirely.
- Files already HEVC+AAC under 2.5 Mbps are **not** transcoded. Whether they are remuxed (stream copy, no re-encode) depends on `-r`; without it they are simply skipped.
- Converts remaining files that are not HEVC or that exceed 2.5 Mbps video bitrate.
- Interlace detection:
  - Fast pass: reads `field_order` from stream metadata (hard interlace flags resolve immediately).
  - Deep scan: runs `idet` on ~1000 frames starting at the 5-minute mark only when metadata is inconclusive; strong TFF/BFF with a low interlaced count = telecine, otherwise interlaced if the count is high.
- Uses software decode with VAAPI encode only (`hevc_vaapi`) so any input codec is supported.
- Encodes at QP 28; audio is stream-copied (original audio preserved).
- Replaces the original only if the new file is **more than 10% smaller** (`new_size * 10 < orig_size * 9`); otherwise creates a `.skip_<basename>` marker. This is a deliberate double-compression guard, stricter than the "merely smaller" gate the PowerShell compressors use.
- Sets ownership to `1000:1000` and permissions to `666` after each replacement.
- Supports recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Runs 1 encoding job at a time.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output |
| `-r` / `--remux-check` | Remux already-compliant files for container repair instead of leaving them untouched. Requires AAC audio. Off by default |

**Execution:**

```bash
cd <media-root>/Foreign
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
- Interlace detection: reads `field_order` from stream metadata first, and when that is inconclusive runs a deep `idet` scan (~200 frames, starting at the 5-minute mark). Applies `deinterlace_qsv` when interlaced frames are found, otherwise `format=qsv`.
- Encodes with `hevc_qsv`.
- Optional temporary directory for intermediate files (set `$TempDir` at the top of the script; empty by default, which writes the temp file beside the source).
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs (configurable via `$MaxJobs` at top of script).

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` (alias `-d`) | Enable verbose debug output |

Thresholds, paths, and the job count are variables at the top of the script.

**Execution:**

```powershell
Set-Location "<media-root>\Foreign"
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
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors such as non-monotonic timestamps, truncated streams, or missing moov atom); automatically remuxes broken containers before transcoding.
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
Set-Location "<media-root>\Foreign"
.\hbcompress_qsv_x265_aac.ps1

# With debug output
.\hbcompress_qsv_x265_aac.ps1 -Debug
```

---

### hbcompress_amd_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with AMD VCE hardware encoding. Targets `.mkv`, `.mp4`, and `.ts` files that are 950 MB or larger. Note the threshold is 950 MB here, not the 1 GB used by `hbcompress_qsv_x265_aac.ps1` in this folder.

**What it does:**

- Encodes via the HandBrakeCLI preset `"1080p AMD x265"`, passed with `--preset`. The encoder, quality, audio, and subtitle settings are **whatever that preset contains** -- this script does not pass `--encoder`, `--quality`, `--encoder-preset`, `--audio`, or `--subtitle` itself, so tuning this script means editing the preset, not the script.
- Inspects each file with `ffprobe` to determine video codec, resolution, and video bitrate.
- Skips files already encoded as HEVC that are under 2.5 Mbps. Audio codec is not checked.
- Skips high-resolution content (`height > 1100`) and AV1 or otherwise unsupported codecs.
- Skips files with no video stream or no audio stream.
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors such as non-monotonic timestamps, truncated streams, or missing moov atom); automatically remuxes broken containers before transcoding.
- Detects file locks before and after encoding; skips files currently open by other processes.
- Performs deferred interlace detection (only when transcoding is required): skips the first 5 minutes to avoid credits, analyzes 200 frames for interlace or telecine patterns. HEVC input skips this step.
- Applies `--deinterlace=slower` for interlaced content; `--detelecine --deinterlace=slower` for suspected telecine. These are the only filter arguments the script adds.
- Writes to a temporary file; atomically replaces the original only if the output is smaller and non-empty.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts. When a file is already compliant it writes a `compliant-v1|<size>|<mtime>` fingerprint into that marker and only honours it while both values still match.
- Supports upward recursive `.skip` directory markers and per-file `.skip_<basename>` markers.
- Updates the terminal title during encoding to show the current file name.

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-Debug` | No | | Enable verbose debug output with timestamps |
| `-RemuxCheck` | No | Off | Remux already-compliant files for container repair instead of leaving them untouched. Requires AAC audio |

**Execution:**

```powershell
Set-Location "<media-root>\Foreign"
.\hbcompress_amd_x265_aac.ps1

# With debug output
.\hbcompress_amd_x265_aac.ps1 -Debug

# Remux already-compliant files for container repair
.\hbcompress_amd_x265_aac.ps1 -RemuxCheck
```

---

> **fixSpecials.ps1** has moved to [Video/General/](../General/README.md).

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
| Quality (ffmpeg AMD) | QP 28 |
| Quality (HandBrake) | RF 24 |
| Video bitrate target (ffmpeg) | None (QP-based) |
| Video bitrate max (ffmpeg) | None (QP-based) |
| Audio codec (HandBrake / QSV scripts) | AAC |
| Audio (bash compress script) | Stream copy (original preserved) |
| Audio bitrate (stereo) | 160 kbps |
| Container | Matroska (`.mkv`) |
