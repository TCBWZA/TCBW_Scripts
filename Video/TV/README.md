# TV Shows Video Scripts

Compression and maintenance scripts for TV show content. Scripts convert video to x265 (HEVC) with AAC audio, flag foreign-language-only files, and identify corrupt MKV files. Episode deduplication is shared from [Video/General/](../General/README.md).

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

### repack_mkv_lang.sh

- `mkvmerge` from mkvtoolnix (track-filtering remux only).
  - Linux: `sudo apt install mkvtoolnix`
  - Verify: `mkvmerge --version`

### Bash Scripts (AMD/Intel GPU)

- Linux/Unix with Bash 5+
- AMD/Intel GPU with VAAPI support (`/dev/dri/renderD128` must be accessible)

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
| `.skip` | Parent show directory | The whole show directory is skipped; no files inside are processed. |
| `.skip_<basename>` | Episode directory | That file is skipped. The basename is the full filename without extension. |

Example: to skip `Show.S01E01.mkv`, create `.skip_Show.S01E01` in the same directory.

Scripts automatically create a `.skip_<basename>` marker when a transcode is not smaller than the original, so the file is not re-attempted.

---

## Scripts

### compress_amd_x265_aac.sh

Batch video compression script using AMD/Intel GPU hardware acceleration (VAAPI) via `ffmpeg`. Targets `.mkv`, `.mp4`, and `.ts` files that are 950 MB or larger.

**What it does:**

- Pre-flight checks for `ffprobe`, `ffmpeg`, `jq`, and `bc`.
- Inspects each file with `ffprobe` (single JSON call via `jq`) to determine video codec, audio codec, video bitrate, field order, and height.
- Skips files encoded as AV1 or with height > 1100p.
- Skips files with no video stream or no audio stream, creating a `.skip_<basename>` marker.
- Deletes legacy files already tagged `[Cleaned]` or `[Trans]`.
- Uses `.skip` directory markers and `.skip_<basename>` per-file markers to opt out of processing.
- Container repair remux: files already HEVC+AAC, under 2.5 Mbps, and progressive are checked for container anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors). Broken containers are remuxed (stream copy) into a clean MKV; clean files are skipped. Enabled with `--remux-check`.
- Converts remaining files that are not HEVC+AAC or that exceed 2.5 Mbps video bitrate or are interlaced/telecine.
- Interlace / telecine detection:
  - **Fast pass**: reads `field_order` from stream metadata. Hard interlace flags (`tt`, `bb`, `tb`, `bt`) resolve to `interlaced`; `progressive` resolves to `progressive`.
  - **Slow pass** (when metadata is inconclusive): runs `ffmpeg -vf idet` on ~1000 frames starting at the 5-minute mark and counts interlaced/TFF/BFF frames. Strong TFF/BFF with low interlaced count = `telecine`; otherwise `interlaced` if interlaced count is high.
- Applies the appropriate filter chain for each detection result:
  - `interlaced`: `bwdif=mode=send_frame`
  - `telecine`: `pullup,dejudder`
  - `progressive`: no filter
- Encodes with `hevc_vaapi` at QP 28, audio and subtitle streams are copied without modification (`-c:a copy`). MP4 files with `mov_text` subtitles are converted to `srt` before muxing into MKV.
- Runs at low scheduling priority (`nice -n 10`, `ionice -c 3`).
- Writes to `[Trans].tmp`; replaces the original only if the new file is more than 10% smaller. Otherwise creates a `.skip_<basename>` marker.
- Sets ownership to `1000:1000` and permissions to `666` after each replacement.
- Runs 1 encoding job at a time.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output. |
| `-r` / `--remux-check` | Enable container repair remux for compliant files. |

**Execution:**

```bash
# Run from within the TV directory to compress all eligible files
cd <media-root>/TV
./compress_amd_x265_aac.sh

# With debug output
./compress_amd_x265_aac.sh --debug
```

---

### compress_lang_amd_x265_aac.sh

Batch video compression script using AMD/Intel GPU hardware acceleration (VAAPI) via `ffmpeg` with language-based stream filtering. Targets `.mkv`, `.mp4`, and `.ts` files that are 950 MB or larger.

**What it does:**

