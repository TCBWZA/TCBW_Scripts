# Foreign Content Video Scripts

Deinterlacing and transcoding scripts optimized for foreign language content. These scripts convert interlaced video to x265 (HEVC) format with AAC audio.

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
Bash script for deinterlacing video files using AMD GPU hardware acceleration (VAAPI). Processes .mkv, .mp4, and .ts files. Includes automatic filtering for already-processed files and supports parallel encoding (default: 2 concurrent jobs). Skips files smaller than 1GB.

**Platform**: Linux/Unix with AMD GPU support

### deinterlace_qsv_x265_aac.ps1
PowerShell script for deinterlacing using Intel Quick Sync Video (QSV) encoding. Processes .mkv and .ts files with configurable temporary directory for intermediate files. Includes progress tracking and filtering for already-processed content. Supports parallel encoding.

**Platform**: Windows with Intel Quick Sync support

### deinterlacemp4_amd_x265_aac.sh
Bash script specialized for MP4 file deinterlacing with AMD GPU acceleration. Handles MP4 container format conversion and includes automatic cleanup of previously processed files (marked with [Cleaned] or [Trans]). Optimized for batch MP4 processing.

**Platform**: Linux/Unix with AMD GPU support

### hbdeintvappi.sh
Alternative bash-based deinterlacing script using VAAPI for AMD GPUs. Processes multiple video formats with parallel job support. Another variant for AMD GPU deinterlacing workflows.

**Platform**: Linux/Unix with AMD GPU support
