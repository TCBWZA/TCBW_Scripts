<#
.SYNOPSIS
    Transcodes TV episode video files to HEVC/AAC using HandBrake with AMD VCE hardware encoding.

.DESCRIPTION
    Recursively scans the current directory for MKV, MP4, and TS files over 1 GB and
    transcodes them to HEVC (H.265) video with AAC audio using HandBrakeCLI and the
    AMD VCE (vce_h265) hardware encoder. Files already in the desired format are skipped.

    Features:
    - Debug mode with timestamped output
    - MKV container health check with automatic remux repair path
    - File lock detection before and after encode/move
    - Atomic replacement with size validation
    - Deferred interlace detection (runs only when needed)
    - 4K, AV1, no-video-stream, and no-audio-stream guards
    - Recursive .skip directory marker support
    - Per-file .skip_<basename> marker support
    - English/undefined subtitle stream filtering

.PARAMETER Debug
    Enables verbose debug output with timestamps.

.EXAMPLE
    PS> .\hbcompress_amd_x265_aac.ps1

.EXAMPLE
    PS> .\hbcompress_amd_x265_aac.ps1 -Debug

.NOTES
    - Requires PowerShell 7+, HandBrakeCLI, ffprobe, and ffmpeg on PATH.
    - AMD VCE hardware encoding must be available on the system.
    - Run from the root directory containing your TV show folders.
    - Place a .skip file in any directory to exclude it and all subdirectories.
    - Place a .skip_<basename> file alongside a video to exclude that file.
#>
# Requires PowerShell 7+
param(
    [Alias("d")]
    [switch]$Debug
)

$ErrorActionPreference = "Stop"
$DebugMode = $Debug.IsPresent

function Debug {
    param([string]$Message)
    if ($DebugMode) {
        $ts = (Get-Date).ToString("HH:mm:ss.fff")
        Write-Host "[DEBUG $ts] $Message" -ForegroundColor DarkGray
    }
}

Register-EngineEvent PowerShell.Exiting -Action {
    Write-Host "Interrupted -- exiting safely"
}

###############################################################
# MKV CONTAINER HEALTH CHECK
###############################################################
function Test-MKVContainerProblem {
    param([string]$Path)

    Debug "Checking MKV container health: $Path"

    try {
        $probeJson = ffprobe -v quiet -print_format json -show_format -show_streams "$Path"
        $probe = $probeJson | ConvertFrom-Json
    }
    catch {
        Debug "ffprobe failed during container check"
        return $true   # treat as problematic
    }

    # Timestamp issues
    if ($probe.format.start_time -eq "N/A") {
        Debug "Container issue: start_time is N/A"
        return $true
    }

    # Corrupt duration
    if ($probe.format.duration -eq "N/A") {
        Debug "Container issue: duration is N/A"
        return $true
    }
    if ($probe.format.duration -match '^-?[\d.]+$' -and [double]$probe.format.duration -le 0) {
        Debug "Container issue: duration is non-positive ($($probe.format.duration))"
        return $true
    }

    # Deeper check: demux pass catches non-monotonic timestamps, truncation, missing moov
    $ffmpegErrors = & ffmpeg -nostdin -hide_banner -v error -i $Path -f null - 2>&1
    if ($ffmpegErrors) {
        Debug "Container issue: ffmpeg demux errors detected"
        return $true
    }

    return $false
}


###############################################################
# FILE LOCK DETECTION
###############################################################
function Test-FileLocked {
    param([string]$Path)

    Debug "Checking file lock: $Path"

    try {
        $fs = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $fs.Close()
        return $false
    }
    catch [System.IO.IOException] {
        Debug "File is locked: $Path"
        return $true
    }
    catch {
        Debug "Unexpected lock-check exception: $($_.Exception.Message)"
        return $true
    }
}