- Pre-flight checks for `ffprobe`, `ffmpeg`, `jq`, and `bc`.
- Uses `jq` to filter audio and subtitle streams. When an English (`eng`/`en`), undefined (`und`), or unknown (`unk`) audio track exists, streams in other languages are dropped. When no such audio track exists (foreign-only content), all audio and subtitle tracks are kept.
- Inspects each file with `ffprobe` to determine video codec, audio codec, video bitrate, and field order.
- Skips AV1-encoded files and high-resolution content (`> 1100p`).
- Detects interlacing / telecine with a two-pass approach: a fast pass reads `field_order` from stream metadata (hard interlace flags resolve immediately), and a slow pass runs `ffmpeg -vf idet` on ~1000 frames starting at the 5-minute mark when metadata is inconclusive.
- Applies `bwdif=mode=send_frame` for interlaced content, `pullup,dejudder` for telecine.
- Encodes with `hevc_vaapi` at QP 28, audio is copied, and subtitles are copied or converted from `mov_text` to `srt` for MP4 inputs.
- Replaces the original only if the new file is more than 10% smaller; otherwise creates a `.skip_<basename>` marker.
- Runs up to 2 parallel encoding jobs.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output. |
| `-r` / `--remux-check` | Enable container repair remux for compliant files. |

**Execution:**

```bash
# Run from within the TV directory
cd <media-root>/TV
./compress_lang_amd_x265_aac.sh

# With debug output
./compress_lang_amd_x265_aac.sh --debug
```

---

### compress_1080p_lang_amd_x265_aac.sh

High-resolution TV variant of `compress_lang_amd_x265_aac.sh`: language-filtered compression that downsizes content taller than 1080p to a full 1920x1080 frame and tone-maps HDR to SDR. Targets `.mkv`, `.mp4`, and `.ts` files that are 950 MB or larger.

**What it does:**

- Pre-flight checks for `ffprobe`, `ffmpeg`, `jq`, `bc`, and `mkvmerge`.
- Language filtering: when an English (`eng`/`en`), undefined (`und`), or unknown (`unk`) audio track exists, audio and subtitle streams in other languages are dropped; when no such audio exists (foreign-only content), all tracks are kept.
- Audio handling: any kept audio track that is not already AAC forces a transcode, and all kept audio is re-encoded to AAC 160k.
- Downscale: when `height > 1080`, scales via CPU `scale` (force_original_aspect_ratio=decrease) then `pad` to a full 1920x1080 black frame; never upscales. CPU scale+pad is used instead of `scale_vaapi` because the VAAPI encoder alignment padding leaves garbage pixels.
- HDR detection (`color_transfer` in `smpte2084` / `arib-std-b67`); HDR content is tone-mapped to SDR with a CPU zscale/tonemap chain (the AMD VAAPI driver has no HDR VPP): `zscale=transfer=linear,tonemap=hable,zscale=primaries=bt709:transfer=bt709:matrix=bt709`.
- Interlace / telecine detection follows the same two-pass `field_order` + `idet` scan as `compress_lang`; filters run before the tonemap/scale chain (base = `bwdif=mode=send_frame` interlaced / `pullup,dejudder` telecine / none progressive).
- `needs_convert` triggers when the video codec/bitrate/scan-type changes, or a track change, downscale, or tonemap is needed. Tracks-only pruning never skips as already-compliant.
- Encodes with `hevc_vaapi` at QP 28; video track is retagged `-metadata:s:v:0 language=zxx`.
- Replaces the original only if the new file is more than 10% smaller; otherwise creates a `.skip_<basename>` marker.
- When the transcode succeeds but is not 10% smaller and tracks were filtered, strips the unwanted audio/subs via an `mkvmerge` stream-copy remux (`[Strip].tmp`), video language set to `zxx`; the video bitstream is unchanged.
- Runs up to 2 parallel encoding jobs.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output. |
| `-r` / `--remux-check` | Enable container repair remux for compliant files. |

**Execution:**

```bash
# Run from within the TV directory
cd <media-root>/TV
./compress_1080p_lang_amd_x265_aac.sh

# With debug output
./compress_1080p_lang_amd_x265_aac.sh --debug
```

---

### compress_1080p_eng_amd_x265_aac.sh

Byte-identical copy of `compress_1080p_lang_amd_x265_aac.sh` (kept under a distinct name for deployment/rollout). Same behavior, same parameters, same execution.

---

### compress_1080p_anime_amd_x265_aac.sh

Anime variant of `compress_1080p_lang_amd_x265_aac.sh`. Identical except the audio language filter is widened to keep Japanese and Chinese tracks alongside English: `eng`/`en`, `jpn`/`ja`, `chi`/`zho`/`zh`, `und`, `unk`. Subtitle filtering is unchanged (`eng`/`en`/`und`/`unk`). Same name/parameters/execution as the 1080p lang variant.

