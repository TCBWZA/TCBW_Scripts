<#
.SYNOPSIS
    Forces TV video files to 1080p SDR using HandBrake with AMD VCE hardware encoding.

.DESCRIPTION
    Recursively scans the current directory for MKV, MP4, and TS files over 1 GB and
    forces them to 1080p SDR using HandBrakeCLI with the "1080p SDR AMD x265" preset
    and the AMD VCE (vce_h265) hardware encoder.

    Any input above 1920x1080 is downscaled, and HDR input (HDR10 or HLG) is tone
    mapped to SDR. Unlike hbcompress_amd_x265_aac.ps1, UHD input is NOT skipped.
    A file is only treated as already-compliant when it is HEVC, AAC, progressive,
    at or below 1920x1080, and not HDR.

    Features:
    - Debug mode with timestamped output
    - MKV container health check with automatic remux repair path
    - File lock detection before and after encode/move
    - Atomic replacement with size validation
    - Deferred interlace detection (runs only when needed)
    - Forced 1080p downscale and HDR to SDR tone mapping
    - Post-encode probe that discards output failing the 1080p/SDR check
    - AV1, no-video-stream, and no-audio-stream guards
    - Recursive .skip directory marker support
    - Per-file .skip_<basename> marker support

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
# POST-ENCODE 1080p SDR CHECK
###############################################################
function Test-OutputIs1080pSDR {
    param([string]$Path)

    try {
        $out = ffprobe -v quiet -print_format json -show_streams -select_streams v "$Path" |
            ConvertFrom-Json
    }
    catch {
        Write-Host "Post-check FAILED: could not probe output ($($_.Exception.Message))"
        Debug "Post-encode probe threw: $($_.Exception.Message)"
        return $false
    }

    $s = ($out.streams | Where-Object { $_.codec_type -eq "video" -and -not $_.disposition.attached_pic })[0]
    if (-not $s) {
        Write-Host "Post-check FAILED: no video stream in output"
        Debug "Post-encode probe found no video stream"
        return $false
    }

    if (($s.width -gt 1920) -or ($s.height -gt 1080)) {
        Write-Host "Post-check FAILED: output is $($s.width)x$($s.height), expected <= 1920x1080"
        Debug "Output too large: $($s.width)x$($s.height)"
        return $false
    }

    # bt2020-10 must be caught here too, same reason as the input check.
    if ($s.color_transfer -in @("smpte2084", "arib-std-b67", "bt2020-10")) {
        Write-Host "Post-check FAILED: output is still HDR (color_transfer=$($s.color_transfer))"
        Debug "Output still HDR: $($s.color_transfer)"
        return $false
    }

    # Non-square pixels. This is a guard, not a description of normal output:
    # the script now computes the fit itself and forces --non-anamorphic, so a
    # correct encode is always 1:1. It is kept because that is exactly how the
    # 3840x1920 source went wrong once already, landing as 1920x1080 SAR 9:8
    # (a 2160x1080 display) purely from the preset's anamorphic mode. Storage
    # dims alone cannot catch that, so the SAR has to be checked explicitly.
    $sar = $s.sample_aspect_ratio
    if ($sar -and $sar -ne "1:1" -and $sar -ne "0:1") {
        Write-Host "Post-check FAILED: non-square pixels (SAR=$sar), output is not true 1080p"
        Debug "Output has non-square pixels: SAR=$sar"
        return $false
    }

    Write-Host "Post-check OK: $($s.width)x$($s.height) SDR (transfer=$($s.color_transfer), SAR=$sar)"
    return $true
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
        Write-Host "ERROR: Temp output path is a directory -> $TmpFile"
        Debug "Temp path is directory"
        return
    }

    # Lock check on temp file
    if (Test-FileLocked -Path $TmpFile) {
        Write-Host "Temp file locked -> $TmpFile"
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
            Write-Host "ERROR: Temp file is zero-length. Deleting it."
            Debug "Temp file zero-length"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        if (-not $SkipSizeCheck) {
            # Require the new file to be at least 10% smaller
            if (($newSize * 10) -ge ($origSize * 9)) {
                Write-Host "Skipped: new file not 10% smaller (${origMB}MB -> ${newMB}MB)"
                Debug "New file not 10% smaller, marking skip"
                New-Item -Path $SkipFile -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $TmpFile -Force
                return
            }
        }

        if (Test-FileLocked -Path $OrigFile) {
            Write-Host "File is locked -> $OrigFile"
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
            Write-Host "Original file locked during commit -> $OrigFile"
            Debug "Original locked at final commit"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        $isMkv = [System.IO.Path]::GetExtension($OrigFile) -ieq ".mkv"
        $finalPath = if ($isMkv) { $OrigFile } else { [System.IO.Path]::ChangeExtension($OrigFile, ".mkv") }

        if ($finalPath -ne $OrigFile) {
            if (Test-Path -LiteralPath $finalPath) {
                Write-Host "Target already exists, refusing to overwrite: $finalPath"
                Debug "Destination collision: $finalPath"
                Remove-Item -LiteralPath $TmpFile -Force
                return
            }
            Write-Host "Output will be Matroska -> $finalPath"
        }

        # Final lock check before move
        if (Test-FileLocked -Path $TmpFile) {
            Write-Host "Temp file locked during final move -> $TmpFile"
            Debug "Temp locked at final move"
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }

        Write-Host "Committing new file -> $finalPath"
        Debug "Moving temp file into place"
        Move-Item -LiteralPath $TmpFile -Destination $finalPath -Force
        if ($finalPath -ne $OrigFile) { Remove-Item -LiteralPath $OrigFile -Force }

        Write-Host "Replaced: ${origMB}MB -> ${newMB}MB"
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

    $stream = $probe.streams | Where-Object { $_.codec_type -eq "video" -and -not $_.disposition.attached_pic }

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

    Write-Host -NoNewline "$([char]0x1B)]0;$($f.Name)`a"

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
        $marker = [System.IO.FileInfo]::new($fileSkip)
        $honour = $true
        if ($marker.Length -gt 0) {
            # Only this script's own tag counts as proof of a 1080p/SDR pass.
            # A compliant-v1 tag written by hbcompress_amd_x265_aac.ps1 says
            # nothing about resolution or HDR, so it must not stop us here.
            $fingerprinted = [System.IO.File]::ReadAllText($fileSkip) -match '^compliant-1080psdr-v1\|(\d+)\|(\d+)$'
            $honour = $fingerprinted -and ($f.Length -eq [long]$matches[1] -and $f.LastWriteTimeUtc.Ticks -eq [long]$matches[2])
            if (-not $honour) {
                Write-Host "Marker does not certify a 1080p SDR pass -- rechecking $($f.Name)"
                Debug "Marker invalid for this pass, removing: $fileSkip"
                Remove-Item -LiteralPath $fileSkip -Force
            }
        }
        if ($honour) {
            Write-Host "Skipping $($f.FullName) -- file marked with $(Split-Path $fileSkip -Leaf)"
            Debug "Per-file skip triggered: $fileSkip"
            continue
        }
    }

        # SKIP: Already processed
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Debug "Already processed marker found, deleting original"
        Remove-Item -LiteralPath $f.FullName -Force
        continue
    }

    Write-Host "Checking $($f.FullName)"
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

    $videoStream = ($probe.streams | Where-Object { $_.codec_type -eq "video" -and -not $_.disposition.attached_pic })[0]

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

    # Above 1080p and HDR are the two reasons this script exists, so they are
    # never a reason to skip. They only feed needs_convert further down.
    # bt2020-10 is how ffprobe reports HDR10 in Matroska, NOT smpte2084 --
    # matching only smpte2084 silently certified an HDR10 file as SDR.
    $colorTransfer = $videoStream.color_transfer
    $isHDR = $colorTransfer -in @("smpte2084", "arib-std-b67", "bt2020-10")
    $tooBig = ($width -gt 1920) -or ($height -gt 1080)
    Debug "Color transfer: $colorTransfer"
    Debug "HDR: $isHDR"
    Debug "Above 1080p: $tooBig"

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

    # Audio handling comes entirely from the preset: copy whatever the preset
    # accepts, fall back to AAC 160k for the rest. No per-track args needed.

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
    if ($tooBig) { $needs_convert = $true }
    if ($isHDR) { $needs_convert = $true }
    Debug "Needs convert (pre-interlace): $needs_convert"

    ###############################################################
    # INTERLACE DETECTION
    ###############################################################
    if ($vcodec -eq "hevc") {

        # If ffprobe reports progressive, trust it
        if ($videoStream.field_order -eq "progressive") {
            Debug "HEVC flagged progressive -> skipping interlace detection"
            $status = "progressive"
        }
        # If ffprobe reports known interlace patterns, treat as interlaced
        elseif ($videoStream.field_order -match "^(tt|bb|tb|bt)$") {
            Debug "HEVC flagged interlaced -> running full detection"
            $status = Get-VideoInterlaceStatus $f.FullName
        }
        # If field_order is missing or weird, run slow detection
        else {
            Debug "HEVC field_order unknown -> running slow interlace/telecine detection"
            $status = Get-VideoInterlaceStatus $f.FullName
        }
    }
    else {
        # Non-HEVC -> always run full detection
        $status = Get-VideoInterlaceStatus $f.FullName
    }
    Debug "Interlace status: $status"

    if ($status -ne "progressive") { $needs_convert = $true }
    Debug "Needs convert: $needs_convert"

    ###############################################################
    # REMUX LOGIC
    ###############################################################
    $canRemux = $false

    # Only remux if transcoding is NOT needed
    if (-not $needs_convert) {
        if ($f.Extension -ieq ".mkv") {
            # Only remux if MKV container is problematic
            if (Test-MKVContainerProblem -Path $f.FullName) {
                $canRemux = $true
            }
        }
        else {
            $canRemux = $true
        }
    }

    if ($canRemux) {
        Write-Host "Remuxing $($f.FullName) -> MKV (stream copy)"
        Debug "Stream-copy remux triggered"

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
            Write-Host "Temp file locked -> $tmpfile"
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
            Write-Host "Skipping $($f.FullName) -- already 1080p SDR HEVC/AAC"
            Set-Content -LiteralPath $fileSkip -Value "compliant-1080psdr-v1|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)" -Encoding ascii -NoNewline
        Debug "Compliant fingerprint written: $fileSkip"
        continue
    }


    ###############################################################
    # FILTER SELECTION
    ###############################################################
    switch ($status) {
        "interlaced" {
            $hb_filter = "--deinterlace=slower"
            Write-Host "Detected: TRUE INTERLACE -> Applying deinterlace=slower"
        }
        "progressive" {
            $hb_filter = ""
            Write-Host "Detected: PROGRESSIVE -> No deinterlace"
        }
        "unknown" {
            $hb_filter = "--detelecine --deinterlace=slower"
            Write-Host "Detected: UNKNOWN / TELECINE -> Applying detelecine + deinterlace=slower"
        }
    }

    Debug "HandBrake filter: $hb_filter"

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

    # Fit inside 1920x1080 with square pixels.
    #
    # This must be an explicit --width/--height, not --maxWidth/--maxHeight.
    # Per `HandBrakeCLI --help`, --width/--height pin the *storage* box while
    # --maxWidth/--maxHeight are only a cap. The preset already pins
    # PictureWidth/PictureHeight to 1920x1080, so the cap had nothing left to
    # clamp: HandBrake's own job JSON showed width=1920/height=1080 with no
    # maxwidth/maxheight keys even though both were passed, and 3840x1920 came
    # out 1920x1080 SAR 9:8 (a 2160x1080 display). Computing the box here is
    # what actually fits it. Even dimensions are required for yuv420p.
    $scale = [math]::Min(1920.0 / $width, 1080.0 / $height)
    if ($scale -gt 1.0) { $scale = 1.0 }
    $outW = [int]([math]::Floor(($width * $scale) / 2) * 2)
    $outH = [int]([math]::Floor(($height * $scale) / 2) * 2)
    Write-Host "Output   : ${outW}x${outH} (source ${width}x${height})"

    # Preset supplies encoder and quality. Sizing and colour are passed on the
    # CLI because both need to be exact and the preset gets them wrong:
    #  - --width/--height: see the fit above. Computed per file because every
    #    source has its own aspect ratio, so no single box is correct. 2:1
    #    gives 1920x960, 2.4:1 gives 1920x800, 16:9 gives 1920x1080, and
    #    anything already inside the box is left at its own size. No padding:
    #    a short frame is the honest result for a short source.
    #  - --non-anamorphic: force SAR 1:1. The preset's anamorphic mode stores
    #    non-square pixels to preserve the source *display* aspect inside the
    #    box, which is what produced the 9:8 result. With the box already
    #    fitted to the source aspect, square pixels are the correct output.
    #  - --colorspace: HandBrake's GUI does not persist the Colorspace choice
    #    into an exported preset (verified: exports keep it at "off").
    # Colour conversion is skipped for SDR input.
    $hb_args = @(
        "--input", "$($f.FullName)",
        "--output", "$tmpfile",
        "--format", "mkv",
        "--preset-import-gui",
        "--preset", "1080p SDR AMD x265",
        "--width", "$outW",
        "--height", "$outH",
        "--non-anamorphic",
        "--no-hdr-dynamic-metadata",
        "--subtitle-lang-list", "eng,und",
        "--subtitle-default=1"
    )
    if ($isHDR) { $hb_args += @("--colorspace", "bt709") }
    if ($hb_filter -ne "") { $hb_args += $hb_filter.Split(" ") }

    & HandBrakeCLI @hb_args

    $exit = $LASTEXITCODE
    Debug "HandBrake exit code: $exit"

    # Lock check after encode
    if (Test-FileLocked -Path $tmpfile) {
        Write-Host "Temp file locked -> $tmpfile"
        Debug "Temp file locked after encode"
        Remove-Item -LiteralPath $tmpfile -Force
        continue
    }

    # Gate the replace on the output actually being 1080p SDR. This is what makes
    # a bad or missing tone map in the preset fail loudly instead of quietly
    # replacing a good HDR source with an equally HDR result.
    if (-not (Test-OutputIs1080pSDR -Path $tmpfile)) {
        Write-Host "Discarding output -- failed 1080p SDR post-check, original left untouched"
        Debug "Post-encode 1080p SDR check failed, discarding: $tmpfile"
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
