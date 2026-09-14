<#
.SYNOPSIS
    Batch compresses TV show episode files using Intel Quick Sync Video (QSV).

.DESCRIPTION
    Recursively scans the current directory for MKV, MP4, and TS files 1 GB or larger
    and re-encodes files that are not already HEVC+AAC or exceed 2.5 Mbps video
    bitrate. Encoding uses hevc_qsv via Intel Quick Sync hardware acceleration.
    Interlace and telecine detection is performed with ffprobe/idet. The original file
    is replaced only when the new file is smaller, and AVC/AV1 streams are always
    transcoded. QSV-compatible filter chains are used per detection result
    (bwdif / pullup+dejudder / scale_qsv). Up to $MaxJobs parallel encoding jobs run
    at once.

.NOTES
    - Edit $MaxJobs at the top of the script.
    - Requires ffmpeg and ffprobe on PATH.
    - Requires an Intel CPU or GPU with Quick Sync Video support.
    - Files tagged [Cleaned] or [Trans] are deleted automatically.
    - A .skip directory marker skips the entire folder. A .skip_<basename> per-file marker skips that specific file.
    - A .skip_<basename> marker is created automatically when output is not smaller.
    - All audio and subtitle streams are copied without modification.

.PARAMETER Debug
    Enable verbose debug output.

.EXAMPLE
    Set-Location "Z:\Media\TV"
    .\compress_qsv_x265_aac.ps1
#>

param(
    [Alias("d")]
    [switch]$Debug
)

$DebugMode = $Debug.IsPresent

function Write-DebugLog {
    param([string]$Message)
    if ($DebugMode) {
        $ts = (Get-Date).ToString("HH:mm:ss.fff")
        Write-Host "[DEBUG $ts] $Message" -ForegroundColor DarkGray
    }
}

function Test-ContainerProblem {
    param([string]$Path)
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_format -show_streams "$Path"
        $probe = $probeJson | ConvertFrom-Json
    } catch { return $true }
    if ($probe.format.start_time -eq "N/A") { return $true }
    if ($probe.format.duration -eq "N/A") { return $true }
    if ($probe.format.duration -match '^-?[\d.]+$' -and [double]$probe.format.duration -le 0) { return $true }
    $ffmpegErrors = & ffmpeg -nostdin -hide_banner -v error -i $Path -f null - 2>&1
    if ($ffmpegErrors) { return $true }
    return $false
}

$MaxJobs = 1