---

### compress_mp4ts_amd_x265_aac.sh

MP4/TS-specific variant. Transcodes **only `.mp4` and `.ts` sources** to MKV and leaves `.mkv` input alone, so it is safe to point at a folder that mixes containers. The one deliberate deviation from every other compressor in this folder is the replace gate: it is **not** a double-compression guard.

**What it does:**

- Pre-flight checks for `ffprobe`, `ffmpeg`, and `jq`.
- **No size threshold.** Unlike the other bash compressors here, files of any size are processed.
- Skips AV1-encoded sources, files with no video stream, and files with no audio stream.
- Interlace / telecine detection uses the same `idet` deep scan as the other bash compressors; filters run before the encode (base = `bwdif=mode=send_frame` interlaced / `pullup,dejudder` telecine / none progressive).
- Encodes with `hevc_vaapi` at QP 28. Video track is retagged `-metadata:s:v:0 language=zxx`; attached pictures are dropped.
- **Audio and subtitles are stream-copied, never re-encoded**, and are not language-filtered. Subtitle codec args are chosen per stream so the remux stays valid in Matroska.
- **Replaces the original unconditionally**, including when the new file is *larger* than the source. There is no 10% gate and no `.skip_<basename>` marker on growth. The size change is still reported.
- Output verification: `verify_output` requires the encode to produce **exactly one video stream** and a **positive duration** before the temp file is accepted. A file that fails verification is discarded and the source is kept.
- Already-compliant input (HEVC within the bitrate threshold) is **remuxed, never re-encoded**, and that remux is verified the same way. There is no `-r` flag here; the remux is unconditional.
- On success, runs `apply-metadata.sh` from the same directory. `deploy` ships the two side by side, so the script looks for it next to itself and only prints a debug message if it is absent -- it does not fail the run.
- Runs up to 2 parallel encoding jobs.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output. |

**Execution:**

```bash
# Run from within the TV directory
cd <media-root>/TV
./compress_mp4ts_amd_x265_aac.sh

# With debug output
./compress_mp4ts_amd_x265_aac.sh --debug
```

---

### compress_amd_x265_aac.ps1

PowerShell compression script using AMD GPU hardware acceleration (`hevc_amf` via `dxva2`). Targets `.mkv`, `.mp4`, and `.ts` files that are 1 GB or larger.

**What it does:**

- Inspects each file with `ffprobe` to determine video codec, audio codec, video bitrate, and field order.
- Skips files already encoded as HEVC+AAC that are under 2.5 Mbps and are progressive.
- Skips 4K (UHD) content (filename and height checks).
- Files tagged `[Cleaned]` or `[Trans]` are deleted automatically.
- Detects interlacing with the `ffmpeg idet` filter (200 frames, skipping the first 5 minutes); applies the `yadif` deinterlace filter when interlacing is found.
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
Set-Location "<media-root>\TV"
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
- Interlace / telecine detection is two-pass: a fast pass reads `field_order` from stream metadata (hard interlace flags resolve immediately), and a slow pass runs `ffmpeg idet` on ~1000 frames starting at the 5-minute mark when metadata is inconclusive. Per-result filter chains: `bwdif=mode=send_frame` for interlaced, `pullup,dejudder` for telecine, `scale_qsv` for progressive.
- Encodes with `hevc_qsv` at QP 28.
- All audio and subtitle streams are copied without modification.
- Writes to a temporary file; atomically replaces the original only if the output is smaller.
- Creates a `.skip_<basename>` marker when output is not smaller, preventing repeated re-encode attempts.
- Supports `.skip` directory markers and per-file `.skip_<basename>` markers.
- Runs 1 encoding job at a time (`$MaxJobs = 1`, editable at the top of the script).

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` / `-d` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "<media-root>\TV"
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
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors such as non-monotonic timestamps, truncated streams, or missing moov atom); broken MKV containers that do not need transcoding are remuxed (stream copy) without re-encoding.
- Detects file locks before and after encoding; skips files currently open by other processes.
- Performs deferred interlace detection (only when transcoding is required): a fast pass reads `field_order` (hard interlace flags resolve to interlaced, `progressive` is trusted for HEVC input), and a slow pass analyzes 200 frames starting at the 5-minute mark when metadata is inconclusive or for non-HEVC input.
- Applies `--deinterlace=slower` for interlaced content; `--detelecine --deinterlace=slower` for suspected telecine.
- Encodes with HandBrakeCLI using `vce_h265` encoder at quality RF 24, re-encoding all audio tracks to AAC at 160 kbps.
- Filters subtitle streams to English (`eng`) and undefined (`und`) language tracks; other subtitle languages are dropped.
- Writes to a temporary file; atomically replaces the original only if the new file is more than 10% smaller and non-empty. The container-repair remux path skips the 10% size check (stream copy does not shrink files).
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
Set-Location "<media-root>\TV"
.\hbcompress_amd_x265_aac.ps1

# Enable debug output
.\hbcompress_amd_x265_aac.ps1 -Debug
```

