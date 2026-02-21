# TCBW Scripts

## Project Structure

```
TCBW_Scripts/
├── README.md (this file)
├── LICENSE
├── Linux/
│   └── lxc/
│       └── pve-lxc-upgrade.sh         - Automated LXC container updater for Proxmox
├── Video/
│   ├── Foreign/                        - Compression scripts for foreign language content
│   │   ├── README.md
│   │   ├── compress_amd_x265_aac.sh   - AMD GPU compression (bash)
│   │   ├── compress_qsv_x265_aac.ps1  - Intel QSV compression (PowerShell)
│   │   ├── compressmp4_amd_x265_aac.sh - MP4-specific AMD compression
│   │   └── hbcompress_qsv_x265_aac.ps1 - HandBrake Intel QSV compression
│   ├── Movies/                         - Compression & deduplication scripts for movies
│   │   ├── README.md
│   │   ├── compress_amd_x265_aac.sh   - AMD GPU compression (bash)
│   │   ├── compress_qsv_x265_aac.ps1  - Intel QSV compression (PowerShell)
│   │   ├── clean_compress_amd_x265_aac.sh - AMD GPU w/ metadata handling (bash)
│   │   ├── clean_compress_qsv_x265_aac.ps1 - Intel QSV w/ metadata handling (PowerShell)
│   │   ├── clean_compressUHD_qsv_x265_aac.ps1 - Intel QSV 4K compression (PowerShell)
│   │   └── dedup.ps1                 - Duplicate removal (PowerShell)
│   └── TV/                             - Compression & deduplication scripts for TV shows
│       ├── README.md
│       ├── compress_amd_x265_aac.sh   - AMD GPU compression (bash)
│       ├── compress_qsv_x265_aac.ps1  - Intel QSV compression (PowerShell)
│       ├── hbcompress_qsv_x265_aac.ps1 - HandBrake Intel QSV compression
│       └── dedup.ps1                 - Duplicate episode removal & priority-based selection
└── Files/
    └── (legacy or additional files)
```

## Linux

See [Linux/README.md](Linux/README.md) for detailed descriptions of Linux utilities.

## Video Processing Scripts

**⚠️ USE AT YOUR OWN RISK**

The settings in use work for me. You need to make sure things like bitrate meet your quality requirements. **THESE WILL NOT WORK FOR UHD.** (except `clean_compressUHD_qsv_x265_aac.ps1`)

### Overview

A comprehensive collection of powerful video transcoding, compression, and deduplication scripts optimized for batch processing of video media. These scripts leverage hardware-accelerated encoding to efficiently convert interlaced video content to modern formats with reduced file sizes, and provide intelligent duplicate detection and removal.

### Video Folder Organization

- **[Foreign/](Video/Foreign/README.md)** - Deinterlacing scripts optimized for foreign language content
- **[Movies/](Video/Movies/README.md)** - Deinterlacing scripts optimized for movie content  
- **[TV/](Video/TV/README.md)** - Deinterlacing scripts optimized for TV show content

See each folder's README for detailed file descriptions and usage information.

## Features

### Architecture & Design

**Why Dual Script Implementations?**

This repository maintains both bash (shell) and PowerShell script implementations due to specific hardware and software constraints:

- **Bash Scripts (Linux/Debian)**: Run on a Debian box with an older version of FFmpeg that has a critical bug affecting files with embedded subtitles. When processing such files, the transcoding process runs at extremely low FPS (often single-digit FPS), making transcoding impractical.

- **PowerShell Scripts (Windows)**: Run on a separate machine with current FFmpeg to work around this limitation. The PowerShell implementations handle transcodes that are problematic on the Debian box, achieving normal FPS rates and practical transcoding times.

This dual-machine approach ensures reliable batch processing despite the Debian FFmpeg limitations, while maintaining the cost-efficiency of the Linux environment for compatible files.

### Compression Scripts

- **Hardware-Accelerated Encoding**: Support for both AMD VAAPI and Intel Quick Sync Video (QSV) encoders
- **Batch Processing**: Parallel encoding with configurable concurrent jobs
- **Smart Format Detection**: Automatically detects interlacing and decides whether conversion is needed
- **Optimized Frame Analysis**: Skips first 5 minutes of video (intros/credits) when analyzing for interlacing
- **Output Format**: x265 (HEVC) video codec with AAC audio
- **Metadata Handling**: Optional metadata and sidecar file management
- **Skip Markers**: Support for `.skip` files to mark directories and shows as ineligible for compression

### Deduplication Scripts

- **Intelligent Duplicate Detection**: Matches episodes by S##E## or ##x## patterns
- **Priority-Based Selection**: Keeps MKV > MP4 > TS > AVI when duplicates exist
- **Comprehensive Cleanup**: Removes all associated sidecar files (.nfo, .srt, .jpg, .trickplay, etc.)
- **Audit Mode**: Preview what would be deleted before making changes
- **Directory-Scoped Matching**: Only considers files in the same directory as potential duplicates

### General