Get-ChildItem -Recurse | Where-Object { $_.Extension -in '.mkv', '.mp4', '.ts' } | ForEach-Object {

    $File = $_.FullName
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $Dir  = $_.DirectoryName

    # Skip cleaned/transcoded files
    if ($Base.Contains("[Cleaned]") -or $Base.Contains("[Trans]")) {
        Remove-Item -LiteralPath $File -Force
        return
    }

    # Skip small files (<1GB)
    if ($_.Length -lt 1GB) {
        return
    }

    # Skip if directory .skip marker exists
    if (Test-Path -LiteralPath (Join-Path $Dir ".skip")) {
        Write-Host "Skipping $File -- .skip directory marker found"
        return
    }

    # Skip if per-file .skip_<basename> marker exists
    if (Test-Path -LiteralPath (Join-Path $Dir ".skip_$Base")) {
        Write-Host "Skipping $File -- .skip_$Base per-file marker found"
        return
    }

    # Skip 2160p or higher resolution videos (filename match)
    if ($Base -imatch '2160[pP]\]') {
        Write-Host "Skipping $File -- 4K (or higher) video match (filename)"
        return
    }

    Write-Host "Checking $File"

    # ffprobe checks
    $vcodec = ffprobe -v error -select_streams v:0 `
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$File"

    $vbitrate = ffprobe -v error -select_streams v:0 `
        -show_entries stream=bit_rate -of default=nw=1:nk=1 "$File"

    $acodec = ffprobe -v error -select_streams a:0 `
        -show_entries stream=codec_name -of default=nw=1:nk=1 "$File"

    $field = ffprobe -v error -select_streams v:0 `
        -show_entries stream=field_order -of default=nw=1:nk=1 "$File"

    $vheight = ffprobe -v error -select_streams v:0 `
        -show_entries stream=height -of default=nw=1:nk=1 "$File"

    # SKIP: high resolution (> 1100p) -- ffprobe secondary check, supplements filename check
    if ([int]$vheight -gt 1100) {
        Write-Host "Skipping $File -- high-resolution video detected (height=$vheight)"
        return
    }

    # Fast checks first, skip if true
    $NeedsConvert = $false
    if ($acodec -ne "aac") { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $vcodec -ne "hevc") { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $vbitrate -ne "N/A" -and [int]$vbitrate -gt 2500000) { $NeedsConvert = $true }
    if (-not $NeedsConvert -and $field -ne "progressive") { $NeedsConvert = $true }

    Write-DebugLog "vcodec=$vcodec vbitrate=$vbitrate acodec=$acodec field=$field NeedsConvert=$NeedsConvert"

    # Check for container problems before any skip/no-skip decision
    if (Test-ContainerProblem -Path $File) {
        Write-Host "Remuxing $File -- container repair"
        $Tmp = Join-Path $Dir "$Base`[Trans`].tmp"
        if (Test-Path $Tmp) { Remove-Item $Tmp -Force }

        # mov_text -> SRT: MP4 text subtitles cannot be stream-copied into MKV
        $RemuxSubArgs = @('-c:s', 'copy')
        if ([System.IO.Path]::GetExtension($File).ToLower() -eq '.mp4') {
            $subInfo = ffprobe -v quiet -print_format json -show_streams "$File" | ConvertFrom-Json
            if ($subInfo.streams | Where-Object { $_.codec_type -eq 'subtitle' -and $_.codec_name -eq 'mov_text' }) {
                Write-Host "Subtitle: mov_text detected in MP4 -- converting to SRT"
                $RemuxSubArgs = @('-c:s', 'srt')
            }
        }

        ffmpeg -hide_banner -nostdin -threads 2 -y `
            -i "$File" `
            -map 0 `
            -c:v copy -c:a copy `
            @RemuxSubArgs `
            -f matroska `
            "$Tmp"

        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Tmp)) {
            $origFile = Get-Item -LiteralPath $File
            $timestamp = $origFile.LastWriteTime
            $origSize = $origFile.Length
            $newSize  = (Get-Item -LiteralPath $Tmp).Length
            Remove-Item -LiteralPath $File -Force
            Move-Item -LiteralPath $Tmp -Destination $File -Force
            (Get-Item -LiteralPath $File).LastWriteTime = $timestamp
            Write-Host "Replaced (remux): $([math]::Round($origSize/1MB, 2))MB -> $([math]::Round($newSize/1MB, 2))MB"
        } else {
            if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force }
        }
        return
    }

    if (-not $NeedsConvert) {
        Write-Host "Skipping $File -- already in desired format"
        return
    }

    # Temp output
    $Tmp = Join-Path $Dir "$Base`[Trans`].tmp"

    if (Test-Path $Tmp) { Remove-Item $Tmp -Force }

    $status = "progressive"

    if ($field -match "^(tt|bb|tb|bt)$") {
        $status = "interlaced"
    } elseif ($field -ne "progressive") {
        Write-Host "Running deep interlace/telecine scan..."

        $idet = ffmpeg -hide_banner -nostdin -threads 2 -ss 300 -noaccurate_seek -skip_frame nokey -i "$File" -skip_frame default -filter:v idet -frames:v 1000 -an -f null - 2>&1
        $interlaceMatch  = $idet | Select-String -Pattern "Interlaced:\s*(\d+)" -AllMatches
        $progMatch       = $idet | Select-String -Pattern "Progressive:\s*(\d+)" -AllMatches
        $tffMatch        = $idet | Select-String -Pattern "TFF:\s*(\d+)" -AllMatches
        $bffMatch        = $idet | Select-String -Pattern "BFF:\s*(\d+)" -AllMatches

        $InterlacedCount = if ($interlaceMatch)  { [int]$interlaceMatch.Matches.Groups[1].Value }  else { 0 }
        $ProgressiveCount = if ($progMatch)     { [int]$progMatch.Matches.Groups[1].Value }       else { 0 }
        $TffCount        = if ($tffMatch)       { [int]$tffMatch.Matches.Groups[1].Value }        else { 0 }
        $BffCount        = if ($bffMatch)       { [int]$bffMatch.Matches.Groups[1].Value }        else { 0 }

        if (($TffCount -gt 50 -or $BffCount -gt 50) -and $InterlacedCount -lt 20) {
            $status = "telecine"
        } elseif ($InterlacedCount -gt 50) {
            $status = "interlaced"
        } else {
            $status = "progressive"
        }
    }

    Write-Host "Detected: $status"

    # mov_text -> SRT: MP4 text subtitles cannot be stream-copied into MKV
    $SubArgs = @('-c:s', 'copy')
    if ([System.IO.Path]::GetExtension($File).ToLower() -eq '.mp4') {
        $subInfo = ffprobe -v quiet -print_format json -show_streams "$File" | ConvertFrom-Json
        if ($subInfo.streams | Where-Object { $_.codec_type -eq 'subtitle' -and $_.codec_name -eq 'mov_text' }) {
            Write-Host "Subtitle: mov_text detected in MP4 -- converting to SRT"
            $SubArgs = @('-c:s', 'srt')
        }
    }

    # Wait for job slots
    while ((Get-Job -State Running).Count -ge $MaxJobs) {
        Start-Sleep -Seconds 1
    }

    Write-Host "Processing $File"

    # Start encoding job
    Start-Job -ScriptBlock {
        param($File, $Tmp, $SubArgs, $Status)

        # Clean temp file immediately before ffmpeg runs
        if (Test-Path -LiteralPath $Tmp) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }

        $ffmpegArgs = @('-hide_banner', '-nostdin', '-threads', '2', '-y', '-i', $File)

        $filterGraph = switch ($Status) {
            'interlaced' { "bwdif=mode=send_frame,format=nv12,hwupload" }
            'telecine'   { "pullup,dejudder,format=nv12,hwupload" }
            default      { "scale_qsv=format=nv12" }
        }

        $ffmpegArgs += @('-filter:v', $filterGraph)
        $ffmpegArgs += @('-map', '0:v:0', '-map', '0:a?', '-map', '0:s?', '-map', '-0:v:m:attached_pic')
        $ffmpegArgs += @('-c:v', 'hevc_qsv', '-qp', '28')
        $ffmpegArgs += @('-c:a', 'copy')
        $ffmpegArgs += $SubArgs
        $ffmpegArgs += @('-f', 'matroska')
        $ffmpegArgs += $Tmp

        $p = Start-Process -FilePath 'ffmpeg' -ArgumentList $ffmpegArgs -NoNewWindow -Wait -PassThru
        $ffmpegExitCode = $p.ExitCode

        # Verify output file and is not empty
        if ($ffmpegExitCode -ne 0 -or -not (Test-Path -LiteralPath $Tmp)) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
            return
        }

        $tmpSize = (Get-Item -LiteralPath $Tmp -ErrorAction SilentlyContinue).Length
        if ($tmpSize -eq 0) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
            return
        }

        if ($ffmpegExitCode -eq 0) {
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
                Write-Host "Replaced: ${origMB}MB -> ${newMB}MB"
            } else {
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Skipped: new file not smaller (${origMB}MB -> ${newMB}MB) - creating .skip_<basename> marker"
                $skipFile = Join-Path (Split-Path -LiteralPath $File) ".skip_$([System.IO.Path]::GetFileNameWithoutExtension($File))"
                New-Item -LiteralPath $skipFile -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $Tmp -Force
            }
        } else {
            if (Test-Path -LiteralPath $Tmp) {
                Remove-Item -LiteralPath $Tmp -Force
            }
        }

    } -ArgumentList $File, $Tmp, $SubArgs, $status

}

# Wait for all jobs
Get-Job | Wait-Job | Receive-Job
Get-Job | Remove-Job

# Cleanup all stray [Trans] temp files
Get-ChildItem -Recurse -Filter "*`[Trans`].tmp" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Filter "*`[Trans`].nfo" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Filter "*`[Trans`].jpg" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Filter "*`[Trans`].trickplay" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