---

### hbcompress_qsv_x265_aac.ps1

PowerShell batch compression script using HandBrakeCLI with Intel Quick Sync Video (QSV) hardware encoding. Functionally identical to `hbcompress_amd_x265_aac.ps1` but targets Intel QSV hardware.

**What it does:**

- Same logic and feature set as `hbcompress_amd_x265_aac.ps1`.
- Encodes with `qsv_h265` and `--encoder-preset medium`.
- Skips 4K (UHD) and AV1-encoded files.
- Checks MKV containers for structural anomalies (bad `start_time`, corrupt or non-positive duration, or ffmpeg demux errors such as non-monotonic timestamps, truncated streams, or missing moov atom); broken MKV containers that do not need transcoding are remuxed (stream copy) without re-encoding.
- Detects file locks before and after encoding.
- Performs deferred two-pass interlace detection with the same frame-skip logic.
- Filters subtitle streams to English and undefined language tracks.
- Atomically replaces originals only when the new file is more than 10% smaller; creates `.skip_<basename>` markers otherwise (the container-repair remux path skips the size check).

**Parameters:**

| Parameter | Description |
|---|---|
| `-Debug` / `-d` | Enables verbose debug output with timestamps. |

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "<media-root>\TV"
.\hbcompress_qsv_x265_aac.ps1

# Enable debug output
.\hbcompress_qsv_x265_aac.ps1 -Debug
```

---

### hbcompress_1080p_amd_x265_aac.ps1

HandBrake variant that forces 1080p SDR output. Unlike the other compressors in this folder it does **not** skip UHD or HDR input: it transcodes them down.

**What it does:**

- Encodes via the HandBrakeCLI preset `"1080p SDR AMD x265"`.
- Skips files under 1 GB.
- **Accepts UHD and HDR input** and transcodes it rather than skipping it.
- Resolution: scales to a box of at most 1920x1080 with no upscaling and **no padding**, passed as explicit `--width`/`--height` rather than `--maxWidth`/`--maxHeight`. The explicit values are deliberate: the preset already pins `PictureWidth`/`PictureHeight` to 1920x1080, so a cap has nothing left to clamp, and the preset's anamorphic mode would otherwise derive 2160x1080 (SAR 9:8) from a 1920x1080 display. `--non-anamorphic` forces SAR 1:1.
- HDR detection matches `smpte2084`, `arib-std-b67`, **and `bt2020-10`**. The third value matters: `bt2020-10` is how ffprobe reports HDR10 in Matroska, so matching only `smpte2084` silently certifies an HDR10 file as SDR. HDR is tone-mapped to SDR.
- **Post-encode checks**: verifies the encoded resolution is within 1920x1080 and that an HDR source actually came out SDR. A bad or missing tone map in the preset therefore fails loudly instead of quietly.
- Replaces the original only if the new file is more than 10% smaller.
- Supports both skip-marker forms: a `.skip` file in the directory, and a `.skip_<basename>` file next to the video.
- Audio and subtitle handling come entirely from the preset.
- `-Debug` (alias `-d`) enables verbose output. There is no concurrency setting; this script is single-threaded.

**Execution:**

```powershell
# Run from within the TV directory
Set-Location "<media-root>\TV"
.\hbcompress_1080p_amd_x265_aac.ps1

# Enable debug output
.\hbcompress_1080p_amd_x265_aac.ps1 -Debug
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
./findforeign.sh --root <media-root>/TV

# Scan with CSV output
./findforeign.sh --root <media-root>/TV --csv /tmp/foreign.csv

# Scan and trigger Sonarr replacement for flagged episodes
./findforeign.sh --root <media-root>/TV --sonarr

# Full example with all options
./findforeign.sh --root <media-root>/TV --csv /tmp/foreign.csv --sonarr
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
| `-SonarrUrl` | No | `http://docker.local:8989` | Sonarr base URL |
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
.\findforeign.ps1 -Root "<media-root>\TV" -CsvFile ".\foreign.csv"

