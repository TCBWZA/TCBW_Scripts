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
- `HandBrakeCLI` required by `hbcompress_qsv_x265_aac.ps1`:
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

- Inspects each file with `ffprobe` to determine video codec, audio codec, and video bitrate.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Performs two-pass interlace/telecine detection:
  - Fast pass: reads `field_order` from stream metadata.
  - Deep scan: runs `idet` filter and `repeat_pict` frame analysis only when metadata is inconclusive.
- Applies the correct deinterlace filter: `bwdif` for interlaced, `fieldmatch+decimate+bwdif` for telecine.
- Encodes with `hevc_vaapi` at QP 22, VBR 1800k / max 2000k.
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs.

No command-line parameters. Run from within the target directory.

**Execution:**

```bash
cd /mnt/media/Foreign
./compress_amd_x265_aac.sh
```

---

### compressmp4_amd_x265_aac.sh

Bash compression script specialised for MP4 container files, using AMD GPU hardware acceleration. Targets `.mp4` files that are 1 GB or larger.

**What it does:**

- Same codec check and VAAPI encoding as `compress_amd_x265_aac.sh`.
- Processes only `.mp4` files (not MKV or TS).
- Encodes with `hevc_vaapi` at QP 22, VBR 1800k / max 2000k.
- Replaces original only if the new file is smaller.
- Runs up to 2 parallel encoding jobs.

No command-line parameters. Run from within the target directory.

**Execution:**

```bash
cd /mnt/media/Foreign
./compressmp4_amd_x265_aac.sh
```

---

### compress_qsv_x265_aac.ps1

PowerShell compression script using Intel Quick Sync Video (QSV) encoding. Targets `.mkv` and `.ts` files that are 1 GB or larger.

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

- Inspects each file with `ffprobe` to determine video codec, audio codec, and video bitrate.
- Converts files that are not already HEVC+AAC or that exceed 2.5 Mbps video bitrate.
- Performs interlace detection via `ffprobe` frame metadata:
  - Applies `--deinterlace=slower` for interlaced content.
  - Applies `--detelecine --deinterlace=slower` for unknown or telecine content.
- Encodes with HandBrakeCLI using `qsv_h265` encoder at quality 24, stereo AAC at 160 kbps.
- Transcodes to a temporary file first; replaces the original only if the new file is smaller.
- Creates a `.skip_<basename>` marker when a new file is not smaller.
- Configurable HandBrake quality (`$HandBrakeQuality`, default 24) and temp directory (`$TempDir`) at the top of the script.

No command-line parameters. Edit the threshold constants at the top of the script before running.

**Execution:**

```powershell
Set-Location "Z:\Media\Foreign"
.\hbcompress_qsv_x265_aac.ps1
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
| Video codec (AMD/VAAPI) | `hevc_vaapi` |
| Video codec (Intel QSV via HandBrake) | `qsv_h265` |
| Video codec (Intel QSV direct) | `hevc_qsv` |
| Quality (ffmpeg) | QP 22 |
| Quality (HandBrake) | RF 24 |
| Video bitrate target | 1800 kbps |
| Video bitrate max | 2000 kbps |
| Audio codec | AAC |
| Audio bitrate (stereo) | 160 kbps |
| Container | Matroska (`.mkv`) |
