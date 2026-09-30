# TCBW Scripts

## Project Structure

```
TCBW_Scripts/
|--  README.md (this file)
|--  LICENSE
|--  .gitattributes                  - Line-ending rules: LF for .sh, auto for everything else
|--  Linux/
|   |--  README.md
|   \--  general/
|       |--  README.md
|       |--  backup_docker.sh              - Stops LXC container, backs up Docker data volume, restarts container
|       |--  backup_etc.sh                 - Archives /etc to a network mount
|       |--  backup_root.sh                - Archives /root to a network mount
|       |--  lxc-upgrade.sh                - Updates Proxmox host and all LXC containers in parallel (autoremove; runs /usr/bin/update and addon update hooks unattended, timeout-bounded, with exit status checked)
|       |--  setperm.sh                    - Sets permissions on media directories
|       |--  showswap.sh                   - Displays swap usage
|       |--  shrink_boot_disk.sh           - Shrinks a raw-image LXC rootfs on directory storage
|       |--  shrinkvol.sh                  - Shrinks an LXC container LVM logical volume
|       |--  sync.sh                       - Orchestrator: powers on USB, runs all sync tasks, powers off
|       |--  sync_anime.sh                 - Rsyncs anime library to <usb-share>/Media/Video/Anime (local USB)
|       |--  sync_audiobooks.sh            - Rsyncs audiobook library to <usb-share>/Media/audiobooks (local USB)
|       |--  sync_backups.sh               - Rsyncs <sysdata-share> to <usb-share>/DATA/sysdata_backups (local USB)
|       |--  sync_books.sh                 - Rsyncs book library to <usb-share>/Media/books (local USB)
|       |--  sync_docker.sh                - Stops LXC container, syncs Docker data to <usb-share>, restarts container
|       |--  sync_etv.sh                   - Rsyncs TV library to <alt-share>/Media/Video/TV (manual-only trigger)
|       |--  sync_main_backups.sh          - Rsyncs <sysdata-share> to <zfs-pool>/main_backups (ZFS dataset)
|       |--  sync_movies.sh                - Rsyncs movie library to <usb-share>/Media/Video/Movies (local USB)
|       |--  sync_sysdocker_maindocker.sh  - Rsyncs <sysdata-share> to <zfs-pool>/main_docker (ZFS dataset)
|       |--  sync_tv.sh                    - Rsyncs TV library to <usb-share>/Media/Video/TV (local USB)
|       |--  usb-poweroff.sh               - Safely powers off the USB external drive
|       \--  usb-poweron.sh                - Powers on the USB external drive
|--  Video/
|   |--  Anime/                             - Animation-specific variants of the TV compression scripts
|   |   |--  compress_amd_x265_aac.sh       - AMD GPU VAAPI x265 compression at QP 32 for animation (bash)
|   |   |--  findunsubbed.sh                - Finds Japanese-audio titles with no English subtitles (bash)
|   |   |--  fixmkvproperties.sh            - Fixes MKV container properties (bash)
|   |   |--  hbcompress_amd_x265_aac.ps1    - HandBrake AMD VCE x265 compression (PowerShell)
|   |   \--  hbcompress_qsv_x265_aac.ps1    - HandBrake Intel QSV x265 compression (PowerShell)
|   |--  Foreign/                          - Compression scripts for foreign language content
|   |   |--  README.md
|   |   |--  compress_amd_x265_aac.sh      - AMD GPU VAAPI x265 compression (bash)
|   |   |--  compress_qsv_x265_aac.ps1     - Intel QSV x265 compression (PowerShell)
|   |   |--  dedup.ps1                     - Duplicate removal (PowerShell)
|   |   |--  hbcompress_amd_x265_aac.ps1   - HandBrake via the "1080p AMD x265" preset, AMD VCE x265 (PowerShell)
|   |   \--  hbcompress_qsv_x265_aac.ps1   - HandBrake Intel QSV x265 compression (PowerShell)
|   |--  General/                          - Shared utility scripts used across all video content types
|   |   |--  README.md
|   |   |--  apply-metadata.sh             - NFO metadata writer to MKV tags (bash)
|   |   |--  compress_amd_x265_aac.sh      - AMD GPU VAAPI x265 compression (bash)
|   |   |--  dircleanup.sh                 - Removes orphaned trickplay dirs, stale .skip markers, dangling NFOs (bash)
|   |   |--  dircleanup.ps1                - Removes orphaned trickplay dirs, stale .skip markers, dangling NFOs (PowerShell)
|   |   |--  dedup.ps1                     - Duplicate episode removal and priority-based selection (PowerShell)
|   |   |--  fixSpecials.ps1               - Renames Specials folders to Season 00, merging if needed (PowerShell)
|   |   |--  fixunnamedvideo.sh           - Renames extension-less downloads to <dirname>.mkv (bash)
|   |   |--  hb 1080 profile.json          - HandBrake 1080p user preset (import into HandBrake)
|   |   |--  hb 1080p SDR AMD profile.json - HandBrake 1080p SDR user preset (import into HandBrake)
|   |   |--  listuhd.sh                    - Lists UHD files in a directory (bash)
|   |   |--  organize-chapters.ps1         - Moves *_chapters.xml files into chapters/ subdirectory (PowerShell)
|   |   |--  setairdate.sh                 - NFO air date to file timestamp setter for TV episodes (bash)
|   |   |--  setairdate.ps1                - NFO air date to file timestamp setter for TV episodes (PowerShell)
|   |   \--  sync_robo.ps1                 - Robocopy-based sync helper (PowerShell)
|   |--  Movies/                           - Compression and maintenance scripts for movies
|   |   |--  README.md
|   |   |--  Handbrake AV1 4K preset.json  - HandBrake AV1 4K user preset (import into HandBrake)
|   |   |--  compress_amd_x265_aac.sh      - AMD GPU VAAPI x265 compression (bash)
|   |   |--  compress_amd_x265_aac.ps1     - AMD GPU x265 compression (PowerShell)
|   |   |--  compress_qsv_x265_aac.ps1     - Intel QSV x265 compression (PowerShell)
|   |   |--  findcorrupt.ps1               - Corrupt MKV detection with Radarr integration (PowerShell)
|   |   |--  hbcompress_amd_av1_4k.ps1     - HandBrake AMD VCE AV1 4K compression (PowerShell)
|   |   |--  hbcompress_amd_x265_aac.ps1   - HandBrake AMD VCE x265 compression (PowerShell)
|   |   |--  setreleasedate.sh             - NFO release date to file timestamp setter for movies (bash)
|   |   |--  setreleasedate.ps1            - NFO release date to file timestamp setter for movies (PowerShell)
|   |   \--  remuxmp4.sh                   - MP4 to MKV container remux with Radarr integration (bash)
|   \--  TV/                               - Compression, deduplication, and maintenance scripts for TV shows
|       |--  README.md
|       |--  compress_amd_x265_aac.sh      - AMD VAAPI x265 compression (bash)
|       |--  compress_amd_x265_aac.ps1     - AMD GPU x265 compression (PowerShell)
|       |--  compress_1080p_anime_amd_x265_aac.sh - 1080p downscale, wider audio language gate incl. jpn/chi (bash)
|       |--  compress_1080p_eng_amd_x265_aac.sh   - 1080p downscale + HDR tonemap, eng/und/unk (bash)
|       |--  compress_1080p_lang_amd_x265_aac.sh  - 1080p downscale + HDR tonemap (bash)
|       |--  compress_lang_amd_x265_aac.sh - Language-specific AMD VAAPI x265 compression (bash)
|       |--  compress_mp4ts_amd_x265_aac.sh - MP4/TS to MKV at QP 28, no size gate, replaces even on growth, then runs apply-metadata.sh (bash)
|       |--  compress_qsv_x265_aac.ps1     - Intel QSV x265 compression (PowerShell)
|       |--  findcorrupt.ps1               - Corrupt MKV detection with Sonarr integration (PowerShell)
|       |--  findforeign.ps1               - Foreign-audio detection with Sonarr integration (PowerShell)
|       |--  findforeign.sh                - Foreign-audio detection (bash)
|       |--  hbcompress_1080p_amd_x265_aac.ps1 - HandBrake 1080p SDR downscale via the "1080p SDR AMD x265" preset; transcodes UHD/HDR rather than skipping it (PowerShell)
|       |--  hbcompress_amd_x265_aac.ps1   - HandBrake AMD VCE x265 compression (PowerShell)
|       |--  hbcompress_qsv_x265_aac.ps1   - HandBrake Intel QSV x265 compression (PowerShell)
|       |--  remux.ps1                     - Container-repair remux without re-encoding (PowerShell)
|       \--  repack_mkv_lang.sh            - Track-filtering MKV remux without re-encoding (bash)
|--  Windows/
|   \--  General/
|       |--  backup-wsl.ps1                - Exports a WSL distro to a compressed 7z archive with retention (PowerShell)
|       \--  sync_robo.ps1                 - Robocopy-based sync helper for Windows (PowerShell)
\--  audio/
    \--  books/
        |--  listcorrupt.ps1               - Scans for zero-byte audiobook files and optionally deletes directories (PowerShell)
        \--  listcorrupt.sh                - Scans for zero-byte audiobook files (bash)
```