# Scan and trigger Sonarr replacement for flagged episodes
.\findforeign.ps1 -Root "<media-root>\TV" -CsvFile ".\foreign.csv" -EnableSonarr

# Append results to existing CSV
.\findforeign.ps1 -Root "<media-root>\TV" -CsvFile ".\foreign.csv" -Append
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
| `-SonarrUrl` | No | `http://docker.local:8989` | Sonarr base URL |
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
.\findcorrupt.ps1 -Root "<media-root>\TV" -Audit

# Scan and log corrupt files to CSV
.\findcorrupt.ps1 -Root "<media-root>\TV" -CsvFile ".\corrupt.csv"

# Scan and trigger Sonarr replacement for corrupt episodes
.\findcorrupt.ps1 -Root "<media-root>\TV" -EnableSonarr

# Full example: audit with CSV and custom Sonarr URL
.\findcorrupt.ps1 -Root "<media-root>\TV" -CsvFile ".\corrupt.csv" -Audit -SonarrUrl "http://your-sonarr-host:8989"

# Full production run with Sonarr and all logs
.\findcorrupt.ps1 `
    -Root "<media-root>\TV" `
    -EnableSonarr `
    -CsvFile "D:\Logs\corrupt.csv" `
    -SonarrUrl "http://your-sonarr-host:8989" `
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
.\remux.ps1 -Root "<media-root>\TV" -EnableDebug
```

---

### repack_mkv_lang.sh

Bash remux script using `mkvmerge` (mkvtoolnix) that repacks MKV files applying the same language rules as `compress_lang_amd_x265_aac.sh`. No video or audio re-encoding happens; tracks are stream-copied into a fresh container. Targets `.mkv` files of any size.

**What it does:**

- Pre-flight checks for `mkvmerge`, `ffprobe`, and `jq`.
- Inspects each file with `ffprobe` (single JSON call via `jq`).
- When an English (`eng`/`en`), undefined (`und`), or unknown (`unk`) audio track exists, keeps only those audio and subtitle languages and drops all others. When no such audio track exists (foreign-only content), all audio and subtitle tracks are kept unchanged.
- Keeps the primary video stream (first non-attached-picture video) and drops any attached-picture cover tracks.
- Chapters, global tags, and container attachments (fonts, etc.) are carried over by `mkvmerge` by default.
- Skips files marked with `.skip` directory markers or `.skip_<basename>` per-file markers.
- Creates a `.skip_<basename>` marker when a file has no primary video stream or no audio stream.
- Fast path: files whose tracks already match the language rules are left untouched (no rewrite).
- Writes to a `[Repack].tmp` file; replaces the original atomically only when `mkvmerge` succeeds and the output is non-empty.
- Preserves file modification time and sets ownership to `1000:1000` with permissions `666` after replacement.
- Requires `mkvmerge` v70 or later (v82 verified). Assumes the ffprobe stream index equals the `mkvmerge` track id, which holds for standard Matroska track order.

**Parameters:**

| Parameter | Description |
|---|---|
| `-d` / `--debug` | Enable verbose debug output. |

**Execution:**

```bash
# Run from within a TV directory to repack all MKV files
cd <media-root>/TV
./repack_mkv_lang.sh

# With debug output
./repack_mkv_lang.sh --debug
```

---

### apply-metadata.sh

Not part of this folder. The script lives in [Video/General/](../General/README.md#apply-metadatash) and is shared by every content type. It matters here because `compress_mp4ts_amd_x265_aac.sh` calls it automatically after a successful encode, resolving it from its own directory.

---

> **setairdate.sh / setairdate.ps1** have moved to [Video/General/](../General/README.md).

---

> **organize-chapters.ps1** have moved to [Video/General/](../General/README.md).

---

## Encoding Settings (Compression Scripts)

| Setting | Value |
|---|---|
| Video codec (AMD/VAAPI) | `hevc_vaapi` |
| Video codec (Intel QSV via HandBrake) | `qsv_h265` |
| Video codec (AMD via HandBrake) | `vce_h265` |
| Quality (ffmpeg) | QP 28 |
| Quality (HandBrake) | RF 24 |
| Video bitrate target | None (QP-based) |
| Video bitrate max | None (QP-based) |
| Audio codec | AAC |
| Audio bitrate (stereo) | 160 kbps |
| Audio bitrate (HandBrake re-encode) | 160 kbps (all tracks) |
| Container | Matroska (`.mkv`) |
