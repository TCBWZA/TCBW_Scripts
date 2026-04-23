<#
.SYNOPSIS
    Transcodes foreign-language video files to HEVC/AAC using ffmpeg with Intel QSV hardware encoding.

.DESCRIPTION
    Recursively scans the current directory for MKV, MP4, and TS files over 1 GB and
    transcodes them to HEVC (H.265) video with AAC audio using ffmpeg and the Intel
    Quick Sync Video (hevc_qsv) hardware encoder. Files already in the desired format
    are skipped. Supports parallel encoding with a configurable job limit.

    Features:
    - Parallel encoding with configurable job limit
    - Progress bar tracking
    - Debug mode output
    - Pre-flight tool availability checks
    - Disk space guard before processing
    - Fast remux path for non-MKV containers already in HEVC
    - High-resolution (> 1100p) and AV1 guards
    - Interlace detection and deinterlacing via QSV
    - Atomic replacement with size validation
    - Temp file cleanup on interruption
    - Per-file and parent-directory .skip marker support
    - Configurable temp directory for intermediate files

.PARAMETER Debug
    Enables verbose debug output.

.EXAMPLE
    PS> .\compress_qsv_x265_aac.ps1

.EXAMPLE
    PS> .\compress_qsv_x265_aac.ps1 -Debug

.NOTES
    - Requires PowerShell 7+, ffmpeg, and ffprobe on PATH.
    - Intel Quick Sync Video hardware encoding must be available on the system.
    - Run from the root directory containing your foreign-language video folders.
    - Adjust $MaxJobs, $MinBitrate, $MinFileSize, $MinDiskSpace, and $TempDir as needed.
    - Place a .skip file in any directory to exclude it and all subdirectories.
    - Place a .skip_<basename> file alongside a video to exclude that file.
#>
param(
    [Alias("d")]
    [switch]$Debug
)

$DebugMode = $Debug.IsPresent

###############################################################
# PRE-FLIGHT CHECKS
###############################################################
$requiredTools = @('ffprobe', 'ffmpeg')
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
        Write-Host "\nCleaning up temp files due to interruption..."
        foreach ($file in $tempFilesToCleanup) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
Register-EngineEvent PowerShell.Exiting -Action $cleanupTrap | Out-Null

Write-Host "Starting up…"
Write-Host "Scanning for files..."

###############################################################
# CONFIGURABLE THRESHOLDS
###############################################################
$MaxJobs = 2                      # Max parallel encodes
$MinBitrate = 2500000            # Bitrate threshold (bps) - skip if < this
$MinFileSize = 1                  # Minimum file size (GB)
$MinDiskSpace = 50                # Minimum free disk space (GB)

# Optional temp directory for intermediate files (use "" to keep alongside source)
$TempDir = ""   # or "D:\fasttemp" for intermediate files

# Gather files
$AllFiles = Get-ChildItem -Recurse -Include *.mkv,*.ts,*.mp4 -File | Where-Object {
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($_.FullName)
    $FileSizeGB = [math]::Floor($_.Length / 1GB)
    -not ($Base.Contains("[Cleaned]") -or $Base.Contains("[Trans]")) -and
    $FileSizeGB -ge $MinFileSize
}

$Total = $AllFiles.Count
Write-Host "Found $Total files."
Write-Host "Preparing parallel encoding tasks..."

# Shared progress state
$Progress = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new()
$Progress["Completed"] = 0

Write-Host "Starting parallel processing with $MaxJobs concurrent jobs..."

# Progress bar job (runs in main runspace)
$progressJob = Start-Job -ArgumentList $Total, $Progress -ScriptBlock {
    param($Total, $Progress)

    while ($Progress["Completed"] -lt $Total) {
        $percent = if ($Total -gt 0) { ($Progress["Completed"] / $Total) * 100 } else { 100 }
        Write-Progress -Activity "Encoding Files" `
                       -Status "$($Progress["Completed"]) of $Total completed" `
                       -PercentComplete $percent
        Start-Sleep -Milliseconds 300
    }

    Write-Progress -Activity "Encoding Files" -Completed
}

