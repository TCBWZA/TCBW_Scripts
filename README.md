# TCBW Scripts - Video Processing Suite

## Project Structure

```
TCBW_Scripts/
├── README.md (this file)
├── LICENSE
├── Linux/
│   └── lxc/
│       └── pve-lxc-upgrade.sh         - Automated LXC container updater for Proxmox
├── Video/
│   ├── Foreign/                        - Deinterlacing scripts for foreign language content
│   │   ├── README.md
│   │   ├── deinterlace_amd_x265_aac.sh - AMD GPU deinterlacing (bash)
│   │   ├── deinterlace_qsv_x265_aac.ps1 - Intel QSV deinterlacing (PowerShell)
│   │   ├── deinterlacemp4_amd_x265_aac.sh - MP4-specific AMD deinterlacing
│   │   └── hbdeintvappi.sh            - Alternative AMD VAAPI deinterlacing
│   ├── Movies/                         - Deinterlacing scripts for movies
│   │   ├── README.md
│   │   ├── deinterlace_amd_x265_aac.sh - AMD GPU deinterlacing (bash)
│   │   └── deinterlace_qsv_x265_aac.ps1 - Intel QSV deinterlacing (PowerShell)
│   └── TV/                             - Deinterlacing scripts for TV shows
│       ├── README.md
│       ├── deinterlace_amd_x265_aac.sh - AMD GPU deinterlacing (bash)
│       └── deinterlace_qsv_x265_aac.ps1 - Intel QSV deinterlacing (PowerShell)
└── Files/
    └── (legacy or additional files)
```

## Linux

See [Linux/README.md](Linux/README.md) for detailed descriptions of Linux utilities.

## Video Processing Scripts

**⚠️ USE AT YOUR OWN RISK**

The settings in use work for me. You need to make sure things like bitrate meet your quality requirements. **THESE WILL NOT WORK FOR UHD.**

### Overview

A collection of powerful video transcoding and deinterlacing scripts optimized for batch processing of video media. These scripts leverage hardware-accelerated encoding to efficiently convert interlaced video content to modern formats with reduced file sizes.

### Video Folder Organization

- **[Foreign/](Video/Foreign/README.md)** - Deinterlacing scripts optimized for foreign language content
- **[Movies/](Video/Movies/README.md)** - Deinterlacing scripts optimized for movie content  
- **[TV/](Video/TV/README.md)** - Deinterlacing scripts optimized for TV show content

See each folder's README for detailed file descriptions and usage information.

## Features

- **Hardware-Accelerated Encoding**: Support for both AMD and Intel Quick Sync Video (QSV) encoders
- **Batch Processing**: Parallel encoding with configurable concurrent jobs
- **Smart Format Detection**: Automatically detects interlacing and decides whether conversion is needed
- **Output Format**: x265 (HEVC) video codec with AAC audio
- **Progress Tracking**: Real-time progress monitoring during batch operations (TV Powershell only at this stage.)
- **Multi-Platform**: PowerShell scripts for Windows, shell scripts for Unix-like systems. QSV used in Powershell and VAAPI in bash.
- **Organized Structure**: Separate handling for Movies, TV Shows, and Foreign content

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
   git clone https://github.com/yourusername/TCBW_Scripts.git
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
   - `$MaxJobs`: Number of concurrent encoding jobs (default: 2)
   - `$TempDir`: Directory for temporary files (default: "D:\fasttemp")

## Usage

### Windows (PowerShell)

**For TV Content** (with Intel QSV):
```powershell
.\Video\TV\deinterlace_qsv_x265_aac.ps1
```

**For Movies** (with Intel QSV):
```powershell
.\Video\Movies\deinterlace_qsv_x265_aac.ps1
```

**For Foreign Content** (with Intel QSV):
```powershell
.\Video\Foreign\deinterlace_qsv_x265_aac.ps1
```

### Unix-like Systems (Bash)

**For TV Content**:
```bash
bash ./Video/TV/deinterlace_amd_x265_aac.sh
```

**For Movies**:
```bash
bash ./Video/Movies/deinterlace_amd_x265_aac.sh
```

**For Foreign Content**:
```bash
bash ./Video/Foreign/deinterlace_amd_x265_aac.sh
# or for MP4-specific:
bash ./Video/Foreign/deinterlacemp4_amd_x265_aac.sh
```

For detailed usage instructions and script options, see the README files in each folder:
- [Video/TV/](Video/TV/README.md)
- [Video/Movies/](Video/Movies/README.md)
- [Video/Foreign/](Video/Foreign/README.md)

## Directory Structure

## How It Works

1. **File Scanning**: Recursively scans for `.mkv` and `.ts` files in the script directory
2. **Smart Filtering**: Skips files smaller than 1GB
3. **Format Analysis**: Uses ffprobe to detect:
   - Video codec and bitrate
   - Audio codec
   - Interlacing status (field order)
4. **Conversion Decision**: Only converts files that meet these criteria:
   - Video is not already x265/HEVC
   - Bitrate exceeds 2.5 Mbps
   - Audio is not already AAC
   - Video is interlaced (not progressive)
5. **Deinterlacing**: Uses FFmpeg's `idet` filter to automatically detect and apply appropriate deinterlacing
6. **Parallel Processing**: Encodes multiple files simultaneously (configurable via `$MaxJobs`)
7. **Output**: Creates new files with quality preservation while reducing file size

## Configuration Options

Edit the script header to customize:

**PowerShell (`deinterlace_qsv_x265_aac.ps1`)**:
```powershell
$MaxJobs = 2                    # Number of parallel encoding jobs
$TempDir = "D:\fasttemp"        # Temporary directory for intermediate files
                                # Use "" to keep files in source directory
```

**Bash (`deinterlace_amd_x265_aac.sh`)**:
```bash
MAX_JOBS=2                      # Number of parallel encoding jobs
```

## Encoder Selection

### Intel QSV (Quick Sync Video)
- **File**: `deinterlace_qsv_x265_aac.ps1` or `deinterlace_qsv_x265_aac.sh`
- **Best For**: Intel processors with integrated graphics
- **Performance**: Excellent power efficiency
- **Compatibility**: Works with most modern Intel CPUs

### AMD
- **File**: `deinterlace_amd_x265_aac.sh`
- **Best For**: AMD GPUs (Radeon RX series)
- **Performance**: High throughput for batch processing
- **Compatibility**: Requires compatible AMD hardware

## Performance Tips

1. **Adjust $MaxJobs**: Start with 2-3 concurrent jobs; increase on powerful systems with more VRAM
2. **Use Fast SSD**: Place `$TempDir` on the fastest available drive
3. **Monitor Temperature**: GPU encoding generates heat; ensure proper cooling
4. **Schedule Off-Peak**: Run during off-peak hours to avoid system impact
5. **Test First**: Run on a small subset of files to verify output quality

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "ffmpeg not found" | Ensure FFmpeg is installed and in your PATH |
| Slow encoding | Reduce `$MaxJobs` or check GPU utilization |
| Poor output quality | Verify input file format; try with different encoder |
| Out of disk space | Increase `$TempDir` capacity or reduce `$MaxJobs` |
| GPU not being used | Verify hardware encoder support; check FFmpeg codecs with `ffmpeg -codecs` |

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
**Last Updated**: 2026  
**Version**: 1.0
