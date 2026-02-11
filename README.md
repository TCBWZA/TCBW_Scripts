# TCBW Scripts - Video Processing Suite

**USE AT YOUR OWN RISK**

The setting in use work for me. You need to make sure things like bitrate meet your quality requirements. THESE WILL NOT WORK FOR UHD.

**Overview**

A collection of powerful video transcoding and deinterlacing scripts optimized for batch processing of video media. These scripts leverage hardware-accelerated encoding to efficiently convert interlaced video content to modern formats with reduced file sizes.

## Features

- **Hardware-Accelerated Encoding**: Support for both AMD and Intel Quick Sync Video (QSV) encoders
- **Batch Processing**: Parallel encoding with configurable concurrent jobs
- **Smart Format Detection**: Automatically detects interlacing and decides whether conversion is needed
- **Output Format**: x265 (HEVC) video codec with AAC audio
- **Progress Tracking**: Real-time progress monitoring during batch operations (TV Powershell only at this stage.)
- **Multi-Platform**: PowerShell scripts for Windows, shell scripts for Unix-like systems. QSV used in Powershell and VAAPI in bash.
- **Organized Structure**: Separate handling for Movies, TV Shows, and Foreign content (WIP)

## Prerequisites

### Required Software
- **FFmpeg** and **ffprobe** - Video processing and analysis tools
  - Install via [ffmpeg.org](https://ffmpeg.org/download.html)
  - Or use package manager: `choco install ffmpeg` (Windows), `brew install ffmpeg` (macOS), or `apt install ffmpeg` (Linux)

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

**For TV Content** (with AMD):
```powershell
.\Video\TV\deinterlace_amd_x265_aac.ps1
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
```

## Directory Structure

```
TCBW_Scripts/
├── README.md                           # This file
├── LICENSE                             # MIT License
├── Files/                              # Additional file resources
└── Video/                              # Video processing scripts
    ├── Foreign/                        # Foreign language content
    │   ├── deinterlace_amd_x265_aac.sh
    │   └── deinterlace_qsv_x265_aac.ps1
    ├── Movies/                         # Movie content
    │   ├── deinterlace_amd_x265_aac.sh
    │   └── deinterlace_qsv_x265_aac.ps1
    └── TV/                             # TV series content
        ├── deinterlace_amd_x265_aac.sh
        └── deinterlace_qsv_x265_aac.ps1
```

## How It Works

1. **File Scanning**: Recursively scans for `.mkv` and `.ts` files in the script directory
2. **Smart Filtering**: Skips files files smaller than 1GB
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

## Output Naming

- Original files remain untouched
- Temporary conversion files: `filename[Trans].tmp`
- Final encoded files: `filename.mkv`
- Maintains original file date and time

## Configuration Options

Edit the script header to customize:

```powershell
$MaxJobs = 2                    # Number of parallel encoding jobs
$TempDir = "D:\fasttemp"        # Temporary directory for intermediate files
                                # Use "" to keep files in source directory
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
