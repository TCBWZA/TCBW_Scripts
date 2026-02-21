# TV Shows Video Scripts

Compression and transcoding scripts optimized for TV show content. These scripts convert interlaced video to x265 (HEVC) format with AAC audio.

## ⚠️ DISCLAIMER

**Use at your own risk!** These scripts perform destructive operations on video files. Always test on non-critical files first and maintain backups of your original content before using these scripts.

## Requirements

### Common

- **FFmpeg**: v4.0 or later, **must be on system PATH**
  - Verify installation: `ffmpeg -version`
  - Windows: `winget install FFmpeg` or `choco install ffmpeg` or download from [ffmpeg.org](https://ffmpeg.org/download.html)
  - Linux: `apt install ffmpeg` or `yum install ffmpeg`
- **FFprobe**: Included with FFmpeg, used for video analysis
- **jq**: JSON query utility (required for stream metadata extraction)
  - Linux: `apt install jq` or `yum install jq`
  - Windows: `scoop install jq` or `choco install jq`

### Platform-Specific

- **Bash scripts (AMD)**: Linux/Unix system with bash shell and AMD GPU with VAAPI support (AMD Radeon RX series or newer)
- **PowerShell scripts (Intel QSV)**: Windows with PowerShell 7.0 or later and Intel processor with Quick Sync Video support
- **HandBrake-specific scripts**: HandBrakeCLI must be installed and on system PATH
  - Windows: `choco install handbrake-cli` or `winget install HandBrake.HandBrakeCLI` or download from [handbrake.fr](https://handbrake.fr/)
  - Linux: `apt install handbrake-cli` or `yum install handbrake-cli`
  - Verify installation: `HandBrakeCLI --version`

## Files

### compress_amd_x265_aac.sh

**Status**: Stable

Bash script for video compression using AMD GPU hardware acceleration (VAAPI). Optimized for TV episode files 1GB or larger.

**Features:**

- Processes .mkv, .mp4, and .ts files
- Automatic filtering for already-processed files (marked with [Trans] only)
- Skip marker handling for show-specific exclusion
- Interlace/telecine detection with optimized two-pass scanning:
  - Metadata check first (field_order)
  - Deep frame analysis on actual content (skips first 5 minutes to avoid intros/credits)
  - Analyzes 200 frames for accurate detection
- Deinterlace filters: bwdif (bilateral) for interlaced, fieldmatch+decimate+bwdif for telecine
- Parallel encoding support (default: 2 concurrent jobs)
- Minimum file size: 1GB

**Platform**: Linux/Unix with AMD GPU support

### hbcompress_qsv_x265_aac.ps1

**Status**: Stable (HandBrake-specific variant)

HandBrake-optimized PowerShell script using Intel Quick Sync Video (QSV). Specialized for HandBrake encoding workflows with optimizations for TV episodes. Optimized for files 1GB or larger.

**Features:**

- Processes .mkv, .mp4, and .ts files
- Automatic filtering for already-processed files (marked with [Trans] only)
- HandBrake CLI integration
- Interlace/telecine detection with optimized frame analysis:
  - Skips first 5 minutes of video to avoid intros/credits
  - Analyzes 20 frames for accurate detection
- Always applies decomb filter for interlaced content
- Parallel job support

**Platform**: Windows with Intel Quick Sync support

### dedup.ps1

**Status**: Stable

PowerShell script for identifying and removing duplicate episodes within TV show directories.

**Features:**

- **Pattern Matching**: Scans recursive directory tree for files matching episode patterns:
  - `S##E##` or `S##E###` (e.g., S01E05, S18E012) — standard format
  - `##x##` or `##x###` (e.g., 01x05, 01x012) — alternative format
  - Both formats normalized internally to S##E### for matching
- **Duplicate Detection**:
  - Groups files by episode code **within the same directory**
  - Only considers files as duplicates if they share the same episode code AND are in the same folder
  - Episodes with only one file are automatically kept (no decision needed)
- **File Selection Logic** (when duplicates exist):
  - **Primary**: File type priority: MKV > MP4 > TS > AVI
  - **Secondary**: File size (largest wins if file types are equal)
  - Example: If a directory has `Episode.S01E01.mkv` (500MB) and `Episode.S01E01.mp4` (600MB), the MKV is kept regardless of size
- **Sidecar Cleanup**:
  - Removes all associated files for deleted episodes:
    - Subtitle files (.srt, .sub, .ass, .ssa)
    - Metadata (.nfo, .xml)
    - Images (.jpg, .png)
    - Trickplay directories (.trickplay)
    - Any file starting with the same base name as deleted video
- **Audit Mode** (`-Audit` flag): Preview what would be deleted without making any changes
- **Output**: Detailed summary report showing episodes kept, deleted, and sidecar files removed
- **Cleanup**: Removes all `[Trans]` files and directories on completion

**Usage:**

```powershell
# Preview what would be deleted (audit mode - recommended for first run)
./dedup.ps1 -Audit

# Perform actual deduplication
./dedup.ps1
```

**Platform**: Windows with PowerShell 7.0 or later

## Usage

```bash
# Bash (AMD GPU) - Compression
./compress_amd_x265_aac.sh

# PowerShell (Intel GPU) - HandBrake variant compression
./hbcompress_qsv_x265_aac.ps1

# PowerShell - Deduplication (audit mode - preview changes)
./dedup.ps1 -Audit

# PowerShell - Deduplication (perform actual dedup)
./dedup.ps1
```

## Encoding Settings

- **Video Codec**: hevc_vaapi (AMD) or hevc_qsv (Intel)
- **Quality**: QP 24 (quantizer value, lower = better quality)
- **Bitrate Target**: 1800kbps with max 2000kbps and 4000kbps buffer
- **Audio**: AAC at 160kbps (copied if already AAC)
- **Container**: Matroska (.mkv)

## Notes

### Compression Scripts

- Interlace detection optimization: Skips first 5 minutes of video to avoid intros/credits, then analyzes frames for accurate detection
  - This improves both detection accuracy and script performance
  - Only analyzes relevant content (200 frames in bash, 20 in PowerShell)
- Temporary files use `.tmp` extension and are cleaned up on success or error
- Original file timestamps are preserved after successful encoding
- Original file ownership can be set by uncommenting the `chown` line in scripts (currently disabled for portability)
- **Skip Files (TV-Specific - [Trans] Only)**:
  - `.skip` in parent directory: marks entire parent directory as unsuitable for compression
  - `.skip_SHOWNAME` in current directory: marks specific show (extracted from filename prefix) as unsuitable for compression
  - Scripts check both markers before processing files
  - Files in directories with `.skip` files are automatically skipped
  - Delete skip files to retry compression on marked content
- **Cleanup on Shutdown**: Any files marked with `[Trans]` in the filename after script completion indicate crashed FFmpeg sessions and should be manually reviewed

### Deduplication Script

- **Priority order**: File type (MKV > MP4 > TS > AVI) takes precedence over file size
- Removes all sidecar files (.nfo, .srt, .jpg, .trickplay directories, etc.) for deleted episodes
- Audit mode (`-Audit`) shows what would be deleted without making any changes — recommended for first run
- Progress bars during directory deletion are suppressed for cleaner output
- Timestamps on kept files are preserved from the original set

- Automatic filtering for already-processed files (marked with [Trans] only)
- Skip marker handling for show-specific exclusion
- Interlace/telecine detection with optimized two-pass scanning:
  - Metadata check first (field_order)
  - Deep frame analysis on actual content (skips first 5 minutes to avoid intros/credits)
  - Analyzes 200 frames for accurate detection
- Deinterlace filters: bwdif (bilateral) for interlaced, fieldmatch+decimate+bwdif for telecine
- Parallel encoding support (default: 2 concurrent jobs)
- Minimum file size: 1GB

**Platform**: Linux/Unix with AMD GPU support

### hbcompress_qsv_x265_aac.ps1

**Status**: Stable (HandBrake-specific variant)

HandBrake-optimized PowerShell script using Intel Quick Sync Video (QSV). Specialized for HandBrake encoding workflows with optimizations for TV episodes. Optimized for files 1GB or larger.

Features:

- Processes .mkv, .mp4, and .ts files
- Automatic filtering for already-processed files (marked with [Trans] only)
- HandBrake CLI integration
- Interlace/telecine detection with optimized frame analysis:
  - Skips first 5 minutes of video to avoid intros/credits
  - Analyzes 20 frames for accurate detection
- Always applies decomb filter for interlaced content
- Parallel job support

**Platform**: Windows with Intel Quick Sync support

### dedup.ps1

**Status**: Stable

PowerShell script for identifying and removing duplicate episodes within TV show directories.

Features:

- **Pattern Matching**: Scans recursive directory tree for files matching episode patterns:
  - `S##E##` or `S##E###` (e.g., S01E05, S18E012) — standard format
  - `##x##` or `##x###` (e.g., 01x05, 01x012) — alternative format
  - Both formats normalized internally to S##E### for matching
- **Duplicate Detection**:
  - Groups files by episode code **within the same directory**
  - Only considers files as duplicates if they share the same episode code AND are in the same folder
  - Episodes with only one file are automatically kept (no decision needed)
- **File Selection Logic** (when duplicates exist):
  - **Primary**: File type priority: MKV > MP4 > TS > AVI
  - **Secondary**: File size (largest wins if file types are equal)
  - Example: If a directory has `Episode.S01E01.mkv` (500MB) and `Episode.S01E01.mp4` (600MB), the MKV is kept regardless of size
- **Sidecar Cleanup**:
  - Removes all associated files for deleted episodes:
    - Subtitle files (.srt, .sub, .ass, .ssa)
    - Metadata (.nfo, .xml)
    - Images (.jpg, .png)
    - Trickplay directories (.trickplay)
    - Any file starting with the same base name as deleted video
- **Audit Mode** (`-Audit` flag): Preview what would be deleted without making any changes
- **Output**: Detailed summary report showing episodes kept, deleted, and sidecar files removed
- **Cleanup**: Removes all `[Trans]` files and directories on completion

**Usage:**

```powershell
# Preview what would be deleted (audit mode - recommended for first run)
./dedup.ps1 -Audit

# Perform actual deduplication
./dedup.ps1
```

**Platform**: Windows with PowerShell 7.0 or later

## Usage

```bash
# Bash (AMD GPU) - Compression
./compress_amd_x265_aac.sh

# PowerShell (Intel GPU) - HandBrake variant compression
./hbcompress_qsv_x265_aac.ps1

# PowerShell - Deduplication (audit mode - preview changes)
./dedup.ps1 -Audit

# PowerShell - Deduplication (perform actual dedup)
./dedup.ps1
```

## Encoding Settings

- **Video Codec**: hevc_vaapi (AMD) or hevc_qsv (Intel)
- **Quality**: QP 24 (quantizer value, lower = better quality)
- **Bitrate Target**: 1800kbps with max 2000kbps and 4000kbps buffer
- **Audio**: AAC at 160kbps (copied if already AAC)
- **Container**: Matroska (.mkv)

## Notes

### Compression Scripts

- Interlace detection optimization: Skips first 5 minutes of video to avoid intros/credits, then analyzes frames for accurate detection
  - This improves both detection accuracy and script performance
  - Only analyzes relevant content (200 frames in bash, 20 in PowerShell)
- Temporary files use `.tmp` extension and are cleaned up on success or error
- Original file timestamps are preserved after successful encoding
- Original file ownership can be set by uncommenting the `chown` line in scripts (currently disabled for portability)
- **Skip Files (TV-Specific - [Trans] Only)**:
  - `.skip` in parent directory: marks entire parent directory as unsuitable for compression
  - `.skip_SHOWNAME` in current directory: marks specific show (extracted from filename prefix) as unsuitable for compression
  - Scripts check both markers before processing files
  - Files in directories with `.skip` files are automatically skipped
  - Delete skip files to retry compression on marked content
- **Cleanup on Shutdown**: Any files marked with `[Trans]` in the filename after script completion indicate crashed FFmpeg sessions and should be manually reviewed

### Deduplication Script

- **Priority order**: File type (MKV > MP4 > TS > AVI) takes precedence over file size
- Removes all sidecar files (.nfo, .srt, .jpg, .trickplay directories, etc.) for deleted episodes
- Audit mode (`-Audit`) shows what would be deleted without making any changes — recommended for first run
- Progress bars during directory deletion are suppressed for cleaner output
- Timestamps on kept files are preserved from the original set