# Parallel processing
$AllFiles | ForEach-Object -Parallel {

    param($TempDir, $Progress)

    $File = $_.FullName
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $Dir  = $_.DirectoryName

    $episode_skip_file = Join-Path $Dir ".skip_$Base"
    $parent_skip_file = Join-Path (Split-Path -LiteralPath $Dir) ".skip"

    # Check for skip markers
    if (Test-Path -LiteralPath $parent_skip_file) {
        Write-Host "Skipping $File -- parent directory marked as done"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }
    if (Test-Path -LiteralPath $episode_skip_file) {
        Write-Host "Skipping $File -- episode marked as un-compressible"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    # Decide temp location
    if ([string]::IsNullOrWhiteSpace($TempDir)) {
        $Tmp = Join-Path $Dir "$Base`[Trans`].tmp"
    }
    else {
        $Tmp = Join-Path $TempDir "$Base`[Trans`].tmp"
    }

    Write-Host "Checking $File"

    # Check disk space before processing
    if ([string]::IsNullOrWhiteSpace($TempDir)) {
        $checkDir = $Dir
    } else {
        $checkDir = $TempDir
    }
    $drive = $checkDir -replace '(^[a-zA-Z]).*', '$1'
    $diskInfo = Get-PSDrive -Name $drive[0]
    $freespaceGB = [math]::Floor($diskInfo.Free / 1GB)
    
    if ($freespaceGB -lt $MinDiskSpace) {
        Write-Host "Skipping $File -- insufficient disk space (${freespaceGB}GB free, need ${MinDiskSpace}GB)" -ForegroundColor Yellow
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    # Single ffprobe call (JSON)
    $probeJson = ffprobe -v quiet -print_format json -show_streams "$File"
    $probe     = $probeJson | ConvertFrom-Json

    $video = $probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $audio = $probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $vcodec   = $video.codec_name
    $vbitrate = if ($video.bit_rate) { [int]($video.bit_rate[0]) } else { 0 }
    $field    = $video.field_order
    $acodec   = $audio.codec_name

    if ($using:DebugMode) { Write-Host "[DEBUG] $File vcodec=$vcodec vbitrate=$vbitrate acodec=$acodec field=$field" -ForegroundColor DarkGray }

    # Skip AV1 files entirely
    if ($vcodec -eq "av1") {
        Write-Host "Skipping $File -- AV1 detected"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    # SKIP: high resolution (> 1100p) -- ffprobe secondary check
    $vheight = if ($video.height) { [int]$video.height } else { 0 }
    if ($vheight -gt 1100) {
        Write-Host "Skipping $File -- high-resolution video detected (height=$vheight)"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    #####################################################
    # Fast remux path: HEVC + progressive + low bitrate + non-MKV container
    #####################################################

    $ext = [System.IO.Path]::GetExtension($File).ToLower().TrimStart('.')
    $canRemux = ($vcodec -eq "hevc") -and
                (-not ($vbitrate -match '^\d+$' -and [int]$vbitrate -gt $using:MinBitrate)) -and
                ($field -eq "progressive") -and
                ($ext -ne "mkv")

    if ($canRemux) {
        Write-Host "Remuxing $File → MKV (container change, streams copied)"
        if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force }

        ffmpeg -nostdin -hide_banner -y `
            -i "$File" `
            -map 0 `
            -c copy `
            -f matroska `
            "$Tmp"

        if ($LASTEXITCODE -eq 0) {
            $origFile = Get-Item -LiteralPath $File
            $origSize = $origFile.Length
            $newSize = (Get-Item -LiteralPath $Tmp).Length

            if ($newSize -lt $origSize) {
                $timestamp = $origFile.LastWriteTime
                Remove-Item -LiteralPath $File -Force
                Move-Item -LiteralPath $Tmp -Destination $File -Force
                (Get-Item -LiteralPath $File).LastWriteTime = $timestamp
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Replaced (remux): ${origMB}MB → ${newMB}MB"
            }
            else {
                Write-Host "Skipped (remux): new file not smaller"
                New-Item -Path $episode_skip_file -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $Tmp -Force
            }
        }
        else {
            if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force }
        }

        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    # Fast checks first, skip expensive detection if already need to convert
    $NeedsConvert = $false
    if ($acodec -ne "aac") { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $vcodec -ne "hevc") { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $vbitrate -match '^\d+$' -and [int]$vbitrate -gt $MinBitrate) { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $field -ne "progressive") { $NeedsConvert = $true }

    if (-not $NeedsConvert) {
        Write-Host "Skipping $File -- already in desired format"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    if ($using:DebugMode) { Write-Host "[DEBUG] $File NeedsConvert=true vf=$vf" -ForegroundColor DarkGray }

    # Remove stale temp file
    if (Test-Path -LiteralPath $Tmp) {
        Remove-Item -LiteralPath $Tmp -Force
    }
    $tempFilesToCleanup += $Tmp

    # Interlace detection (optimised) - skip first 5 minutes to avoid credits/intros, analyze next 200 frames
    if ($field -eq "progressive") {
        $vf = "format=qsv"
    }
    else {
        $idet = ffmpeg -hide_banner `
            -ss 300 `
            -skip_frame nokey `
            -filter:v idet `
            -frames:v 200 `
            -an -f null - "$File" 2>&1

        $match = $idet | Select-String -Pattern "Interlaced:\s*(\d+)" -AllMatches
        $InterlacedCount = if ($match) { [int]$match.Matches.Groups[1].Value } else { 0 }

        $vf = if ($InterlacedCount -gt 0) { "deinterlace_qsv" } else { "format=qsv" }
    }

    Write-Host "Processing $File"

    ffmpeg -hide_banner `
        -hwaccel qsv -hwaccel_output_format qsv `
        -i "$File" `
        -vf "$vf" `
        -c:v hevc_qsv `
        -b:v 1800k -maxrate 2000k -bufsize 4000k `
        -c:a copy `
        -c:s copy `
        -f matroska `
        "$Tmp"

    if ($LASTEXITCODE -eq 0) {
        try {
            # Only replace original if new file is smaller
            $origFile = Get-Item -LiteralPath $File
            $origSize = $origFile.Length
            $newSize = (Get-Item -LiteralPath $Tmp).Length
            
            if ($newSize -lt $origSize) {
                $timestamp = $origFile.LastWriteTime
                Remove-Item -LiteralPath $File -Force
                Move-Item -LiteralPath $Tmp -Destination $File -Force
                (Get-Item -LiteralPath $File).LastWriteTime = $timestamp
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
            }
            else {
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip_$Base"
                New-Item -Path $episode_skip_file -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $Tmp -Force
            }
        }
        catch {
            Write-Host "Error finalizing $File : $($_.Exception.Message)"
            if (Test-Path -LiteralPath $Tmp) {
                Remove-Item -LiteralPath $Tmp -Force
            }
        }
    }
    else {
        if (Test-Path -LiteralPath $Tmp) {
            Remove-Item -LiteralPath $Tmp -Force
        }
    }

    # Update global progress
    $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })

} -ThrottleLimit $MaxJobs -ArgumentList @($TempDir, $Progress)

# Wait for progress job to finish and clean it up
Wait-Job $progressJob | Out-Null
Receive-Job $progressJob | Out-Null
Remove-Job $progressJob

Write-Host "All encoding tasks completed."

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