###############################################################
# ATOMIC REPLACEMENT
###############################################################
function Invoke-AtomicReplace {
    param(
        [int]$ExitCode,
        [string]$TmpFile,
        [string]$OrigFile,
        [string]$SkipFile,
        [bool]$SkipSizeCheck = $false
    )

    Debug "AtomicReplace called: exit=$ExitCode tmp=$TmpFile orig=$OrigFile"

    if ($ExitCode -ne 0) {
        Write-Host "Transcode/remux failed. Exit code: $ExitCode"
        Debug "Exit code non-zero, aborting replacement"
        if (Test-Path -LiteralPath $TmpFile) {
            Remove-Item -LiteralPath $TmpFile -Force
        }
        return
    }

    if (-not (Test-Path -LiteralPath $TmpFile)) {
        Write-Host "Temp file missing, cannot replace."
        Debug "Temp file missing"
        return
    }

    # Ensure temp path is a file, not a directory
    try {
        $tmpItem = Get-Item -LiteralPath $TmpFile
    }
    catch {
        Write-Host "ERROR: Unable to stat temp file: $TmpFile"
        Debug "Get-Item failed for tmpfile: $($_.Exception.Message)"
        return
    }

    if ($tmpItem.PSIsContainer) {
        Write-Host "ERROR: Temp output path is a directory → $TmpFile"
        Debug "Temp path is directory"
        return
    }

    # Lock check on temp file
    if (Test-FileLocked -Path $TmpFile) {
        Write-Host "Temp file locked → $TmpFile"
        Debug "Temp file locked inside AtomicReplace"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    try {
        $orig = Get-Item -LiteralPath $OrigFile
    }
    catch {
        Write-Host "ERROR: Unable to stat original file: $OrigFile"
        Debug "Get-Item failed for orig: $($_.Exception.Message)"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    $origSize = $orig.Length
    $newSize  = $tmpItem.Length

    $origMB = [math]::Round($origSize / 1MB, 2)
    $newMB  = [math]::Round($newSize  / 1MB, 2)

    Debug "Original size: $origMB MB"
    Debug "New size: $newMB MB"

    try {
        if ($newSize -le 0) {
            Write-Host "ERROR: Temp file is zero‑length. Deleting it."
            Debug "Temp file zero-length"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        if (-not $SkipSizeCheck) {
            if ($newSize -ge $origSize) {
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB)"
                Debug "New file not smaller, marking skip"
                New-Item -Path $SkipFile -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $TmpFile -Force
                return
            }
        }

        if (Test-FileLocked -Path $OrigFile) {
            Write-Host "File is locked → $OrigFile"
            Debug "Original file locked"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        # Apply original timestamp to temp file
        try {
            Set-ItemProperty -LiteralPath $TmpFile -Name LastWriteTime -Value $orig.LastWriteTime
        }
        catch {
            Debug "Failed to set LastWriteTime on tmpfile: $($_.Exception.Message)"
            # Not fatal; continue
        }

        # Final lock check before deletion
        if (Test-FileLocked -Path $OrigFile) {
            Write-Host "Original file locked during commit → $OrigFile"
            Debug "Original locked at final commit"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        Write-Host "Removing original → $OrigFile"
        Debug "Removing original"
        Remove-Item -LiteralPath $OrigFile -Force

        # Final lock check before move
        if (Test-FileLocked -Path $TmpFile) {
            Write-Host "Temp file locked during final move → $TmpFile"
            Debug "Temp locked at final move"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        Write-Host "Committing new file → $OrigFile"
        Debug "Moving temp file into place"
        Move-Item -LiteralPath $TmpFile -Destination $OrigFile -Force

        Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
        Debug "Atomic replacement complete"
    }
    catch {
        Write-Host "ERROR during replacement: $($_.Exception.Message)"
        Debug "AtomicReplace exception: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $TmpFile) {
            Remove-Item -LiteralPath $TmpFile -Force
        }
    }
}

###############################################################
# INTERLACE / TELECINE DETECTION (IMPROVED)
###############################################################
function Get-VideoInterlaceStatus {
    param([string]$Path)

    Debug "Interlace check (fast pass) for: $Path"

    try {
        $probeJson = ffprobe -v quiet -print_format json -show_streams -select_streams v "$Path"
        $probe = $probeJson | ConvertFrom-Json
    }
    catch {
        Debug "Interlace fast pass failed"
        return "unknown"
    }

    $stream = $probe.streams | Where-Object { $_.codec_type -eq "video" }

    if ($stream.field_order -and $stream.field_order -match "^(tt|bb|tb|bt)$") {
        Debug "Interlace fast pass: TRUE interlaced"
        return "interlaced"
    }

    if ($stream.field_order -eq "progressive") {
        Debug "Interlace fast pass: progressive"
        return "progressive"
    }

    Debug "Interlace fast pass inconclusive, running slow pass..."

    try {
        $probeJson = ffprobe `
            -v quiet `
            -print_format json `
            -show_frames `
            -select_streams v `
            -read_intervals "300%+200" `
            "$Path"

        $probe = $probeJson | ConvertFrom-Json
    }
    catch {
        Debug "Interlace slow pass failed"
        return "unknown"
    }

    $frames = $probe.frames

    if ($frames.interlaced_frame -contains 1) {
        Debug "Interlace slow pass: TRUE interlaced"
        return "interlaced"
    }

    Debug "Interlace slow pass: progressive"
    return "progressive"
}

###############################################################
# STARTUP
###############################################################
Write-Host "Starting up..."
Write-Host "Scanning for files..."
Debug "Debug mode ENABLED"

$root = (Get-Location).ProviderPath
Debug "Root directory: $root"

$files = [System.IO.Directory]::EnumerateFiles(
    $root,
    "*.*",
    [System.IO.SearchOption]::AllDirectories
) | Where-Object {
    $_ -match '\.(mkv|mp4|ts)$'
} | ForEach-Object {
    Get-Item -LiteralPath $_
}

Write-Host "Found $($files.Count) files."
Debug "Enumerated $($files.Count) media files"

Write-Host "Beginning processing..."

###############################################################
# MAIN LOOP
###############################################################
foreach ($f in $files) {

    Debug "---------------------------------------------"
    Debug "Processing file: $($f.FullName)"

    Write-Host "$([char]0x1B)]0;$($f.Name)`a"

    # SKIP: SIZE < 1GB
    if ($f.Length -lt 1GB) {
        Debug "Skipping (size < 1GB): $($f.Length)"
        continue
    }

    $baseNoExt = $f.BaseName
    $dir       = $f.DirectoryName

    Debug "Base name: $baseNoExt"
    Debug "Directory: $dir"

    # SKIP: DIRECTORY .skip (walk upward)
    $cur     = $f.Directory
    $skipDir = $false

    while ($null -ne $cur -and $cur.FullName -ne $root) {
        $skipFile = Join-Path $cur.FullName ".skip"
        if (Test-Path -LiteralPath $skipFile) {
            Write-Host "Skipping $($f.FullName) -- .skip found in $($cur.FullName)"
            Debug "Directory skip triggered by: $skipFile"
            $skipDir = $true
            break
        }
        $cur = $cur.Parent
    }

    if ($skipDir) { continue }

    # SKIP: PER-FILE .skip_<basename>
    $fileSkip = Join-Path $dir ".skip_$baseNoExt"

    if (Test-Path -LiteralPath $fileSkip) {
        Write-Host "Skipping $($f.FullName) -- file marked with $(Split-Path $fileSkip -Leaf)"
        Debug "Per-file skip triggered: $fileSkip"
        continue
    }

    # SKIP: 2160p or higher resolution (filename match)
    if ($baseNoExt -imatch '2160[pP]\]') {
        Write-Host "Skipping $($f.FullName) -- 4K (or higher) video match (filename)"
        Debug "4K (or higher) video match (filename)"
        continue
    }

    # SKIP: Already processed
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Debug "Already processed marker found, deleting original"
        Remove-Item -LiteralPath $f.FullName -Force
        continue
    }

    Write-Host "`nChecking $($f.FullName)"
    Debug "Running ffprobe..."

    # ffprobe JSON (streams only)
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_streams $f.FullName
        $probe     = $probeJson | ConvertFrom-Json
        Debug "ffprobe succeeded"
    }
    catch {
        Write-Host "Skipping $($f.FullName) -- ffprobe JSON invalid"
        Debug "ffprobe failed"
        continue
    }

    $videoStream = ($probe.streams | Where-Object { $_.codec_type -eq "video" })[0]

    if (-not $videoStream) {
        Write-Host "Skipping $($f.FullName) -- no video stream found"
        Debug "No video stream found"
        continue
    }

    $width  = $videoStream.width
    $height = $videoStream.height

    Debug "Video codec: $($videoStream.codec_name)"
    Debug "Video bitrate: $($videoStream.bit_rate)"
    Debug "Resolution: ${width}x${height}"

    # SKIP: high resolution (> 1100p) -- ffprobe secondary check, supplements filename check
    if ($height -gt 1100) {
        Write-Host "Skipping $($f.FullName) -- high-resolution video detected (height=$height)"
        Debug "High-resolution (> 1100p) detected, skipping file"
        continue
    }

    # AUDIO STREAMS
    $audioStreams = $probe.streams | Where-Object { $_.codec_type -eq "audio" }

    if ($audioStreams.Count -eq 0) {
        Write-Host "Skipping $($f.FullName) -- no audio detected"
        Debug "No audio streams found"
        continue
    }

    $audioCodecs = $audioStreams.codec_name
    Debug "Audio codecs: $($audioCodecs -join ', ')"

    $hasAAC = $audioCodecs -contains "aac"
    Debug "Has AAC: $hasAAC"

    $vcodec   = $videoStream.codec_name
    $vbitrate = [int]($videoStream.bit_rate ?? 0)

    ###############################################################
    # Skip AV1
    ###############################################################
    if ($vcodec -eq "av1") {
        Write-Host "Skipping $($f.FullName) -- AV1 video detected"
        Debug "Skipping due to AV1 codec"
        continue
    }


    # Check non-interlace conversion criteria first
    $needs_convert = $false
    if ($vcodec -ne "hevc") { $needs_convert = $true }
    if ($vbitrate -gt 2500000) { $needs_convert = $true }
    if (-not $hasAAC) { $needs_convert = $true }
    Debug "Needs convert (pre-interlace): $needs_convert"

    ###############################################################
    # INTERLACE DETECTION
    ###############################################################
    if ($vcodec -eq "hevc") {

        # If ffprobe reports progressive, trust it
        if ($videoStream.field_order -eq "progressive") {
            Debug "HEVC flagged progressive → skipping interlace detection"
            $status = "progressive"
        }
        # If ffprobe reports known interlace patterns, treat as interlaced
        elseif ($videoStream.field_order -match "^(tt|bb|tb|bt)$") {
            Debug "HEVC flagged interlaced → running full detection"
            $status = Get-VideoInterlaceStatus $f.FullName
        }
        # If field_order is missing or weird, run slow detection
        else {
            Debug "HEVC field_order unknown → running slow interlace/telecine detection"
            $status = Get-VideoInterlaceStatus $f.FullName
        }
    }
    else {
        # Non-HEVC → always run full detection
        $status = Get-VideoInterlaceStatus $f.FullName
    }
    Debug "Interlace status: $status"

    if ($status -ne "progressive") { $needs_convert = $true }
    Debug "Needs convert: $needs_convert"

    ###############################################################
    # REMUX LOGIC
    ###############################################################
    $canRemux = $false

    # Only MKV is eligible for container-repair remux
    if ($f.Extension -ieq ".mkv") {

        # Only remux if transcoding is NOT needed
        if (-not $needs_convert) {

            # Only remux if MKV container is problematic
            if (Test-MKVContainerProblem -Path $f.FullName) {
                $canRemux = $true
            }
        }
    }

    if ($canRemux) {
        Write-Host "Remuxing $($f.FullName) → container repair"
        Debug "Container-repair remux triggered"

        $tmpfile = Join-Path $dir ($baseNoExt + '[Trans].tmp')

        if (Test-Path -LiteralPath $tmpfile) {
            Debug "Removing existing temp file"
            Remove-Item -LiteralPath $tmpfile -Force
        }

        if (Test-FileLocked -Path $f.FullName) {
            Write-Host "Skipping $($f.FullName) -- file is locked"
            Debug "File locked before remux"
            continue
        }

        ffmpeg -y -i "$($f.FullName)" -c copy -f matroska "$tmpfile"
        $exit = $LASTEXITCODE
        Debug "ffmpeg remux exit code: $exit"

        if (Test-FileLocked -Path $tmpfile) {
            Write-Host "Temp file locked → $tmpfile"
            Debug "Temp file locked after remux"
            Remove-Item -LiteralPath $tmpfile -Force
            continue
        }

        Invoke-AtomicReplace -ExitCode $exit -TmpFile $tmpfile -OrigFile $f.FullName -SkipFile $fileSkip -SkipSizeCheck $true
        continue
    }

    ###############################################################
    # SKIP IF NO CONVERT NEEDED (correct location)
    ###############################################################
    if (-not $needs_convert) {
        Write-Host "Skipping $($f.FullName) -- already in desired format"
        continue
    }


    ###############################################################
    # FILTER SELECTION
    ###############################################################
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

    Debug "HandBrake filter: $hb_filter"

    ###############################################################
    # ANIMATION-SPECIFIC ENCODER SETTINGS
    ###############################################################
    $hb_animation = @(
        "--quality 20",
        "--encoder-preset slow"
    ) -join " "

    ###############################################################
    # TEMP OUTPUT
    ###############################################################
    $tmpfile = Join-Path $dir ($baseNoExt + '[Trans].tmp')
    Debug "Temp output file: $tmpfile"

    if (Test-Path -LiteralPath $tmpfile) {
        Debug "Removing existing temp file"
        Remove-Item -LiteralPath $tmpfile -Force
    }

    Write-Host "Input    : $($f.FullName)"
    Write-Host "Temp Out : $tmpfile"
    Write-Host "Filters  : $hb_filter"
    Write-Host "AnimTune : $hb_animation"

    ###############################################################
    # RUN HANDBRAKE
    ###############################################################
    Debug "Running HandBrakeCLI..."

    # Lock check before encode
    if (Test-FileLocked -Path $f.FullName) {
        Write-Host "Skipping $($f.FullName) -- file is locked"
        Debug "File locked before encode"
        continue
    }

    if ($hb_filter -eq "") {
        HandBrakeCLI `
            --input "$($f.FullName)" `
            --output "$tmpfile" `
            --format mkv `
            --encoder vce_h265 `
            --encoder-preset balance `
            --quality 24 `
            --maxHeight 2160 `
            --aencoder av_aac `
            --ab 160 `
            --subtitle-lang-list eng,und --subtitle-default=1 `
    }
    else {
        HandBrakeCLI `
            --input "$($f.FullName)" `
            --output "$tmpfile" `
            --format mkv `
            --encoder vce_h265 `
            --quality 24 `
            --encoder-preset balance `
            --maxHeight 2160 `
            --aencoder av_aac `
            --ab 160 `
            --subtitle-lang-list eng,und --subtitle-default=1 `
            $hb_filter
    }

    $exit = $LASTEXITCODE
    Debug "HandBrake exit code: $exit"

    # Lock check after encode
    if (Test-FileLocked -Path $tmpfile) {
        Write-Host "Temp file locked → $tmpfile"
        Debug "Temp file locked after encode"
        Remove-Item -LiteralPath $tmpfile -Force
        continue
    }

    Invoke-AtomicReplace -ExitCode $exit -TmpFile $tmpfile -OrigFile $f.FullName -SkipFile $fileSkip
}

###############################################################
# CLEANUP
###############################################################
Write-Host "Cleaning up leftover [Trans] files..."
Debug "Running cleanup..."

Get-ChildItem -Recurse -File |
    Where-Object {
        $_.Name -match '\[Trans\]\.tmp' -or
        $_.Name -match '\[Trans\]\.nfo' -or
        $_.Name -match '\[Trans\]\.jpg'
    } |
    ForEach-Object {
        Debug "Removing leftover file: $($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Force
    }

Get-ChildItem -Recurse -Directory |
    Where-Object { $_.Name -match '\[Trans\]\.trickplay' } |
    ForEach-Object {
        Debug "Removing leftover directory: $($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }

Write-Host "All tasks complete."
Debug "Script finished"