### Path Placeholders

Examples in these READMEs use placeholders rather than any one machine's layout. Substitute your own before running:

| Placeholder | Meaning |
|---|---|
| `<media-root>` | Root of your video library (the folder holding `TV/`, `Movies/`, `Anime/`, `books/`) |
| `<usb-share>` | Removable-drive mountpoint used as a sync destination |
| `<alt-share>` | Second, automounted share used only by `sync_etv.sh` |
| `<zfs-pool>` | Mountpoint of a ZFS dataset used as a sync destination |
| `<sysdata-share>` | Mountpoint holding `sysdata_backups` and `sysdata_docker` |

The Linux sync and backup scripts set `SOURCE`, `DEST`, and `MOUNT` as variables at the top of the file, so those paths are meant to be edited. Read the variables rather than assuming the value shown in an example.

## Linux

See [Linux/README.md](Linux/README.md) for detailed descriptions of Linux utilities.

## Video Processing Scripts

**USE AT YOUR OWN RISK**

The settings in use work for me. You need to make sure things like bitrate meet your quality requirements. **UHD HANDLING DIFFERS BY SCRIPT, SO CHECK WHICH ONE YOU ARE POINTING AT A 4K FILE. ONLY TWO SCRIPTS ENCODE UHD: `Video/Movies/compress_amd_x265_aac.sh` ENCODES IT IN PLACE (ICQ 24, 10-bit main10, HDR passthrough) AND `Video/Movies/hbcompress_amd_av1_4k.ps1` ENCODES IT TO AV1. EVERY OTHER COMPRESSOR SKIPS UHD, WITH ONE EXCEPTION: THE `Video/TV/compress_1080p_*` AND `Video/TV/hbcompress_1080p_amd_x265_aac.ps1` VARIANTS DOWNSCALE IT TO 1080p INSTEAD OF SKIPPING IT.**

