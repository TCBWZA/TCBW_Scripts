# Video Compression Scripts (1GB+ Minimum)

Compression and transcoding scripts optimized for files at least 1GB in size. These scripts convert interlaced video to x265 (HEVC) format with AAC audio.

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

Bash script for video compression using AMD GPU hardware acceleration (VAAPI).

Features:

- Processes .mkv, .mp4, and .ts files
- Interlace/telecine detection with two-pass scanning
- Deinterlace filters: bwdif (bilateral) for interlaced, fieldmatch+decimate+bwdif for telecine
- Parallel encoding support (default: 2 concurrent jobs)
- Minimum file size: 1GB

**Platform**: Linux/Unix with AMD GPU support

### compress_qsv_x265_aac.ps1

**Status**: Stable

PowerShell script for video compression using Intel Quick Sync Video (QSV) encoding.

Features:

- Processes .mkv and .ts files
- Configurable temporary directory for intermediate files
- Progress tracking and filtering for already-processed content
- Parallel encoding support
- Same interlace/telecine detection as bash variant
- Minimum file size: 1GB

**Platform**: Windows with Intel Quick Sync support

### compressmp4_amd_x265_aac.sh

**Status**: Stable (MP4 specialized)

Bash script specialized for MP4 file compression with AMD GPU acceleration.

Features:

- Processes MP4 container format specifically
- Optimized for batch MP4 processing
- Parallel job support
- VAAPI hardware acceleration for AMD GPUs
- Minimum file size: 1GB

**Platform**: Linux/Unix with AMD GPU support

### hbcompress_qsv_x265_aac.ps1

**Status**: Stable (HandBrake-specific variant)

HandBrake-optimized PowerShell script using Intel Quick Sync Video (QSV). Specialized for HandBrake encoding workflows and integration. Optimized for files 1GB or larger.

**Platform**: Windows with Intel Quick Sync support

## Usage

```bash
# Bash - standard compression (AMD GPU)
./compress_amd_x265_aac.sh

# Bash - MP4 specific (AMD GPU)
./compressmp4_amd_x265_aac.sh

# PowerShell (Intel GPU)
./compress_qsv_x265_aac.ps1

# PowerShell - alternative variant (Intel GPU)
./hbcompress_qsv_x265_aac.ps1
```

## Encoding Settings

- **Video Codec**: hevc_vaapi (AMD) or hevc_qsv (Intel)
- **Quality**: QP 24 (quantizer value, lower = better quality)
- **Bitrate Target**: 1800kbps with max 2000kbps and 4000kbps buffer
- **Audio**: AAC at 160kbps (copied if already AAC)
- **Container**: Matroska (.mkv) or MP4 (.mp4)

## Notes

### Skip Markers

The scripts use hierarchical skip markers to prevent reprocessing of unsuitable content:

- **`.skip` in parent directory**: Marks the entire parent directory as unsuitable for compression. When present, all scripts in that directory will be skipped.
- **`.skip_SHOWNAME` in current directory**: Marks a specific show or episode group as unsuitable (based on the first word of the filename). Created automatically when compression doesn't reduce file size.

The scripts check both markers before processing:

1. If parent `/.skip` exists → skip all files in current and subdirectories
2. If `.skip_SHOWNAME` exists → skip files matching that show name

To retry compression on skipped files, delete the corresponding `.skip_*` files.

### File Size Handling

- Original file is only replaced if compressed version is smaller
- If compression produces a file of equal or greater size, the compressed version is discarded and a `.skip_SHOWNAME` marker is created
- File timestamps are preserved after successful replacement
- Size comparisons use actual byte count (not disk allocation)

### Other Notes

- Original file timestamps are preserved after successful encoding
- Original file ownership can be set by uncommenting the `chown` line in scripts (currently disabled for portability)
- `compressmp4_amd_x265_aac.sh` is optimized for MP4 containers which may have different metadata structure
