# Requires PowerShell 7+
$ErrorActionPreference = "Stop"

Register-EngineEvent PowerShell.Exiting -Action {
    Write-Host "Interrupted -- exiting safely"
}

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
    #
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_frames -select_streams v "$Path"
        $probe = $probeJson | ConvertFrom-Json
    }
    catch {
        return "unknown"
    }

    $frames = $probe.frames | Select-Object -First 200

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
    if ($sizeGB -lt 0) { continue }

    $basename = $f.BaseName
    $dir = $f.DirectoryName
    $baseNoExt = $basename

    # Skip and delete cleaned/transcoded files
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Remove-Item -LiteralPath $f.FullName -Force
        continue
    }

    Write-Host "`nChecking $($f.FullName)"

    #####################################################
    # ffprobe JSON (streams only)
    #####################################################
    $probeJson = ffprobe -v quiet -print_format json -show_streams $f.FullName
    $probe = $probeJson | ConvertFrom-Json

    $videoStream = $probe.streams | Where-Object { $_.codec_type -eq "video" }
    $audioStream = $probe.streams | Where-Object { $_.codec_type -eq "audio" }

    $vcodec = $videoStream.codec_name
    $vbitrate = [int]$videoStream.bit_rate
    $acodec = $audioStream.codec_name

    #####################################################
    # Detect interlacing BEFORE deciding conversion
    #####################################################
    $status = Get-VideoInterlaceStatus $f.FullName

    $needs_convert = $false
    if ($vcodec -ne "hevc") { $needs_convert = $true }
    if ($vbitrate -gt 2500000) { $needs_convert = $true }
    if ($acodec -ne "aac") { $needs_convert = $true }

    # Telecine or interlaced ALWAYS requires conversion
    if ($status -ne "progressive") { $needs_convert = $true }

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
    $tmpfile = Join-Path $dir "$baseNoExt`[Trans].mkv"

    if (Test-Path $tmpfile) { Remove-Item $tmpfile -Force }

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

    if ($exit -eq 0 -and (Test-Path $tmpfile)) {
        $orig = Get-Item -LiteralPath $f.FullName
        Set-ItemProperty -LiteralPath $tmpfile -Name LastWriteTime -Value $orig.LastWriteTime

        Remove-Item -LiteralPath $f.FullName -Force
        Move-Item -LiteralPath $tmpfile -Destination $f.FullName -Force
    }
    else {
        Write-Host "HandBrake failed or temp file missing. Exit code: $exit"
        if (Test-Path $tmpfile) { Remove-Item $tmpfile -Force }
        continue
    }
}

#####################################################
# Cleanup section
#####################################################

Write-Host "Cleaning up leftover [Trans] files..."

Get-ChildItem -Recurse -File |
    Where-Object {
        $_.Name -match '\[Trans\]\.mkv' -or
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