- **Multi-Platform**: PowerShell scripts for Windows, shell scripts for Unix-like systems
- **Organized Structure**: Separate handling for Movies, TV Shows, and Foreign content
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

**Compression:**

```powershell
# TV Content - Intel QSV compression
.\Video\TV\compress_qsv_x265_aac.ps1

# Movies - Intel QSV compression
.\Video\Movies\compress_qsv_x265_aac.ps1

# Movies - Intel QSV with 4K support
.\Video\Movies\clean_compressUHD_qsv_x265_aac.ps1

# Foreign - Intel QSV compression
.\Video\Foreign\compress_qsv_x265_aac.ps1
```

**Deduplication:**

```powershell
# TV Content - Audit mode (preview only)
.\Video\TV\dedup.ps1 -Audit

# TV Content - Perform deduplication
.\Video\TV\dedup.ps1

# Movies - Audit mode (preview only)
.\Video\Movies\dedup.ps1 -Audit

# Movies - Perform deduplication
.\Video\Movies\dedup.ps1
```

### Unix-like Systems (Bash)

**Compression:**

```bash
# TV Content - AMD GPU compression
bash ./Video/TV/compress_amd_x265_aac.sh

# Movies - AMD GPU compression
bash ./Video/Movies/compress_amd_x265_aac.sh

# Foreign - AMD GPU compression
bash ./Video/Foreign/compress_amd_x265_aac.sh
```

For detailed usage instructions and script options, see the README files in each folder:

- [Video/TV/](Video/TV/README.md)
- [Video/Movies/](Video/Movies/README.md)
- [Video/Foreign/](Video/Foreign/README.md)

## How It Works

### Compression Scripts

1. **File Scanning**: Recursively scans for `.mkv`, `.mp4`, and `.ts` files in the script directory
2. **Smart Filtering**: Skips files smaller than 1GB and previously processed files (marked [Cleaned] or [Trans])
3. **Format Analysis**: Uses ffprobe to detect:
   - Video codec and bitrate
   - Audio codec
   - Interlacing status (field order)
4. **Conversion Decision**: Only converts files that meet these criteria:
   - Video is not already x265/HEVC
   - Bitrate exceeds 2.5 Mbps
   - Audio is not already AAC
   - Video is interlaced (not progressive)
5. **Interlace Detection**: Two-stage analysis:
   - Quick metadata check first (field_order)
   - Deep frame analysis on actual content (skips first 5 minutes to avoid intros/credits)
6. **Deinterlacing**: Automatically applies appropriate filter based on detection (bwdif for interlaced, fieldmatch+decimate+bwdif for telecine)
7. **Parallel Processing**: Encodes multiple files simultaneously (configurable via `$MaxJobs`)
8. **Output**: Creates new files with quality preservation while reducing file size

### Deduplication Scripts

1. **Pattern Detection**: Scans files for episode codes (S##E##, ##x##, etc.)
2. **Grouping**: Groups potential duplicates by episode code within each directory
3. **Priority Selection**: Applies priority: File Type (MKV > MP4 > TS > AVI) → File Size (largest)
4. **Cleanup**: Removes all sidecar files associated with deleted episodes
5. **Reporting**: Generates detailed summary of actions taken

## Configuration Options

Edit the script header to customize:

**PowerShell Compression Scripts (`compress_qsv_x265_aac.ps1`)**:

```powershell
$MaxJobs = 2                    # Number of parallel encoding jobs
$TempDir = "D:\fasttemp"        # Temporary directory for intermediate files
                                # Use "" to keep files in source directory
```

**Bash Compression Scripts (`compress_amd_x265_aac.sh`)**:

```bash
MAX_JOBS=2                      # Number of parallel encoding jobs
```

**PowerShell Deduplication (`dedup.ps1`)**:

```powershell
# Run with -Audit flag for preview mode
./dedup.ps1 -Audit              # Preview changes without deleting
./dedup.ps1                     # Perform actual deduplication
```

## Encoder Selection

### Intel QSV (Quick Sync Video)

- **Files**: `compress_qsv_x265_aac.ps1`, `hbcompress_qsv_x265_aac.ps1`, `clean_compress_qsv_x265_aac.ps1`, `clean_compressUHD_qsv_x265_aac.ps1`
- **Best For**: Intel processors with integrated graphics
- **Performance**: Excellent power efficiency
- **Compatibility**: Works with most modern Intel CPUs
- **4K Support**: Use `clean_compressUHD_qsv_x265_aac.ps1` for UHD content

### AMD VAAPI

- **Files**: `compress_amd_x265_aac.sh`, `compressmp4_amd_x265_aac.sh`
- **Best For**: AMD GPUs (Radeon RX series)
- **Performance**: High throughput for batch processing
- **Compatibility**: Requires compatible AMD hardware

### HandBrake Integration

- **Files**: `hbcompress_qsv_x265_aac.ps1` (Windows with Intel QSV)
- **Best For**: HandBrake encoding workflows
- **Features**: Specialized handling for HandBrake CLI integration

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
**Last Updated**: February 2026  
**Version**: 2.0
