# TV Shows Video Scripts

Deinterlacing and transcoding scripts optimized for TV show content. These scripts convert interlaced video to x265 (HEVC) format with AAC audio.

## Requirements

### Common
- **FFmpeg**: v4.0 or later, **must be on system PATH**
  - Verify installation: `ffmpeg -version`
  - Windows: `choco install ffmpeg` or download from [ffmpeg.org](https://ffmpeg.org/download.html)
  - Linux: `apt install ffmpeg` or `yum install ffmpeg`
- **FFprobe**: Included with FFmpeg, used for video analysis

### Platform-Specific
- **Bash scripts (AMD)**: Linux/Unix system with bash shell and AMD GPU with VAAPI support (AMD Radeon RX series or newer)
- **PowerShell scripts (Intel QSV)**: Windows with PowerShell 7.0 or later and Intel processor with Quick Sync Video support

## Files

### deinterlace_amd_x265_aac.sh
Bash script for deinterlacing TV show files using AMD GPU hardware acceleration (VAAPI). Processes .mkv, .mp4, and .ts files. Includes automatic filtering for already-processed files and supports parallel encoding (default: 2 concurrent jobs). Skips files smaller than 1GB.

**Platform**: Linux/Unix with AMD GPU support

### deinterlace_qsv_x265_aac.ps1
PowerShell script for deinterlacing TV shows using Intel Quick Sync Video (QSV) encoding. Processes .mkv and .ts files with configurable temporary directory for intermediate files. Includes progress tracking and filtering for already-processed content. Supports parallel encoding.

**Platform**: Windows with Intel Quick Sync support
