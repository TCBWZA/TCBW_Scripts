# Requires PowerShell 7+
$ErrorActionPreference = "Stop"

Register-EngineEvent PowerShell.Exiting -Action {
    Write-Host "Interrupted -- exiting safely"
} | Out-Null

Write-Host "Starting up..."
Write-Host "Scanning for files..."

###############################################################
# FUNCTION: FAST interlace / telecine detection
###############################################################
function Get-VideoInterlaceStatus {
    param([string]$Path)

    #
    # FAST PASS — STREAM METADATA ONLY
    #
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_streams -select_streams v "$Path"
        $probe = $probeJson | ConvertFrom-Json
    }
    catch {
        Write-Host "ffprobe failed for $Path"
        return "unknown"
    }

    $stream = $probe.streams | Where-Object { $_.codec_type -eq "video" }

    # Explicit interlace flags (tt, bb, tb, bt) — ALWAYS interlaced
    if ($stream.field_order -and $stream.field_order -match "^(tt|bb|tb|bt)$") {
        return "interlaced"
    }

    # Explicit progressive → DONE (no frame scan)
    if ($stream.field_order -eq "progressive") {
        return "progressive"
    }

    #
    # SLOW PASS — ONLY IF field_order missing or unknown
    # OPTIMIZED: Limit to first 20 frames to reduce analysis time
    #
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_frames -select_streams v -count:frames 20 "$Path"
        $probe = $probeJson | ConvertFrom-Json
    }
    catch {
        return "unknown"
    }

    # Skip first 5 minutes (9000 frames at 30fps) to avoid credits/intros, then check next 20 frames
    $frames = $probe.frames | Select-Object -Skip 9000 -First 20

    if ($frames.interlaced_frame -contains 1) {
        return "interlaced"
    }

    return "progressive"
}

###############################################################
# MAIN PROCESSING
###############################################################

$files = Get-ChildItem -Recurse -File -Include *.mkv, *.mp4, *.ts

Write-Host "Found $($files.Count) files."
Write-Host "Beginning processing..."

foreach ($f in $files) {

    # File size in GB
    $sizeGB = [math]::Floor($f.Length / 1GB)
    if ($sizeGB -lt 1) { continue }

    $basename = $f.BaseName
    $dir = $f.DirectoryName
    $baseNoExt = $basename
    
    # Extract show name (everything before the last space followed by numbers, or up to first number sequence)
    $show_name = ($basename -split '\s+')[0]
    $show_skip_file = Join-Path $dir ".skip_$show_name"
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
    if (Test-Path -LiteralPath $show_skip_file) {
        Write-Host "Skipping $($f.FullName) -- show marked with .skip_$show_name"
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
    $vbitrate = if ($videoStream.bit_rate) { [int]$videoStream.bit_rate } else { 0 }
    $acodec = $audioStream.codec_name

    #####################################################
    # Fast checks first, only detect interlacing if needed
    #####################################################
    $needs_convert = $false
    if ($acodec -ne "aac") { $needs_convert = $true }
    if (-not $needs_convert -and $vcodec -ne "hevc") { $needs_convert = $true }
    if (-not $needs_convert -and $vbitrate -gt 2500000) { $needs_convert = $true }
    
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
    # Build temp output
    #####################################################
    $tmpfile = Join-Path $dir "$baseNoExt`[Trans].tmp"

    if (Test-Path -LiteralPath $tmpfile) { Remove-Item -LiteralPath $tmpfile -Force }

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
            --quality 24 `
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
            --quality 24 `
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
            Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip_$show_name"
            New-Item -Path $show_skip_file -ItemType File -Force | Out-Null
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

Write-Host "Cleaning up leftover [Trans] files..."

Get-ChildItem -Recurse -File |
    Where-Object {
        $_.Name -match '\[Trans\]\.tmp' -or
        $_.Name -match '\[Trans\]\.nfo' -or
        $_.Name -match '\[Trans\]\.jpg'
    } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }

Get-ChildItem -Recurse -Directory |
    Where-Object { $_.Name -match '\[Trans\]\.trickplay' } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }

Write-Host "All tasks complete."
