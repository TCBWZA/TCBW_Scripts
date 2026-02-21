Write-Host "Starting up…"
Write-Host "Scanning for files..."

# Max parallel encodes
$MaxJobs = 2

# Optional temp directory for intermediate files (use "" to keep alongside source)
$TempDir = "D:\fasttemp"   # or "" for same folder as source

# Gather files
$AllFiles = Get-ChildItem -Recurse -Include *.mkv,*.ts -File | Where-Object {
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($_.FullName)
    -not ($Base.Contains("[Cleaned]") -or $Base.Contains("[Trans]")) -and
    $_.Length -ge 1GB
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

    # Extract show name (first word) for hierarchical skip markers
    $show_name = ($Base -split '\s+')[0]
    $show_skip_file = Join-Path $Dir ".skip_$show_name"
    $parent_skip_file = Join-Path (Split-Path -LiteralPath $Dir) ".skip"

    # Check for skip markers
    if (Test-Path -LiteralPath $parent_skip_file) {
        Write-Host "Skipping $File -- parent directory marked as done"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }
    if (Test-Path -LiteralPath $show_skip_file) {
        Write-Host "Skipping $File -- show marked as uncompressible"
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

    # Single ffprobe call (JSON)
    $probeJson = ffprobe -v quiet -print_format json -show_streams "$File"
    $probe     = $probeJson | ConvertFrom-Json

    $video = $probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $audio = $probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

    $vcodec   = $video.codec_name
    $vbitrate = $video.bit_rate
    $field    = $video.field_order
    $acodec   = $audio.codec_name

    # Fast checks first, skip expensive detection if already need to convert
    $NeedsConvert = $false
    if ($acodec -ne "aac") { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $vcodec -ne "hevc") { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $vbitrate -match '^\d+$' -and [int]$vbitrate -gt 2500000) { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $field -ne "progressive") { $NeedsConvert = $true }

    if (-not $NeedsConvert) {
        Write-Host "Skipping $File -- already in desired format"
        $null = $Progress.AddOrUpdate("Completed", 1, { param($k, $old) $old + 1 })
        return
    }

    # Remove stale temp file
    if (Test-Path -LiteralPath $Tmp) {
        Remove-Item -LiteralPath $Tmp -Force
    }

    # Interlace detection (optimised) — skip first 5 minutes to avoid credits/intros, analyze next 200 frames
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
        -c:a aac -b:a 160k `
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
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip_$show_name"
                New-Item -Path $show_skip_file -ItemType File -Force | Out-Null
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
Write-Host "Cleaning up leftover [Trans] sidecar files and directories..."

# Cleanup section
#####################################################

Write-Host "Cleaning up all [Cleaned] and [Trans] files and directories..."

# Remove ALL [Cleaned] files (including .mkv, .tmp, .nfo, .jpg, etc.)
Get-ChildItem -Recurse -Include "*[Cleaned].*" -Force |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Remove [Cleaned] trickplay directories
Get-ChildItem -Recurse -Directory -Include "*[Cleaned].trickplay" |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Remove ALL [Trans] files (including .mkv, .tmp, .nfo, .jpg, etc.)
Get-ChildItem -Recurse -Include "*[Trans].*" -Force |
    Remove-Item -Force -ErrorAction SilentlyContinue

# Remove [Trans] trickplay directories
Get-ChildItem -Recurse -Directory -Include "*[Trans].trickplay" |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."
