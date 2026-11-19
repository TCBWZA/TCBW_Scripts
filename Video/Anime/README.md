# Anime Video Scripts

Animation-specific compression variants, a scanner for Japanese-audio episodes with no usable subtitles, and an MKV property and NFO tag cleaner. The bash compressor here runs at QP 32 where the TV equivalent runs at QP 28, and the HandBrake pair uses animation encode flags.

## DISCLAIMER

Use at your own risk. `findunsubbed.sh` deletes files. Run it with `--audit` first, and keep backups, before using it in write mode.

---

## Requirements

| Script | Platform | Hardware dependency |
|---|---|---|
| `compress_amd_x265_aac.sh` | Linux with Bash | AMD or Intel GPU with VAAPI at `/dev/dri/renderD128` |
| `findunsubbed.sh` | Linux with Bash | None |
| `fixmkvproperties.sh` | Linux with Bash 4+ | None |
| `hbcompress_amd_x265_aac.ps1` | Windows with PowerShell 7+ | AMD VCE encoder and `HandBrakeCLI` |
| `hbcompress_qsv_x265_aac.ps1` | Windows with PowerShell 7+ | Intel QSV encoder and `HandBrakeCLI` |

Command-line tool dependencies are listed in each script section below.

## Scripts

- [`compress_amd_x265_aac.sh`](#compress_amd_x265_aacsh)
- [`findunsubbed.sh`](#findunsubbedsh)
- [`fixmkvproperties.sh`](#fixmkvpropertiessh)
- [`hbcompress_amd_x265_aac.ps1`](#hbcompress_amd_x265_aacps1)
- [`hbcompress_qsv_x265_aac.ps1`](#hbcompress_qsv_x265_aacps1)

---

### compress_amd_x265_aac.sh

Bash batch compressor that uses AMD or Intel GPU VAAPI through `ffmpeg`. It scans the current directory recursively for `.mkv`, `.mp4`, and `.ts` files larger than 950 MB, re-encodes video to HEVC at QP 32 (the animation setting for this folder; the TV variant uses QP 28), and copies audio and subtitle streams. There is no language filter.

**What it does:**

- Checks for `ffprobe`, `ffmpeg`, `jq`, and `bc` at startup; a missing tool exits 1.
- Builds the candidate list with one `find`, limited to `*.mkv`, `*.mp4`, and `*.ts` (case-insensitive) and `-size +950M`. Extras are excluded by 8 filename suffixes (`-trailer`, `-behindthescenes`, `-featurette`, `-interview`, `-scene`, `-short`, `-deleted`, `-sample`) and 13 directory names (`behind the scenes`, `deleted scenes`, `interviews`, `scenes`, `samples`, `shorts`, `featurettes`, `clips`, `other`, `extras`, `trailers`, `theme-music`, `backdrops`).
- Deletes files whose basename contains `[Cleaned]` or `[Trans]`.
- Skips files with no video or no audio stream and writes a `.skip_<basename>` marker. Skips AV1 (`av1`, `av01`, `libaom-av1`, `unknown`) and anything taller than 1100 pixels without writing a marker.
- Conversion triggers when the video codec is not `hevc`, the video bitrate is above 2,500,000, or the file is interlaced or telecine.
- Interlace detection: `field_order` flags `tt`, `bb`, `tb`, and `bt` resolve to interlaced, and `progressive` is accepted directly. Inconclusive metadata on a file that needs conversion runs an `ffmpeg idet` scan of about 1000 frames from the 5-minute mark. Strong TFF or BFF counts with a low interlaced count classify as telecine; a high interlaced count classifies as interlaced.
- Encode path uses `-vaapi_device /dev/dri/renderD128`, `-c:v:0 hevc_vaapi`, `-qp 32`, `-c:a copy`, and `-f matroska`. Filters are none for progressive, `bwdif=mode=send_frame` for interlaced, and `pullup,dejudder` for telecine. Attached-picture streams are dropped. MP4 files carrying `mov_text` subtitles are converted to `srt`; other subtitle streams are copied.
- Runs at low priority with `nice -n 10 ionice -c3` and processes one file at a time (`MAX_JOBS=1`).
- Writes to `<basename>[Trans].tmp` beside the source. A successful encode replaces the source only when the output is more than 10% smaller (`new_size * 10 < orig_size * 9`); a rejected output is deleted and a `.skip_<basename>` marker is written. Replacements preserve the source timestamp and get ownership `1000:1000` and mode `666`.
- With `--remux-check` and AAC audio, an otherwise compliant file is stream-copied into MKV: a non-MKV source is always remuxed, while an MKV is remuxed only when the container check finds a `start_time` or duration reported as `N/A`, a non-positive duration, or `ffmpeg` demux errors. The remux path skips the 10% size gate.
- Tracks temp files on `INT` and `TERM`, and removes leftover `[Trans].tmp` files at the end of the run.

**Parameters:**

| Flag | Default | Effect |
|---|---|---|
| `-d`, `--debug` | off | Print `[DEBUG]` lines to standard error |
| `-r`, `--remux-check` | off | Enable the container-repair remux path for compliant files with AAC audio |

There is no root-path argument. Unrecognised arguments are ignored; the script always scans the current working directory with `find .`.

**Skip markers:**

| Marker | Location | Effect |
|---|---|---|
| `.skip` | Any directory at or below the working directory | That directory and its subdirectories are skipped |
| `.skip_<basename>` | Next to the video, with the final extension removed from the basename | That one file is skipped |

A `.skip_<basename>` marker is also created automatically when a file has no required stream or when a transcode is not more than 10% smaller.

**Dependencies:**

| Tool | Purpose |
|---|---|
| `ffmpeg`, `ffprobe` | Encoding, demux health check, and stream metadata |
| `jq` | Parses the single `ffprobe` JSON call |
| `bc` | Numeric duration comparison |
| VAAPI device `/dev/dri/renderD128` | Hardware `hevc_vaapi` encode |

**Execution:**

```bash
cd <media-root>/Anime/Series
./compress_amd_x265_aac.sh

# Enable debug output and container-repair remux
./compress_amd_x265_aac.sh --debug --remux-check
```

---

### findunsubbed.sh

Bash utility that scans a directory tree for MKV files whose audio is entirely Japanese and that have no usable subtitle stream. An `eng`, `und`, `unk`, missing, English-named, or English-looking subtitle counts as usable. These unsubbed raws are deleted, and Sonarr is asked to replace the episode with a subtitled copy. Sonarr is enabled by default; audit, CSV logging, and Sonarr can each be controlled independently.

**What it does:**

- Uses `ffprobe` and `jq` to read stream metadata and apply the language rules, then `ffmpeg` to sample subtitle text when the tag or title is not enough.
- Flags a file only when every audio stream is tagged `jpn`, `ja`, or `jp` and no subtitle stream is usable.
- Deletes flagged files with `rm -f`, then, when Sonarr is enabled, resolves and requests a replacement episode.
- Resolves the Sonarr series and episode **before** deleting, so a failed lookup leaves the file in place.
- Supports `--audit` for a read-only preview and `--no-sonarr` for delete-only runs.
- Honours `.skip` directory markers and `.skip_<basename>` per-file markers.
- Optionally writes deleted paths to a CSV and always keeps a `sonarr_log.csv` when Sonarr is enabled.
- Requires `ffprobe`, `ffmpeg`, `jq`, and `curl`.

**Detection rules:**

| Condition | Result |
|---|---|
| `ffprobe` returns no stream data | Not flagged; left for `findcorrupt` |
| No audio streams | Not flagged |
| Any audio stream is not `jpn`, `ja`, or `jp`, including an untagged or empty language | Not flagged; left for manual review |
| Any subtitle stream is `eng`, `und`, `unk`, or untagged | Not flagged; the tag is usable or unknown |
| Subtitle title contains `English`, or the first 120 seconds look like English text | Not flagged, even when the language tag is wrong |
| Japanese-only subtitles, such as `jpn` signs, or any other subtitle language | Does not count as subbed; file is still flagged |
| All audio `jpn`/`ja`/`jp` and no usable subtitle | Flagged |

Language tags are lower-cased before comparison. The text check reads up to 80 subtitle cues with HTML/ASS markup stripped, and needs at least 12 Latin letters plus a Latin majority. Only files ending `.mkv` are scanned. Files whose name matches `*-trailer.*` are excluded.

**Skip markers:**

| Marker | Location | Effect |
|---|---|---|
| `.skip` | Any directory under the root | That directory is pruned; nothing inside is scanned |
| `.skip_<basename>` | Next to the video, with the final extension removed from the basename | That one file is skipped, for example `.skip_Episode` skips `Episode.mkv` |

**Options:**

| Flag | Default | Effect |
|---|---|---|
| `-r`, `--root` | `.` | Root directory to scan recursively |
| `-c`, `--csv` | none | Write deleted file paths to this CSV; without it, no CSV is written |
| `-a`, `--append` | off | Append to the CSV instead of writing a new one; requires `--csv` |
| `--audit` | off | Print what would happen and change nothing: no delete, no CSV row, no Sonarr request |
| `--no-sonarr` | Sonarr on | Disable Sonarr integration; a flagged file is still deleted |
| `-s`, `--sonarr` | Sonarr on | Explicitly enable Sonarr, useful to re-enable it after `--no-sonarr` |
| `-d`, `--debug` | off | Print `[DEBUG]` lines to standard error |

An unknown argument, or `--append` without `--csv`, exits with an error before any file is touched. The CSV parent directory must exist. With `--csv` and no `--append`, the CSV is overwritten with a `FilePath` header row; with `--append`, no header is written.

**Delete order and Sonarr resolve gate:**

1. A flagged file is reported as `Japanese-only, no subs`.
2. In `--audit` mode the script prints `[AUDIT] Would delete` and, if Sonarr is enabled, `[AUDIT] Would request Sonarr replacement`, then moves on without changing anything.
3. With Sonarr enabled, the series and episode are resolved first. The full series list is fetched once per run and cached; the series name comes from the file's grandparent directory and is matched against series titles and path components, not a loose search. The `SxxEyy` code is read from the filename. A missing or unreadable series list, an unparsable episode code, zero matches, or more than one match all refuse the delete: the file is kept, the reason is logged to `sonarr_log.csv` with a `(file kept)` status, and scanning continues.
4. The file is deleted with `rm -f`. A failed delete is reported and no CSV row or Sonarr request follows.
5. After a successful delete, the quoted path is appended to the CSV when one was requested.
6. With Sonarr enabled, three calls are issued in order: `RefreshSeries` to mark the episode missing, `episode/monitor` with `monitored: true` to make it wanted, and `EpisodeSearch` to grab a replacement. Each HTTP status is printed and appended to `sonarr_log.csv`.

`sonarr_log.csv` lives in the working directory. When Sonarr is enabled it is created with a `DateTime,FilePath,Status` header before the scan starts, and receives one row per Sonarr call plus one row per file kept by the resolve gate.

**Configuration:**

Edit these variables near the top of the script before running with Sonarr enabled:

```
SONARR_URL="http://docker.local:8989"
SONARR_API_KEY="YOUR_API_KEY_HERE"
```

Use the fully qualified host `docker.local`; a bare `docker` name can be redirected by a VPN client. Replace the placeholder key before use, because leaving it in place exits with an error when Sonarr is enabled. The default scan root is `ROOT="."`.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Scan completed, including audit and delete-only runs |
| `1` | Missing dependency, unknown argument, root is not a directory, `--append` without `--csv`, CSV parent directory missing, or Sonarr enabled with a missing or placeholder API key |
| `3` | Sonarr is enabled but unreachable at the configured URL |

Per-file problems, such as a failed resolve or a failed delete, are logged and skipped; they do not change the exit code.

**Dependencies:**

| Tool | Purpose |
|---|---|
| `ffprobe` | Reads audio and subtitle stream metadata, part of `ffmpeg` |
| `jq` | Parses the ffprobe JSON and applies the language tests |
| `curl` | Sonarr connectivity check, series and episode lookups, and replacement commands |

All three are checked at startup; a missing tool exits 1. On Debian and Ubuntu they can be installed with `sudo apt update && sudo apt install ffmpeg jq curl -y`.

**Execution:**

```bash
# Preview a series tree without changing anything
./findunsubbed.sh --root <media-root>/Anime/Series --audit

# Delete flagged files and record the paths in a new CSV
./findunsubbed.sh --root <media-root>/Anime/Series --csv /tmp/unsubbed.csv

# Append to an existing CSV and keep the default Sonarr integration
./findunsubbed.sh --root <media-root>/Anime/Series --csv /tmp/unsubbed.csv --append

# Delete flagged files but skip Sonarr entirely
./findunsubbed.sh --root <media-root>/Anime/Series --no-sonarr

# Re-enable Sonarr explicitly and enable verbose diagnostics
./findunsubbed.sh --root <media-root>/Anime/Series --sonarr --debug
```

---

### fixmkvproperties.sh

Bash MKV cleaner and NFO tag applier. It scans the current directory recursively for `.mkv` files, repairs containers, normalises track names, and writes NFO-derived tags and container titles. The scan excludes extras by the same 8 filename suffixes and 13 directory names used by `compress_amd_x265_aac.sh`.

**What it does:**

- Checks for `xmlstarlet`, `mkvmerge`, `mkvpropedit`, `mkvextract`, `jq`, `stat`, `touch`, and `ffmpeg` at startup; a missing tool exits 1.
- Reads track metadata with `mkvmerge -J`. If that fails, the file is stream-copied into a clean MKV with `ffmpeg -max_interleave_delta 0` and probed again; a second failure skips the file.
- Checks track UIDs for missing, non-numeric, zero, or duplicate values. A bad UID set triggers one repair remux and a re-check; a file that still fails is skipped.
- Reads `<basename>.nfo` beside each MKV, stripping a leading BOM. An `episodedetails` element supplies `showtitle`, `title`, `season`, `episode`, `plot`, and `aired`; the release year is the first 4 characters of `aired`. The container title becomes `<series>: <episode title>` and the tags `TITLE`, `SERIES`, `SHOW`, `SEASON`, `EPISODE`, `DESCRIPTION`, and `DATE_RELEASED` are written.
- When there is no NFO, or the NFO has no `episodedetails`, no tags are applied. The series name falls back to the nearest parent directory holding `series.nfo` or `tvshow.nfo`, otherwise to the parent directory name.
- Skips a file when its existing `SERIES`, `SHOW`, `SEASON`, `EPISODE`, and `TITLE` tags already match the NFO.
- Normalises a non-empty container title with `mkvmerge --title ""` and replaces the source only when the output is non-empty and parses as MKV.
- Renames tracks with positional selectors `track:v<n>`, `track:a<n>`, and `track:s<n>`. Video is named `Video`. Audio and subtitle names have release-group and CR junk stripped and trailing hyphens removed, and gain a language name when the track language is `eng`, `jpn`, `chi`/`zho`/`cmn`, `yue`, `kor`, `spa`, `fra`/`fre`, or `deu`/`ger` and no language word is already present. SDH, CC, HI, HOH, and signs strings are left in the cleaned name.
- Writes the container title and tag set with `mkvpropedit`, then restores the original modification time. The title-normalisation replacement gets ownership `1000:1000` and mode `666`.
- Files that need no title change, no rename, and no tags are left untouched.

**Parameters:**

| Flag | Default | Effect |
|---|---|---|
| `--dry-run` | off | Report what would change and make no metadata edits |
| `--debug` | off | Print `[DEBUG]` lines and include them in the audit log when one is set |
| `--audit-log <path>` | none | Append timestamped audit lines to the given file |

Unknown arguments and `--audit-log` without a path exit 1. There is no root-path argument; the script scans the current working directory. The repair remux described above runs before the `--dry-run` check, so a container that fails `mkvmerge -J` or the UID check is still rewritten in dry-run mode.

**Dependencies:**

| Tool | Purpose |
|---|---|
| `mkvmerge`, `mkvpropedit`, `mkvextract` | MKV probing, title clear, track rename, and tag read or write (MKVToolNix) |
| `xmlstarlet` | NFO XPath reads and XML escaping |
| `jq` | Track and tag JSON parsing |
| `ffmpeg` | Stream-copy repair remux |
| `stat`, `touch` | Modification time capture and restore |

**Execution:**

```bash
cd <media-root>/Anime/Series
./fixmkvproperties.sh --dry-run

# Apply changes and keep an audit trail
./fixmkvproperties.sh --audit-log ./fixmkv-audit.log
```

---

### hbcompress_amd_x265_aac.ps1

PowerShell batch compressor using HandBrakeCLI with AMD VCE hardware encoding. It recursively scans the current directory for `.mkv`, `.mp4`, and `.ts` files of 1 GB or larger, encodes video to HEVC, and copies every audio and subtitle track without language filtering. Files are processed one at a time.

**What it does:**

- Requires PowerShell 7+, `HandBrakeCLI`, `ffprobe`, and `ffmpeg` on `PATH`, plus a working AMD VCE encoder.
- Skips files under 1 GB, files with no video stream, files with no audio stream, AV1 sources, and 4K sources (width at least 3800 and height at least 2000).
- Honours a `.skip` file in any directory from the file's parent up to the scan root, and a `.skip_<basename>` file beside the video. Files whose basename contains `[Cleaned]` or `[Trans]` are deleted.
- Conversion is needed when the video is not `hevc`, the video bitrate is above 2,500,000, or interlace detection does not report progressive. HEVC files flagged `progressive` skip interlace detection; other cases use a `field_order` fast pass and a slow probe of about 200 frames starting at the 5-minute mark. Detected interlacing adds `--deinterlace=slower`; an inconclusive probe adds `--detelecine --deinterlace=slower`.
- MKV files that need no conversion are checked for a `start_time` or duration reported as `N/A`, or for bitmap subtitle codecs (`hdmv_pgs_subtitle`, `dvd_subtitle`, `dvb_subtitle`). A failing file is stream-copied into a clean MKV with `ffmpeg -c copy`; this container-repair path bypasses the 10% size gate.
- Encodes with `HandBrakeCLI --format mkv --encoder vce_h265 --encoder-preset balanced --quality 24 --maxHeight 2160 --audio all --aencoder copy --subtitle copy`, plus the selected filter arguments. The `balanced` preset, quality 24, and all-track copy flags are the animation encode settings used in this folder; no language filtering is applied.
- Checks file locks before and after encode, remux, and move. Output goes to `<basename>[Trans].tmp` beside the source.
- Replaces the source only when the output is non-zero, unlocked, and more than 10% smaller (`($newSize * 10) -ge ($origSize * 9)` triggers a skip). A size-gate rejection deletes the output and writes a 0-byte `.skip_<basename>` marker. The source modification time is copied to the output before the swap.
- Updates the terminal title with the current file name and removes leftover `[Trans].tmp`, `[Trans].nfo`, and `[Trans].jpg` files and `[Trans].trickplay` directories at the end of the run.

**Parameters:**

| Flag | Default | Effect |
|---|---|---|
| `-Debug`, `-d` | off | Timestamped `[DEBUG]` output |

There is no root-path or mandatory file parameter; the scan root is always the current PowerShell location.

**Dependencies:**

| Tool | Purpose |
|---|---|
| `HandBrakeCLI` | Encoding with the `vce_h265` encoder |
| `ffprobe` | Stream metadata, container health, and interlace frames |
| `ffmpeg` | Stream-copy container repair |
| PowerShell 7+ | Required by the script syntax, including the `??` operator |

**Execution:**

```powershell
Set-Location "<media-root>\Anime\TV Dub"
.\hbcompress_amd_x265_aac.ps1

# Verbose diagnostics
.\hbcompress_amd_x265_aac.ps1 -Debug
```

---

### hbcompress_qsv_x265_aac.ps1

PowerShell batch compressor using HandBrakeCLI with Intel Quick Sync Video (QSV) hardware encoding. It follows the same scan, skip, detection, container-repair, and replace pipeline as `hbcompress_amd_x265_aac.ps1`, with a different encoder and preset. It copies every audio and subtitle track without language filtering and processes files one at a time.

**What it does:**

- Requires PowerShell 7+, `HandBrakeCLI`, `ffprobe`, and `ffmpeg` on `PATH`, plus a working Intel QSV encoder.
- Skips files under 1 GB, files with no video stream, files with no audio stream, AV1 sources, and 4K sources (width at least 3800 and height at least 2000).
- Honours `.skip` directory markers and `.skip_<basename>` per-file markers, and deletes basenames containing `[Cleaned]` or `[Trans]`.
- Uses the same `field_order` fast pass and 200-frame slow probe as the AMD variant. Interlaced input adds `--deinterlace=slower`; inconclusive probes add `--detelecine --deinterlace=slower`.
- Repairs MKV containers that fail the health check (`start_time` or duration reported as `N/A`, or `hdmv_pgs_subtitle`, `dvd_subtitle`, `dvb_subtitle`) with `ffmpeg -c copy`, skipping the 10% gate on that path.
- Encodes with `HandBrakeCLI --format mkv --encoder qsv_h265 --encoder-preset medium --quality 24 --maxHeight 2160 --audio all --aencoder copy --subtitle copy`, plus the selected filter arguments. Quality 24 and the all-track copy flags are the animation encode settings used in this folder. The `qsv_h265` encoder and `medium` preset are the only behavioural differences from the AMD variant.
- Applies the same file-lock checks, `[Trans].tmp` output, 10% replace gate with a 0-byte `.skip_<basename>` marker on rejection, timestamp preservation, terminal-title update, and end-of-run `[Trans]` cleanup as the AMD variant.

**Parameters:**

| Flag | Default | Effect |
|---|---|---|
| `-Debug`, `-d` | off | Timestamped `[DEBUG]` output |

There is no root-path or mandatory file parameter; the scan root is the current PowerShell location.

**Dependencies:**

| Tool | Purpose |
|---|---|
| `HandBrakeCLI` | Encoding with the `qsv_h265` encoder |
| `ffprobe` | Stream metadata, container health, and interlace frames |
| `ffmpeg` | Stream-copy container repair |
| PowerShell 7+ | Required by the script syntax, including the `??` operator |

**Execution:**

```powershell
Set-Location "<media-root>\Anime\Series"
.\hbcompress_qsv_x265_aac.ps1

# Verbose diagnostics
.\hbcompress_qsv_x265_aac.ps1 -Debug
```
