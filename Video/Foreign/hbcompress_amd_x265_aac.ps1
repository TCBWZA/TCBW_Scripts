<#
.SYNOPSIS
    Video processing and compression script using HandBrakeCLI and ffmpeg.

.DESCRIPTION
    This script scans the current directory tree for video files and applies
    processing rules aligned with the companion shell script. It performs
    container health checks, optional remux operations, interlace and telecine
    detection, and conditional transcoding using an existing HandBrake preset.

.PARAMETER Debug
    Enables verbose debug output.

.PARAMETER RemuxCheck
    Enables container repair remux operations when a container issue is found
    and no transcode is required.

.NOTES
    Requirements:
        - PowerShell 7 or later
        - ffprobe, ffmpeg, HandBrakeCLI available in PATH
        - Existing HandBrake preset named "1080p AMD x265"
        - ASCII-only output and comments

.EXAMPLE
    .\hbcompress_amd_x265_aac.ps1

.EXAMPLE
    .\hbcompress_amd_x265_aac.ps1 -Debug

.EXAMPLE
    .\hbcompress_amd_x265_aac.ps1 -RemuxCheck
#>

# =====================================================================
# PowerShell 7+ Video Processor
# Logic aligned with compress_amd_x265_aac.sh
# =====================================================================

[CmdletBinding()]
param(
    [Alias("d")]
    [switch]$Debug,

    [Alias("r")]
    [switch]$RemuxCheck
)

$ErrorActionPreference = "Stop"
$DebugMode = $Debug.IsPresent

function Debug {
    param([string]$Message)
    if ($DebugMode) {
        $ts = (Get-Date).ToString("HH:mm:ss.fff")
        Write-Host "[DEBUG $ts] $Message"
    }
}

Register-EngineEvent PowerShell.Exiting -Action {
    Write-Host "Interrupted -- exiting safely"
}

# =====================================================================
# Pre-flight checks
# =====================================================================

$requiredTools = @("ffprobe", "ffmpeg", "HandBrakeCLI")
foreach ($tool in $requiredTools) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: $tool not found in PATH"
        exit 1
    }
}

$presetName = "1080p AMD x265"

# =====================================================================
# Container health check
# =====================================================================

function Test-ContainerProblem {
    param([string]$Path)

    Debug "Checking container health: $Path"

    try {
        $probeJson = ffprobe -v quiet -print_format json -show_format -show_streams "$Path"
        $probe     = $probeJson | ConvertFrom-Json
    }
    catch {
        Debug "ffprobe failed"
        return $true
    }

    $startTime = $probe.format.start_time
    if (-not $startTime -or $startTime -eq "N/A") {
        Debug "start_time invalid"
        return $true
    }

    $duration = $probe.format.duration
    if (-not $duration -or $duration -eq "N/A") {
        Debug "duration invalid"
        return $true
    }

    if ($duration -match "^-?[0-9.]+$") {
        if ([double]$duration -le 0) {
            Debug "duration non-positive"
            return $true
        }
    }

    $ffmpegErrors = & ffmpeg -nostdin -hide_banner -v error -i "$Path" -f null - 2>&1
    if ($ffmpegErrors) {
        Debug "ffmpeg demux errors detected"
        return $true
    }

    return $false
}

# =====================================================================
# File lock detection
# =====================================================================

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
    catch {
        Debug "File locked"
        return $true
    }
}

# =====================================================================
# Atomic replacement
# =====================================================================

