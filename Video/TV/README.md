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

Bash script for video compression using AMD GPU hardware acceleration (VAAPI). Optimized for files 1GB or larger.

Features:

- Processes .mkv, .mp4, and .ts files
- Automatic filtering for already-processed files (marked with [Cleaned] or [Trans])
- Interlace/telecine detection with two-pass scanning (metadata check + deep frame analysis)
- Deinterlace filters: bwdif (bilateral) for interlaced, fieldmatch+decimate+bwdif for telecine
- Parallel encoding support (default: 2 concurrent jobs)
- Minimum file size: 1GB

**Platform**: Linux/Unix with AMD GPU support

### hbcompress_qsv_x265_aac.ps1

**Status**: Stable (HandBrake-specific variant)

HandBrake-optimized PowerShell script using Intel Quick Sync Video (QSV). Specialized for HandBrake encoding workflows and integration. Optimized for files 1GB or larger.

**Platform**: Windows with Intel Quick Sync support

## Usage

```bash
# Bash (AMD GPU)
./compress_amd_x265_aac.sh

# PowerShell (Intel GPU) - HandBrake variant
./hbcompress_qsv_x265_aac.ps1
```

## Encoding Settings

- **Video Codec**: hevc_vaapi (AMD) or hevc_qsv (Intel)
- **Quality**: QP 24 (quantizer value, lower = better quality)
- **Bitrate Target**: 1800kbps with max 2000kbps and 4000kbps buffer
- **Audio**: AAC at 160kbps (copied if already AAC)
- **Container**: Matroska (.mkv)

## Notes

- Interlace detection runs in two stages: first checks field_order metadata, then performs frame-level analysis if needed
- Temporary files use `.tmp` extension and are cleaned up on success or error
- Original file timestamps are preserved after successful encoding
- Original file ownership can be set by uncommenting the `chown` line in scripts (currently disabled for portability)
