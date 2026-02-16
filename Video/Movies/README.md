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

Features:

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

### hbcompress_qsv_x265_aac.ps1

**Status**: Stable (HandBrake-specific variant)

HandBrake-optimized PowerShell script using Intel Quick Sync Video (QSV). Specialized for HandBrake encoding workflows and integration. Optimized for files 5GB or larger.

**Platform**: Windows with Intel Quick Sync support

### dedup.ps1

PowerShell script for identifying and managing duplicate video files.

**Platform**: Windows

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

## Notes

- Require `jq` for JSON parsing (especially important for track filtering scripts)
- Temporary files use `.tmp` extension and are cleaned up on success
- Original file ownership can be set by uncommenting the `chown` line in scripts (currently disabled for portability)