function Invoke-AtomicReplace {
    param(
        [int]$ExitCode,
        [string]$TmpFile,
        [string]$OrigFile,
        [string]$SkipFile,
        [bool]$SkipSizeCheck = $false
    )

    Debug "AtomicReplace: exit=$ExitCode tmp=$TmpFile orig=$OrigFile"

    if ($ExitCode -ne 0) {
        Write-Host "Transcode or remux failed. Exit code: $ExitCode"
        if (Test-Path -LiteralPath $TmpFile) { Remove-Item -LiteralPath $TmpFile -Force }
        return
    }

    if (-not (Test-Path -LiteralPath $TmpFile)) {
        Write-Host "Temp file missing"
        return
    }

    $tmpItem = Get-Item -LiteralPath $TmpFile
    if ($tmpItem.PSIsContainer) {
        Write-Host "ERROR: Temp path is a directory"
        return
    }

    if (Test-FileLocked -Path $TmpFile) {
        Write-Host "Temp file locked"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    $orig = Get-Item -LiteralPath $OrigFile
    $origSize = $orig.Length
    $newSize  = $tmpItem.Length

    if ($newSize -le 0) {
        Write-Host "ERROR: Temp file zero length"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    if (-not $SkipSizeCheck) {
        if ($newSize -ge $origSize) {
            Write-Host "Skipped: new file not smaller"
            if ($SkipFile) { New-Item -LiteralPath $SkipFile -ItemType File -Force | Out-Null }
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }
    }

    if (Test-FileLocked -Path $OrigFile) {
        Write-Host "Original file locked"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    try {
        Set-ItemProperty -LiteralPath $TmpFile -Name LastWriteTime -Value $orig.LastWriteTime
    }
    catch {}

    if (Test-FileLocked -Path $OrigFile) {
        Write-Host "Original file locked at commit"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    Remove-Item -LiteralPath $OrigFile -Force

    if (Test-FileLocked -Path $TmpFile) {
        Write-Host "Temp file locked at final move"
        Remove-Item -LiteralPath $TmpFile -Force
        return
    }

    Move-Item -LiteralPath $TmpFile -Destination $OrigFile -Force
    Write-Host "Replaced file"
}

# =====================================================================
# Interlace / telecine detection (idet parity)
# =====================================================================

function Get-VideoStatus {
    param(
        [string]$Path,
        [string]$FieldOrder
    )

    if ($FieldOrder -match "^(tt|bb|tb|bt)$") {
        Debug "Interlaced by field_order"
        return "interlaced"
    }
    elseif ($FieldOrder -eq "progressive") {
        Debug "Progressive by field_order"
        return "progressive"
    }

    Write-Host "Running deep interlace scan..."
    Debug "Running idet..."

    $idetOutput = & ffmpeg -nostdin -hide_banner `
        -ss 300 `
        -noaccurate_seek `
        -skip_frame nokey `
        -i "$Path" `
        -skip_frame default `
        -filter:v idet `
        -frames:v 1000 `
        -an -f null - 2>&1

    $interlaced = 0
    $tff = 0
    $bff = 0

    $m = [regex]::Match($idetOutput, "Interlaced:\s*([0-9]+)")
    if ($m.Success) { $interlaced = [int]$m.Groups[1].Value }

    $m = [regex]::Match($idetOutput, "TFF:\s*([0-9]+)")
    if ($m.Success) { $tff = [int]$m.Groups[1].Value }

    $m = [regex]::Match($idetOutput, "BFF:\s*([0-9]+)")
    if ($m.Success) { $bff = [int]$m.Groups[1].Value }

    if ((($tff -gt 50) -or ($bff -gt 50)) -and ($interlaced -lt 20)) {
        Debug "Telecine detected"
        return "telecine"
    }
    elseif ($interlaced -gt 50) {
        Debug "Interlaced detected"
        return "interlaced"
    }
    else {
        Debug "Progressive assumed"
        return "progressive"
    }
}

# =====================================================================
# Startup
# =====================================================================

Write-Host "Starting up..."
Write-Host "Scanning for files..."

$root = (Get-Location).ProviderPath

# Fast .NET enumeration
$files = foreach ($path in [System.IO.Directory]::EnumerateFiles($root, "*", "AllDirectories")) {

    if ($path.EndsWith(".mkv", [System.StringComparison]::OrdinalIgnoreCase) -or
        $path.EndsWith(".mp4", [System.StringComparison]::OrdinalIgnoreCase) -or
        $path.EndsWith(".ts",  [System.StringComparison]::OrdinalIgnoreCase)) {

        $info = [System.IO.FileInfo]::new($path)

        if ($info.Length -ge 950MB) {
            $info
        }
    }
}

Write-Host "Found $($files.Count) files."
Write-Host "Beginning processing..."

# =====================================================================
# Main loop
# =====================================================================

foreach ($f in $files) {

    Debug "---------------------------------------------"
    Debug "Processing: $($f.FullName)"

    $base = $f.BaseName
    $dir  = $f.DirectoryName

    # Directory .skip check
    $scan = Get-Item -LiteralPath $dir
    $skip = $false

    while ($scan -and $scan.FullName.StartsWith($root)) {
        $marker = Join-Path $scan.FullName ".skip"
        if (Test-Path -LiteralPath $marker) {
            Debug ".skip found at $($scan.FullName)"
            $skip = $true
            break
        }
        if (-not $scan.Parent) { break }
        $scan = $scan.Parent
    }

    if ($skip) { continue }

    # Per-file skip
    $fileSkip = Join-Path $dir (".skip_$base")
    if (Test-Path -LiteralPath $fileSkip) {
        Write-Host "Skipping $($f.FullName) -- file marked skip"
        continue
    }

    # Delete leftover cleaned/transcoded
    if ($base -match "\[Cleaned\]|\[Trans\]") {
        Debug "Deleting leftover processed file"
        Remove-Item -LiteralPath $f.FullName -Force
        continue
    }

    Write-Host "Checking $($f.FullName)"

        # ffprobe JSON (hardened)
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_streams "$($f.FullName)"
        $probe     = $probeJson | ConvertFrom-Json
    }
    catch {
        Write-Host "Skipping $($f.FullName) -- ffprobe JSON invalid"
        continue
    }

    # Ensure streams exist
    if (-not $probe.streams) {
        Write-Host "Skipping $($f.FullName) -- no streams found"
        continue
    }

    # Select video stream (ignore attached pictures)
    $video = $probe.streams |
        Where-Object { $_.codec_type -eq "video" -and -not $_.disposition.attached_pic } |
        Select-Object -First 1

    if (-not $video) {
        Write-Host "Skipping $($f.FullName) -- no usable video stream"
        continue
    }

    # Select audio stream
    $audio = $probe.streams |
        Where-Object { $_.codec_type -eq "audio" } |
        Select-Object -First 1

    if (-not $audio) {
        Write-Host "Skipping $($f.FullName) -- no audio stream"
        continue
    }

    # Safe extraction helpers
    function ConvertTo-Safe-String { param($v) if ($null -eq $v) { "" } else { "$v" } }
    function ConvertTo-Safe-Int    { param($v) if ($v -match "^[0-9]+$") { [int]$v } else { 0 } }

    # Extract fields safely
    $vcodec_raw = ConvertTo-Safe-String $video.codec_name
    $vcodec_lc  = $vcodec_raw.ToLowerInvariant()

    $height_raw = ConvertTo-Safe-String $video.height
    $height     = ConvertTo-Safe-Int $height_raw

    $field_raw  = ConvertTo-Safe-String $video.field_order
    $field      = $field_raw.ToLowerInvariant()

    $acodec_raw = ConvertTo-Safe-String $audio.codec_name
    $acodec     = $acodec_raw.ToLowerInvariant()

    # Bitrate: try bit_rate, then tags.BPS, else 0
    $vbitrate_raw = $video.bit_rate
    if (-not $vbitrate_raw -and $video.tags -and $video.tags.BPS) {
        $vbitrate_raw = $video.tags.BPS
    }
    $vbitrate = ConvertTo-Safe-Int $vbitrate_raw

    Debug "vcodec=$vcodec_lc vbitrate=$vbitrate height=$height field_order=$field acodec=$acodec"


    # Skip AV1
    if ($vcodec_lc -in @("av1","av01","libaom-av1","unknown")) {
        Write-Host "Skipping $($f.FullName) -- AV1 or unsupported codec"
        continue
    }

    # Skip UHD-ish
    if ($height -gt 1100) {
        Write-Host "Skipping $($f.FullName) -- high resolution"
        continue
    }

    # Interlace detection
    $status = Get-VideoStatus -Path $f.FullName -FieldOrder $field
    Write-Host "Detected: $status"

    # Needs convert
    $needs = $false
    if ($vcodec_lc -ne "hevc") { $needs = $true }
    if ($vbitrate -gt 2500000) { $needs = $true }
    if ($status -ne "progressive") { $needs = $true }

    # Remux logic
    if (-not $needs -and $RemuxCheck -and $acodec -eq "aac") {
        if (Test-ContainerProblem -Path $f.FullName) {
            Write-Host "Remuxing $($f.FullName) for container repair"

            $tmp = Join-Path $dir ($base + "[Trans].tmp")
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

            if (Test-FileLocked -Path $f.FullName) {
                Write-Host "Skipping $($f.FullName) -- locked"
                continue
            }

            & ffmpeg -nostdin -hide_banner -y `
                -i "$($f.FullName)" `
                -map 0 `
                -c:v copy -c:a copy -c:s copy `
                -f matroska `
                "$tmp"

            $exit = $LASTEXITCODE

            if (Test-FileLocked -Path $tmp) {
                Write-Host "Temp file locked"
                Remove-Item -LiteralPath $tmp -Force
                continue
            }

            Invoke-AtomicReplace -ExitCode $exit -TmpFile $tmp -OrigFile $f.FullName -SkipFile $fileSkip -SkipSizeCheck $true
            continue
        }
    }

    if (-not $needs) {
        Write-Host "Skipping $($f.FullName) -- already in desired format"
        continue
    }

    # HandBrake filter selection
    $hbFilters = @()
    switch ($status) {
        "interlaced" {
            Write-Host "Applying deinterlace"
            $hbFilters = @("--deinterlace=slower")
        }
        "telecine" {
            Write-Host "Applying detelecine + deinterlace"
            $hbFilters = @("--detelecine","--deinterlace=slower")
        }
        default {
            Write-Host "Progressive: no filters"
            $hbFilters = @()
        }
    }

    # Temp output
    $tmp = Join-Path $dir ($base + "[Trans].tmp")
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

    Write-Host "Input: $($f.FullName)"
    Write-Host "Temp:  $tmp"

    if (Test-FileLocked -Path $f.FullName) {
        Write-Host "Skipping $($f.FullName) -- locked"
        continue
    }

    # HandBrakeCLI
    $hbArgs = @(
        "--preset", $presetName,
        "--input",  $f.FullName,
        "--output", $tmp
    ) + $hbFilters

    & HandBrakeCLI @hbArgs
    $exit = $LASTEXITCODE

    if (Test-FileLocked -Path $tmp) {
        Write-Host "Temp file locked"
        Remove-Item -LiteralPath $tmp -Force
        continue
    }

    Invoke-AtomicReplace -ExitCode $exit -TmpFile $tmp -OrigFile $f.FullName -SkipFile $fileSkip
}

# =====================================================================
# Cleanup
# =====================================================================

Write-Host "Cleaning up leftover Trans files..."

Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $_.Name -match "\[Trans\]\.tmp" -or
        $_.Name -match "\[Trans\]\.nfo" -or
        $_.Name -match "\[Trans\]\.jpg"
    } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }

Get-ChildItem -LiteralPath $root -Recurse -Directory |
    Where-Object { $_.Name -match "\[Trans\]\.trickplay" } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }

Write-Host "All tasks complete."
