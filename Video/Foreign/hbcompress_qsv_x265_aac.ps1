# Requires PowerShell 7+

$ErrorActionPreference = "Stop"

###############################################################
# PRE-FLIGHT CHECKS
###############################################################
$requiredTools = @('HandBrakeCLI', 'ffprobe', 'ffmpeg')
foreach ($tool in $requiredTools) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: $tool not found in PATH" -ForegroundColor Red
        Write-Host "Please install or add to PATH before running this script."
        exit 1
    }
}

###############################################################
# CLEANUP TRAP FOR INTERRUPTION
###############################################################
$tempFilesToCleanup = @()
$cleanupTrap = {
    if ($tempFilesToCleanup.Count -gt 0) {
        Write-Host "Cleaning up temp files due to interruption..."
        foreach ($file in $tempFilesToCleanup) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Write-Host "Interrupted -- exiting safely"
}
Register-EngineEvent PowerShell.Exiting -Action $cleanupTrap | Out-Null

Write-Host "Starting up..."
Write-Host "Scanning for files..."

###############################################################
# CONFIGURABLE THRESHOLDS
###############################################################
$HandBrakeQuality = 24            # Video quality (18-28)
$MinBitrate = 2500000            # Bitrate threshold (bps) - skip if > this
$MinFileSize = 1                  # Minimum file size (GB)
$MinDiskSpace = 50                # Minimum free disk space (GB)

# Optional temp directory for intermediate files (use "" to keep alongside source)
$TempDir = ""   # or "D:\fasttemp" for HandBrake temp outputs

###############################################################
# FUNCTION: FAST interlace / telecine detection
###############################################################
function Get-VideoInterlaceStatus {
    param([string]$Path)

    $probeJson = ffprobe -v quiet -print_format json -show_streams -select_streams v "$Path"
    $probe = $probeJson | ConvertFrom-Json

    $stream = $probe.streams | Where-Object { $_.codec_type -eq "video" }

    if ($stream.field_order -and $stream.field_order -match "^(tt|bb|tb|bt)$") {
        return "interlaced"
    }

    if ($stream.field_order -eq "progressive") {
        return "progressive"
    }

    $probeJson = ffprobe -v quiet -print_format json -show_frames -select_streams v -count:frames 20 "$Path"
    $probe = $probeJson | ConvertFrom-Json

    $frames = $probe.frames | Select-Object -Skip 9000 -First 20

    if ($frames.interlaced_frame -contains 1) {
        return "interlaced"
    }

    return "progressive"
}

# Find all video files
$files = Get-ChildItem -Recurse -File -Include *.mkv, *.mp4, *.ts

Write-Host "Found $($files.Count) files."
Write-Host "Beginning processing..."

foreach ($f in $files) {

    # File size in GB
    $sizeGB = [math]::Floor($f.Length / 1GB)
    if ($sizeGB -lt $MinFileSize) { continue }

    $basename = $f.BaseName
    $dir = $f.DirectoryName
    $baseNoExt = $basename

    $episode_skip_file = Join-Path $dir ".skip_$baseNoExt"
    $parent_skip_file = Join-Path (Split-Path $dir) ".skip"

    # Skip and delete cleaned/transcoded files
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Remove-Item -LiteralPath $f.FullName -Force
        continue
    }

    # Check for skip markers
    if (Test-Path -LiteralPath $parent_skip_file) {
        Write-Host "Skipping $($f.FullName) -- parent directory marked with .skip"
        continue
    }
    if (Test-Path -LiteralPath $episode_skip_file) {
        Write-Host "Skipping $($f.FullName) -- episode marked with .skip_$baseNoExt"
        continue
    }

    Write-Host "`nChecking $($f.FullName)"

    #####################################################
    # ffprobe JSON (streams only)
    #####################################################
    $probeJson = ffprobe -v quiet -print_format json -show_streams $f.FullName
    $probe = $probeJson | ConvertFrom-Json

    $videoStream = $probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $audioStream = $probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $vcodec = $videoStream.codec_name
    $vbitrate = if ($videoStream.bit_rate) { [int]($videoStream.bit_rate[0]) } else { 0 }
    $acodec = $audioStream.codec_name

    # Skip AV1 files entirely
    if ($vcodec -eq "av1") {
        Write-Host "Skipping $($f.FullName) -- AV1 detected"
        continue
    }

    #####################################################
    # Fast checks first, only detect interlacing if needed
    #####################################################
    $needs_convert = $false
    if ($acodec -ne "aac") { $needs_convert = $true }
    if (-not $needs_convert -and $vcodec -ne "hevc") { $needs_convert = $true }
    if (-not $needs_convert -and $vbitrate -gt $MinBitrate) { $needs_convert = $true }
    
    # Only run expensive interlace detection if other checks pass
    $status = $null
    if (-not $needs_convert) {
        $status = Get-VideoInterlaceStatus $f.FullName
        # Telecine or interlaced ALWAYS requires conversion
        if ($status -ne "progressive") { $needs_convert = $true }
    }
    else {
        # If we already need to convert, we still need status for filter choice
        $status = Get-VideoInterlaceStatus $f.FullName
    }

    if (-not $needs_convert) {
        Write-Host "Skipping $($f.FullName) -- already in desired format"
        continue
    }

    #####################################################
    # Choose filter (VALID HANDBRAKE OPTIONS)
    #####################################################
    switch ($status) {
        "interlaced" {
            $hb_filter = "--deinterlace=slower"
            Write-Host "Detected: TRUE INTERLACE → Applying deinterlace=slower"
        }
        "progressive" {
            $hb_filter = ""
            Write-Host "Detected: PROGRESSIVE → No deinterlace"
        }
        "unknown" {
            $hb_filter = "--detelecine --deinterlace=slower"
            Write-Host "Detected: UNKNOWN / TELECINE → Applying detelecine + deinterlace=slower"
        }
    }

    #####################################################
    # Check disk space before processing
    #####################################################
    if ([string]::IsNullOrWhiteSpace($TempDir)) {
        $checkDir = $dir
    } else {
        $checkDir = $TempDir
    }
    $drive = $checkDir -replace '(^[a-zA-Z]).*', '$1'
    $diskInfo = Get-PSDrive -Name $drive[0]
    $freespaceGB = [math]::Floor($diskInfo.Free / 1GB)
    
    if ($freespaceGB -lt $MinDiskSpace) {
        Write-Host "Skipping $($f.FullName) -- insufficient disk space (${freespaceGB}GB free, need ${MinDiskSpace}GB)" -ForegroundColor Yellow
        continue
    }

    #####################################################
    # Build temp output
    #####################################################
    $tmpfile = Join-Path $dir "$baseNoExt`[Trans].tmp"

    if (Test-Path -LiteralPath $tmpfile) { Remove-Item -LiteralPath $tmpfile -Force }
    $tempFilesToCleanup += $tmpfile

    Write-Host "Input    : $($f.FullName)"
    Write-Host "Temp Out : $tmpfile"
    Write-Host "Filters  : $hb_filter"

    #####################################################
    # RUN HANDBRAKE DIRECTLY (FULL OUTPUT)
    #####################################################

    if ($hb_filter -eq "") {
        HandBrakeCLI `
            --input "$($f.FullName)" `
            --output "$tmpfile" `
            --format mkv `
            --encoder qsv_h265 `
            --encoder-preset balanced `
            --quality $HandBrakeQuality `
            --maxHeight 2160 `
            --aencoder av_aac `
            --ab 160 `
            --mixdown stereo `
            --subtitle copy
    }
    else {
        HandBrakeCLI `
            --input "$($f.FullName)" `
            --output "$tmpfile" `
            --format mkv `
            --encoder qsv_h265 `
            --encoder-preset balanced `
            --quality $HandBrakeQuality `
            --maxHeight 2160 `
            --aencoder av_aac `
            --ab 160 `
            --mixdown stereo `
            --subtitle copy `
            $hb_filter
    }

    $exit = $LASTEXITCODE

    #####################################################
    # SAFE EXIT HANDLING
    #####################################################

    if ($exit -eq 0 -and (Test-Path -LiteralPath $tmpfile)) {
        $orig = Get-Item -LiteralPath $f.FullName
        $origSize = $orig.Length
        $newSize = (Get-Item -LiteralPath $tmpfile).Length
        
        if ($newSize -lt $origSize) {
            Set-ItemProperty -Path $tmpfile -Name LastWriteTime -Value $orig.LastWriteTime
            Remove-Item -LiteralPath $f.FullName -Force
            Move-Item -LiteralPath $tmpfile -Destination $f.FullName -Force
            $origMB = [math]::Round($origSize / 1MB, 2)
            $newMB = [math]::Round($newSize / 1MB, 2)
            Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
        }
        else {
            $origMB = [math]::Round($origSize / 1MB, 2)
            $newMB = [math]::Round($newSize / 1MB, 2)
            Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip_$baseNoExt"
            New-Item -Path $episode_skip_file -ItemType File -Force | Out-Null
            Remove-Item -LiteralPath $tmpfile -Force
        }
    }
    else {
        Write-Host "HandBrake failed or temp file missing. Exit code: $exit"
        if (Test-Path -LiteralPath $tmpfile) { Remove-Item -LiteralPath $tmpfile -Force }
        continue
    }
}

#####################################################
# Cleanup section
#####################################################

Write-Host "Cleaning up all [Trans] files and directories..."

Get-ChildItem -Recurse -Include "*[Trans].*" -Force |
    Remove-Item -Force -ErrorAction SilentlyContinue

Get-ChildItem -Recurse -Directory -Include "*[Trans].trickplay" |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "All tasks complete."