### Overview

A collection of video transcoding, compression, and deduplication scripts for batch media processing. Hardware-accelerated encoding converts interlaced video to modern formats at reduced file sizes, with duplicate detection and removal built in.

### Video Folder Organization

- **Anime/** - Animation-specific variants of the TV compression scripts. The bash compressor is QP 32 where the TV one is QP 28, and the HandBrake pair uses animation encode flags. It has no README of its own; see the `Video/Anime/` entries in the structure tree above
- **General/** - Shared utility scripts used across all video content types ([README](Video/General/README.md))
- **Foreign/** - Compression scripts for foreign language content ([README](Video/Foreign/README.md))
- **Movies/** - Compression and maintenance scripts for movie content ([README](Video/Movies/README.md))
- **TV/** - Compression and maintenance scripts for TV show content ([README](Video/TV/README.md))

See each folder's README for detailed file descriptions and usage information.

## Features

### Architecture & Design

**Why Dual Script Implementations?**

The repository keeps both bash (shell) and PowerShell implementations because of hardware and software constraints:

- **Bash Scripts (Linux/Debian)**: Run on a Debian box whose FFmpeg version has a critical bug with embedded subtitles: transcoding such files runs at single-digit FPS, which is impractical.

- **PowerShell Scripts (Windows)**: Run on a separate machine with current FFmpeg. They handle the transcodes that are problematic on the Debian box at normal FPS.

The two machines keep batch processing reliable despite the Debian FFmpeg bug, and compatible files still run on the lower-cost Linux box.

### Compression Scripts

- **Hardware-Accelerated Encoding**: Support for AMD VAAPI, Intel Quick Sync Video (QSV), and HandBrake VCE encoders
- **Batch Processing**: Parallel encoding with configurable concurrent jobs (bash scripts)
- **Smart Format Detection**: Detects interlacing and telecine (NTSC 3:2 pulldown) and decides whether conversion is needed
- **Optimized Frame Analysis**: Seeks to the 5-minute mark (past intros and credits) before the `idet` frame scan
- **Output Format**: x265 (HEVC) video codec with AAC audio
- **Metadata Handling**: Optional metadata and sidecar file management
- **Skip Markers**: Support for `.skip` directory markers and `.skip_<basename>` per-file markers
- **Container Repair**: Automatic MKV container health check; broken containers are remuxed (stream copy) without re-encoding
- **File Lock Detection**: Skips files currently open by other processes (media players, Plex, etc.)
- **Atomic Replacement**: Writes to a temp file and swaps atomically. The replace gate differs by family: the bash compressors and the `hbcompress_*` scripts require the output to be **more than 10% smaller** than the original (a double-compression guard), while the PowerShell ffmpeg compressors (`Video/TV/compress_amd_x265_aac.ps1`, `Video/TV/compress_qsv_x265_aac.ps1` and the Movies/Foreign equivalents) replace whenever the output is merely **smaller**. `Video/TV/compress_mp4ts_amd_x265_aac.sh` replaces unconditionally, including when the result grows.
- **Format Guards**: Every compressor skips AV1-encoded sources. UHD handling varies: `Video/Movies/compress_amd_x265_aac.sh` encodes it in place and `Video/Movies/hbcompress_amd_av1_4k.ps1` encodes it to AV1, while all the other Movies, TV, and Foreign compressors skip anything with a coded height above 1100. The exception is the TV 1080p family (`compress_1080p_*.sh` and `hbcompress_1080p_amd_x265_aac.ps1`), which downscales instead of skipping.
- **Subtitle Filtering**: The TV and Movies `hbcompress_amd_x265_aac.ps1` / `hbcompress_qsv_x265_aac.ps1` scripts retain only English (`eng`) and undefined (`und`) subtitle tracks. `Video/Movies/hbcompress_amd_av1_4k.ps1` copies all audio and subtitle tracks (`--all-audio --aencoder copy`). `Video/Foreign/hbcompress_qsv_x265_aac.ps1` copies all tracks without filtering, and `Video/Foreign/hbcompress_amd_x265_aac.ps1` delegates track selection entirely to its HandBrake preset. The TV `compress_lang` bash script drops streams in languages other than English/undefined/unknown when an English audio track exists, and keeps all tracks when it does not (foreign-only content). `repack_mkv_lang.sh` applies the same language rules when remuxing MKV files without re-encoding.

### Maintenance & Quality Assurance Scripts

- **Corrupt File Detection**: `findcorrupt.ps1` scans for unreadable MKV files and optionally triggers Sonarr or Radarr replacement
- **Foreign Audio Detection**: `findforeign.ps1` / `findforeign.sh` flag episodes with no English or undetermined audio tracks
- **Container Repair**: `remux.ps1` fixes MKV structural anomalies without re-encoding
- **Metadata Sync**: `apply-metadata.sh` is the single applier for both movies and episodes. It reads the NFO, decides MOVIE vs EPISODE from the XML root element, and writes the matching tags into the MKV container. It is deployed alongside whatever script calls it, so the invocation is not bound to folder layout.

### Deduplication Scripts

- **Intelligent Duplicate Detection**: Matches episodes by S##E## or ##x## patterns
- **Priority-Based Selection**: Keeps MKV > MP4 > TS > AVI when duplicates exist
- **Comprehensive Cleanup**: Removes all associated sidecar files (.nfo, .srt, .jpg, .trickplay, etc.)
- **Audit Mode**: Preview what would be deleted before making changes
- **Directory-Scoped Matching**: Only considers files in the same directory as potential duplicates

### General

- **Multi-Platform**: PowerShell scripts for Windows, shell scripts for Unix-like systems
- **Organized Structure**: Separate handling for Movies, TV Shows, Foreign content, and Linux utilities
- **Extensive Documentation**: Detailed README files for each content category

## Prerequisites

### Required Software

- **FFmpeg** and **ffprobe** - Video processing and analysis tools
  - Install via [ffmpeg.org](https://ffmpeg.org/download.html)
  - Or use package manager:
    - Windows: `winget install FFmpeg` or `choco install ffmpeg`
    - macOS: `brew install ffmpeg`
    - Linux: `apt install ffmpeg` or `yum install ffmpeg`

### Hardware Requirements

- **AMD Encoding**: AMD GPU with VCE support (Radeon RX series or newer)
- **Intel QSV**: Intel processor with Quick Sync Video support (most modern Intel CPUs)
- **Recommended**: 4GB+ VRAM, sufficient disk space for temporary files

## Installation

1. **Clone the repository**:

   ```bash
   git clone https://github.com/TCBWZA/TCBW_Scripts.git
   cd TCBW_Scripts
   ```

2. **Verify FFmpeg Installation**:

   ```powershell
   # Windows
   ffmpeg -version
   ffprobe -version
   ```

3. **Configure Script Parameters** (optional):

   Open your chosen script and modify:
   - `$MaxJobs` / `MAX_JOBS`: Number of concurrent encoding jobs. The default is 1 or 2 depending on the script -- see [Parallel Processing](#compression-scripts) above for the per-script values
   - `$TempDir`: Directory for temporary files. Only `Video/Foreign/compress_qsv_x265_aac.ps1` has one, and it is empty by default; set it to a path such as `D:\fasttemp` to encode there instead of beside the source file. The other PowerShell compressors always write their `[Trans].tmp` next to the source file

## Usage

### Windows (PowerShell)

**Compression:**

```powershell
# TV Content - Intel QSV compression (ffmpeg)
./Video/TV/compress_qsv_x265_aac.ps1

# TV Content - AMD VCE compression (HandBrake)
./Video/TV/hbcompress_qsv_x265_aac.ps1

# TV Content - AMD GPU compression (ffmpeg)
./Video/TV/compress_amd_x265_aac.ps1

# Movies - Intel QSV compression
./Video/Movies/compress_qsv_x265_aac.ps1

# Movies - HandBrake AMD VCE compression
./Video/Movies/hbcompress_amd_x265_aac.ps1

# Movies - HandBrake AMD VCE AV1 4K compression
./Video/Movies/hbcompress_amd_av1_4k.ps1

# Foreign - Intel QSV compression
./Video/Foreign/compress_qsv_x265_aac.ps1
```

**Deduplication:**

```powershell
# TV Content - Audit mode (preview only)
./Video/General/dedup.ps1 -Audit

# TV Content - Perform deduplication
./Video/General/dedup.ps1

# Foreign - Audit mode (preview only)
./Video/Foreign/dedup.ps1 -Audit

# Foreign - Perform deduplication
./Video/Foreign/dedup.ps1
```

**Maintenance:**

```powershell
# Find corrupt TV episodes (Sonarr integration)
./Video/TV/findcorrupt.ps1

# Find corrupt movies (Radarr integration)
./Video/Movies/findcorrupt.ps1

# Find foreign audio TV episodes
./Video/TV/findforeign.ps1

# Repair MKV containers without re-encoding
./Video/TV/remux.ps1

# Rename Specials folders
./Video/General/fixSpecials.ps1

# Scan for corrupt audiobook files
./audio/books/listcorrupt.ps1
```

### Unix-like Systems (Bash)

**Compression:**

```bash
# TV Content - AMD GPU compression
bash ./Video/TV/compress_amd_x265_aac.sh

# TV Content - Language-specific AMD GPU compression
bash ./Video/TV/compress_lang_amd_x265_aac.sh

# Movies - AMD GPU compression
bash ./Video/Movies/compress_amd_x265_aac.sh

# Foreign - AMD GPU compression
bash ./Video/Foreign/compress_amd_x265_aac.sh

# Write NFO metadata to MKV tags (MOVIE vs EPISODE decided from the NFO)
bash ./Video/General/apply-metadata.sh
```

**Maintenance:**

```bash
# Find foreign audio TV episodes
bash ./Video/TV/findforeign.sh

# MP4 to MKV container remux
bash ./Video/Movies/remuxmp4.sh

# Track-filtering MKV remux (keeps eng/und/unk when English audio present)
bash ./Video/TV/repack_mkv_lang.sh

# System sync utilities (run from top-level directory)
bash ./Linux/general/sync.sh               # Powers on USB, runs all sync tasks, powers off
bash ./Linux/general/sync_tv.sh            # TV to <usb-share>/Media/Video/TV
bash ./Linux/general/sync_movies.sh        # Movies to <usb-share>/Media/Video/Movies
bash ./Linux/general/sync_anime.sh         # Anime to <usb-share>/Media/Video/Anime
bash ./Linux/general/sync_audiobooks.sh    # Audiobooks to <usb-share>/Media/audiobooks
bash ./Linux/general/sync_books.sh         # Books to <usb-share>/Media/books
bash ./Linux/general/sync_etv.sh           # TV to <alt-share>/Media/Video/TV (manual trigger)
bash ./Linux/general/sync_backups.sh       # Backups to <usb-share>/DATA/sysdata_backups
bash ./Linux/general/sync_docker.sh        # Docker data to <usb-share> (stops/starts container)
bash ./Linux/general/sync_main_backups.sh  # Backups to <zfs-pool>/main_backups (ZFS dataset)
bash ./Linux/general/sync_sysdocker_maindocker.sh  # Docker data to <zfs-pool>/main_docker (ZFS dataset)

# Windows sync helper (PowerShell)
./Windows/General/sync_robo.ps1  # PowerShell version available
```

**System Utilities:**

```bash
# Linux system maintenance
bash ./Linux/general/lxc-upgrade.sh
bash ./Linux/general/setperm.sh
bash ./Linux/general/showswap.sh
bash ./Linux/general/shrinkvol.sh

# USB drive power management
bash ./Linux/general/usb-poweroff.sh
bash ./Linux/general/usb-poweron.sh

# Directory and metadata cleanup
bash ./Video/General/dircleanup.sh
bash ./Video/General/listuhd.sh
bash ./Video/Anime/fixmkvproperties.sh
  bash ./Video/General/setairdate.sh
bash ./Video/Movies/setreleasedate.sh
```

For detailed usage instructions and script options, see the README files in each folder:

- [Linux/README.md](Linux/README.md)
- [Video/TV/](Video/TV/README.md)
- [Video/Movies/](Video/Movies/README.md)
- [Video/Foreign/](Video/Foreign/README.md)
- [Video/General/](Video/General/README.md)

## How It Works

### Compression Scripts

1. **File Scanning**: Recursively scans for `.mkv`, `.mp4`, and `.ts` files in the script directory or specified path, excluding extras by filename suffix and by Jellyfin extras directory (see [Extras Exclusion](#extras-exclusion))
2. **Smart Filtering**: Skips files below a per-script size threshold (950 MB for the TV bash compressors, 5 GB for the Movies family, 1 GB for the PowerShell compressors) and previously processed files.
3. **Format Analysis**: Uses ffprobe to detect:
   - Video codec and bitrate
   - Audio codec
   - Interlacing status (field order)
4. **Conversion Decision**: Only converts files that meet these criteria:
   - Video is not already x265/HEVC
   - Bitrate exceeds 2.5 Mbps
   - Video is interlaced (not progressive)
   - Note: audio codec is a conversion trigger for Movies and TV scripts (not already AAC) but not for the Foreign `hbcompress_qsv_x265_aac.ps1` (all audio is always copied)
5. **Interlace Detection**: Two-pass analysis:
   - Fast pass: reads `field_order` from stream metadata. Hard interlace flags (`tt`, `bb`, `tb`, `bt`) resolve immediately to `interlaced`; `progressive` resolves to `progressive`
   - Slow pass: when metadata is inconclusive, runs `ffmpeg -vf idet` over ~1000 frames (~200 in PowerShell) starting at the 5-minute mark, and classifies the result as `telecine` (strong TFF/BFF with a low interlaced count), `interlaced` (high interlaced count), or `progressive`
   - The classification has exactly three outcomes; there is no `unknown` state. Anything the two passes do not classify as interlaced or telecine stays progressive
6. **Deinterlacing**: Applies one filter per detection result - `bwdif=mode=send_frame` for interlaced, `pullup,dejudder` for telecine, no filter for progressive
7. **Parallel Processing**: Runs encoding jobs with a configurable concurrency limit (`$MaxJobs` / `MAX_JOBS`). The default is 1 for `Video/TV`, `Video/General`, `Video/Foreign` and `Video/Anime` `compress_amd_x265_aac.sh` and for `Video/TV/compress_qsv_x265_aac.ps1`; it is 2 everywhere else
8. **Output**: Writes new files with quality preserved at reduced size

### Extras Exclusion

The bash compressors build their candidate list with a single `find`, so a file is excluded if **either** a filename suffix **or** a directory path matches. Both lists are fixed in the script rather than configurable.

Filename suffixes (all 8): `trailer`, `behindthescenes`, `featurette`, `interview`, `scene`, `short`, `deleted`, `sample`

Directory names (all 13): `behind the scenes`, `deleted scenes`, `interviews`, `scenes`, `samples`, `shorts`, `featurettes`, `clips`, `other`, `extras`, `trailers`, `theme-music`, `backdrops`

Directory matching is on any path component, so a series folder containing an `extras/` or `trailers/` subfolder is skipped whole.

### Skip Markers and Processing Fingerprint

- A `.skip` file in a directory skips the entire directory
- A `.skip_<basename>` file next to a video skips that one file
- Output is written to `<name>[Trans].tmp` beside the source, then moved into place once it passes the replace gate
- A leftover `[Trans]` file from an interrupted run is deleted at the end of the run. Outside the HandBrake scripts nothing records that a file was already processed, so a file skipped for any other reason (already HEVC, under the bitrate threshold, or a declined replace gate) is reconsidered on the next run
- The `hbcompress_*` scripts do record it: when a file is already compliant they write the file size and last-write time in 100ns ticks into its `.skip_<basename>` marker, tagged `compliant-v1` (or `compliant-1080psdr-v1` for `Video/TV/hbcompress_1080p_amd_x265_aac.ps1`). A marker is only honoured when both values still match, so an edited file is rechecked. The 1080p SDR script only trusts its own tag, since a `compliant-v1` tag from `hbcompress_amd_x265_aac.ps1` says nothing about resolution or HDR
- Both the bash and PowerShell scripts delete files tagged `[Cleaned]` or `[Trans]` automatically

### Deduplication Scripts

1. **Pattern Detection**: Scans files for episode codes (S##E##, ##x##, etc.)
2. **Grouping**: Groups potential duplicates by episode code within each directory
3. **Priority Selection**: Applies priority: File Type (MKV > MP4 > TS > AVI) -> File Size (largest)
4. **Cleanup**: Removes all sidecar files associated with deleted episodes
5. **Reporting**: Generates detailed summary of actions taken

## Configuration Options

Edit the script header to customize:

**PowerShell Compression Scripts (compress_qsv_x265_aac.ps1, hbcompress_qsv_x265_aac.ps1, hbcompress_amd_x265_aac.ps1):**

```powershell
$MaxJobs = 1                    # Parallel encoding jobs (compress_qsv only; hbcompress_* run serially)
```

**Bash Compression Scripts (compress_amd_x265_aac.sh, compress_lang_amd_x265_aac.sh):**

```bash
MAX_JOBS=1                      # Number of parallel encoding jobs (compress_lang uses 2)
```

**PowerShell Deduplication (dedup.ps1):**

```powershell
# Run with -Audit flag for preview mode
./dedup.ps1 -Audit              # Preview changes without deleting
./dedup.ps1                     # Perform actual deduplication
```

**PowerShell Foreign Audio (findforeign.ps1):**

```powershell
./findforeign.ps1 -Root "D:\Media" -CsvFile "D:\Logs\foreign.csv"
```

## Encoder Selection

### Intel QSV (Quick Sync Video)

- **Files**: compress_qsv_x265_aac.ps1, hbcompress_qsv_x265_aac.ps1
- **Best For**: Intel processors with integrated graphics
- **Performance**: Excellent power efficiency
- **Compatibility**: Works with most modern Intel CPUs

### AMD VAAPI

- **Files**: compress_amd_x265_aac.sh, compress_amd_x265_aac.ps1
- **Best For**: AMD GPUs (Radeon RX series)
- **Performance**: High throughput with parallel encoding
- **Compatibility**: Requires compatible AMD hardware with VAAPI support (/dev/dri/renderD128)

### HandBrake Integration

- **Files**: hbcompress_amd_x265_aac.ps1 (Windows with AMD VCE), hbcompress_qsv_x265_aac.ps1 (Windows with Intel QSV), hbcompress_amd_av1_4k.ps1 (Windows with AMD VCE AV1)
- **Best For**: HandBrake encoding workflows with hardware acceleration
- **Features**: Container repair, file lock detection, atomic replacement, deferred interlace detection, 4K/AV1 guards, subtitle language filtering

## Performance Tips

1. **Adjust $MaxJobs / MAX_JOBS**: Start with 2-3 concurrent jobs; increase on powerful systems with more VRAM
2. **Use Fast SSD**: Place $TempDir on the fastest available drive
3. **Monitor Temperature**: GPU encoding generates heat; ensure proper cooling
4. **Schedule Off-Peak**: Run during off-peak hours to avoid system impact
5. **Test First**: Run on a small subset of files to verify output quality

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "ffmpeg not found" | Ensure FFmpeg is installed and in your PATH |
| Slow encoding | Reduce $MaxJobs or check GPU utilization |
| Poor output quality | Verify input file format; try with different encoder |
| Out of disk space | Increase $TempDir capacity or reduce $MaxJobs |
| GPU not being used | Verify hardware encoder support; check FFmpeg codecs with ffmpeg -codecs |
| File timestamps not updating after edit | Samba directory caching over a ZFS dataset. `sync_tv.sh` and friends flush the backing block device (`blockdev --flushbufs`) before returning; see [Linux/general/README.md](Linux/general/README.md) |

## Requirements Summary

- **OS**: Windows (PowerShell) or Linux/macOS (Bash)
- **FFmpeg**: v4.0 or later
- **Hardware**: GPU with h.265/HEVC encoding support
- **Disk Space**: At least 20% free space for temporary files
- **RAM**: 4GB minimum, 8GB+ recommended

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing

Contributions are welcome! Feel free to:

- Report bugs and issues
- Suggest improvements and new features
- Submit pull requests with enhancements
- Improve documentation

## Support

For questions, issues, or feature requests, please open an issue on the project repository.

---

**Author**: TCBW
**Last Updated**: September 2026
