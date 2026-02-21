# Video Compression Scripts (5GB+ Minimum)

Compression and transcoding scripts optimized for files at least 5GB in size. These scripts convert interlaced video to x265 (HEVC) format with AAC audio, with intelligent audio/subtitle track filtering.

## ⚠️ DISCLAIMER

**Use at your own risk!** These scripts perform destructive operations on video files. Always test on non-critical files first and maintain backups of your original content before using these scripts.

## Requirements

### Common

- **FFmpeg**: v4.0 or later, **must be on system PATH**
  - Verify installation: `ffmpeg -version`
  - Windows: `winget install FFmpeg` or `choco install ffmpeg` or download from [ffmpeg.org](https://ffmpeg.org/download.html)
  - Linux: `apt install ffmpeg` or `yum install ffmpeg`
- **FFprobe**: Included with FFmpeg, used for video analysis
- **jq**: JSON query utility (required for advanced track filtering in new scripts)
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

### clean_compress_amd_x265_aac.sh ⭐ Revised

**Status**: Production-ready with intelligent track filtering

Bash script for video compression with advanced audio/subtitle track management. Automatically selects English-language audio and subtitle tracks while filtering out foreign language variants. Optimized for files 5GB or larger.

**Features:**

- Intelligent audio/subtitle filtering (keeps English + unknown/untagged streams)
- Dynamic stream track discovery (works even if tracks are reordered)
- Minimum file size: 5GB (configurable)
- Video codec decision: copies x265 if bitrate ≤ 2.5Mbps, re-encodes otherwise
- Interlace/telecine detection with bwdif and fieldmatch filters
- Parallel encoding support (default: 2 concurrent jobs)

**Platform**: Linux/Unix with AMD GPU support

**Audio/Subtitle Filtering**: Enabled

### clean_compress_qsv_x265_aac.ps1 ⭐ Revised

**Status**: Production-ready with intelligent track filtering

PowerShell script for video compression using Intel Quick Sync Video (QSV). Same track filtering intelligence as the AMD bash variant but optimized for Windows/Intel hardware. Best for files 5GB or larger.

**Features:**

- Intelligent audio/subtitle filtering (keeps English + unknown/untagged streams)
- Dynamic stream track discovery
- Minimum file size: 5GB
- Video codec decision logic with bitrate-aware copying
- Interlace/telecine detection
- Intel QSV hardware acceleration
- Supports .mkv, .mp4, .ts container formats

**Platform**: Windows with Intel Quick Sync support

**Audio/Subtitle Filtering**: Enabled

### compress_amd_x265_aac.sh

**Status**: Stable

Bash script for video compression using AMD GPU hardware acceleration (VAAPI). Core video re-encoding functionality for interlaced content. Optimized for files 5GB or larger.

**Features:**

- Processes .mkv, .mp4, and .ts files
- Automatic filtering for already-processed files (marked with [Cleaned] or [Trans])
- Parallel encoding support (default: 2 concurrent jobs)
- Minimum file size: 5GB
- **Note**: Does not perform audio/subtitle filtering; use `clean_compress_amd_x265_aac.sh` for track selection

**Platform**: Linux/Unix with AMD GPU support

### compress_qsv_x265_aac.ps1

**Status**: Stable

PowerShell script for video compression using Intel Quick Sync Video (QSV). Optimized for files 5GB or larger.

**Features:**

- Processes .mkv and .ts files
- Configurable temporary directory for intermediate files
- Progress tracking and filtering for already-processed content
- Parallel encoding support
- Minimum file size: 5GB
- **Note**: Does not perform audio/subtitle filtering; use `clean_compress_qsv_x265_aac.ps1` for track selection

**Platform**: Windows with Intel Quick Sync support

### hbcompress_x265_aac.ps1

**Status**: Stable

PowerShell script using HandBrake CLI for video compression with Intel Quick Sync Video (QSV) support. Specialized for HandBrake encoding workflows. Optimized for files 5GB or larger.

**Features:**

- Integration with HandBrakeCLI for advanced encoding options
- Intel QSV hardware acceleration
- Parallel job support

**Platform**: Windows  with Intel Quick Sync support

### clean_compressUHD_qsv_x265_aac.ps1 ⭐ 4K Specialized

**Status**: Production-ready

PowerShell script specialized for 4K/UHD content compression using Intel Quick Sync Video (QSV) with profile 6.2 encoding. Optimized for files 8GB or larger.

**Features:**

- QP 24 constant quality encoding with profile 6.2 support
- 4K/UHD content detection (≥3840px width)
- Bitrate threshold: 20 Mbps (Profile 6.2 standard)
- Intelligent audio/subtitle track filtering
- Skip marker handling (`.skip` files prevent reprocessing)
- Directory skip functionality (files in directories with `.skip` file are skipped)
- Comprehensive cleanup that removes all intermediate files in case of crashes

**Platform**: Windows with Intel Quick Sync support

**Audio/Subtitle Filtering**: Enabled

**Special Features:**

- Detects and removes incomplete jobs (files marked `[Cleaned]` indicate crashed sessions)
- Automatically removes files that don't compress efficiently

### dedup.ps1

**Status**: Stable

PowerShell script for identifying and removing duplicate video files within movie directories. Uses file size and quality heuristics to determine which duplicates to keep.

**Features:**

- Priority-based selection: MKV > MP4 > AVI > TS
- Keeps largest file when priority is equal
- Removes associated sidecar files (.nfo, .srt, .jpg, .trickplay, etc.)
- Audit mode support (preview deletions without applying)
- Comprehensive summary reporting

**Platform**: Windows

**Usage:**

```powershell
# Normal mode (performs deletions)
.\dedup.ps1

# Audit mode (preview only)
.\dedup.ps1 -Audit
```

## Usage

For files with multiple audio/subtitle tracks requiring intelligent filtering:

```bash
# Bash (AMD GPU)
./clean_compress_amd_x265_aac.sh

# PowerShell (Intel GPU)
./clean_compress_qsv_x265_aac.ps1
```

For basic compression without track filtering:

```bash
# Bash (AMD GPU)
./compress_amd_x265_aac.sh

# PowerShell (Intel GPU)  
./compress_qsv_x265_aac.ps1
```

For 4K/UHD content:

```powershell
# PowerShell (Intel GPU)
./clean_compressUHD_qsv_x265_aac.ps1
```

## Notes

- Require `jq` for JSON parsing (especially important for track filtering scripts)
- Temporary files use `.tmp` extension and are automatically cleaned up on success
- **Skip Files**: When compression does not result in a smaller file, a `.skip` file is created in the directory. This hidden file marks the directory as having files unsuitable for compression (already optimized). Delete the `.skip` file if you want to retry compression on that directory.
- **Cleanup on Shutdown**: Any files marked with `[Cleaned]` or `[Trans]` in the filename after script completion indicate crashed FFmpeg sessions and should be manually reviewed
- **Audio/Subtitle Filtering**: `clean_*` and UHD scripts intelligently filter audio/subtitle tracks, keeping only English language and unknown/untagged streams
- **Original Files**: Intermediate `.tmp` files are removed after successful compression; only `.mkv` output and original files (if unchanged size) are retained

- Dynamic stream track discovery (works even if tracks are reordered)
- Minimum file size: 5GB (configurable)
- Video codec decision: copies x265 if bitrate ≤ 2.5Mbps, re-encodes otherwise
- Interlace/telecine detection with bwdif and fieldmatch filters
- Parallel encoding support (default: 2 concurrent jobs)

**Platform**: Linux/Unix with AMD GPU support

**Audio/Subtitle Filtering**: Enabled

### clean_compress_qsv_x265_aac.ps1 ⭐ Revised

**Status**: Production-ready with intelligent track filtering

PowerShell script for video compression using Intel Quick Sync Video (QSV). Same track filtering intelligence as the AMD bash variant but optimized for Windows/Intel hardware. Best for files 5GB or larger.

Features:

- Intelligent audio/subtitle filtering (keeps English + unknown/untagged streams)
- Dynamic stream track discovery
- Minimum file size: 5GB
- Video codec decision logic with bitrate-aware copying
- Interlace/telecine detection
- Intel QSV hardware acceleration
- Supports .mkv, .mp4, .ts container formats

**Platform**: Windows with Intel Quick Sync support

**Audio/Subtitle Filtering**: Enabled

### compress_amd_x265_aac.sh

**Status**: Stable

Bash script for video compression using AMD GPU hardware acceleration (VAAPI). Core video re-encoding functionality for interlaced content. Optimized for files 5GB or larger.

Features:

- Processes .mkv, .mp4, and .ts files
- Automatic filtering for already-processed files (marked with [Cleaned] or [Trans])
- Parallel encoding support (default: 2 concurrent jobs)
- Minimum file size: 5GB
- **Note**: Does not perform audio/subtitle filtering; use `clean_compress_amd_x265_aac.sh` for track selection

**Platform**: Linux/Unix with AMD GPU support

### compress_qsv_x265_aac.ps1

**Status**: Stable

PowerShell script for video compression using Intel Quick Sync Video (QSV). Optimized for files 5GB or larger.

Features:

- Processes .mkv and .ts files
- Configurable temporary directory for intermediate files
- Progress tracking and filtering for already-processed content
- Parallel encoding support
- Minimum file size: 5GB
- **Note**: Does not perform audio/subtitle filtering; use `clean_compress_qsv_x265_aac.ps1` for track selection

**Platform**: Windows with Intel Quick Sync support

### hbcompress_x265_aac.ps1

**Status**: Stable

PowerShell script using HandBrake CLI for video compression with Intel Quick Sync Video (QSV) support. Specialized for HandBrake encoding workflows. Optimized for files 5GB or larger.

Features:

- Integration with HandBrakeCLI for advanced encoding options
- Intel QSV hardware acceleration
- Parallel job support

**Platform**: Windows  with Intel Quick Sync support

### clean_compressUHD_qsv_x265_aac.ps1 ⭐ 4K Specialized

**Status**: Production-ready

PowerShell script specialized for 4K/UHD content compression using Intel Quick Sync Video (QSV) with profile 6.2 encoding. Optimized for files 8GB or larger.

Features:

- QP 24 constant quality encoding with profile 6.2 support
- 4K/UHD content detection (≥3840px width)
- Bitrate threshold: 20 Mbps (Profile 6.2 standard)
- Intelligent audio/subtitle track filtering
- Skip marker handling (`.skip` files prevent reprocessing)
- Directory skip functionality (files in directories with `.skip` file are skipped)
- Comprehensive cleanup that removes all intermediate files in case of crashes

**Platform**: Windows with Intel Quick Sync support

**Audio/Subtitle Filtering**: Enabled

**Special Features**:

- Detects and removes incomplete jobs (files marked `[Cleaned]` indicate crashed sessions)
- Automatically removes files that don't compress efficiently

### dedup.ps1

**Status**: Stable

PowerShell script for identifying and removing duplicate video files within movie directories. Uses file size and quality heuristics to determine which duplicates to keep.

Features:

- Priority-based selection: MKV > MP4 > AVI > TS
- Keeps largest file when priority is equal
- Removes associated sidecar files (.nfo, .srt, .jpg, .trickplay, etc.)
- Audit mode support (preview deletions without applying)
- Comprehensive summary reporting

**Platform**: Windows

**Usage**

```powershell
# Normal mode (performs deletions)
.\dedup.ps1

# Audit mode (preview only)
.\dedup.ps1 -Audit
```

**Usage**

For files with multiple audio/subtitle tracks requiring intelligent filtering:

```bash
# Bash (AMD GPU)
./clean_compress_amd_x265_aac.sh

# PowerShell (Intel GPU)
./clean_compress_qsv_x265_aac.ps1
```

For basic compression without track filtering:

```bash
# Bash (AMD GPU)
./compress_amd_x265_aac.sh

# PowerShell (Intel GPU)  
./compress_qsv_x265_aac.ps1
```

For 4K/UHD content:

```powershell
# PowerShell (Intel GPU)
./clean_compressUHD_qsv_x265_aac.ps1
```

**Notes**

- Require `jq` for JSON parsing (especially important for track filtering scripts)
- Temporary files use `.tmp` extension and are automatically cleaned up on success
- **Skip Files**: When compression does not result in a smaller file, a `.skip` file is created in the directory. This hidden file marks the directory as having files unsuitable for compression (already optimized). Delete the `.skip` file if you want to retry compression on that directory.
- **Cleanup on Shutdown**: Any files marked with `[Cleaned]` or `[Trans]` in the filename after script completion indicate crashed FFmpeg sessions and should be manually reviewed
- **Audio/Subtitle Filtering**: `clean_*` and UHD scripts intelligently filter audio/subtitle tracks, keeping only English language and unknown/untagged streams
- **Original Files**: Intermediate `.tmp` files are removed after successful compression; only `.mkv` output and original files (if unchanged size) are retained
