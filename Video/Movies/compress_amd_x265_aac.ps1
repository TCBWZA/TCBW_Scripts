<#
.SYNOPSIS
    Batch compresses movie MKV files using AMD GPU hardware acceleration.

.DESCRIPTION
    Recursively scans the current directory for MKV files 5 GB or larger and
    re-encodes files that are not already HEVC+AAC or exceed 2.5 Mbps video
    bitrate. Encoding uses AMD hevc_amf via dxva2 hardware acceleration.
    Interlace detection is performed with ffprobe/idet. The original file is
    replaced only when the new file is smaller. Up to $MaxJobs parallel encoding
    jobs run at once.

.NOTES
    - Edit $MaxJobs at the top of the script.
    - Requires ffmpeg and ffprobe on PATH.
    - Requires an AMD GPU with AMF/VCE support.
    - Files tagged [Cleaned] or [Trans] are deleted automatically.
    - A .skip directory marker skips the entire folder. A .skip_<basename> per-file marker skips that specific file.
    - A .skip_<basename> marker is created automatically when output is not smaller.

.PARAMETER Debug
    Enable verbose debug output.

.EXAMPLE
    Set-Location "Z:\Media\Movies"
    .\compress_amd_x265_aac.ps1
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

$MaxJobs = 2

Get-ChildItem -Recurse -Filter *.mkv | ForEach-Object {

    $File = $_.FullName
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($File)
    $Dir  = $_.DirectoryName

    # Skip cleaned/transcoded files 
    if ($Base.Contains("[Cleaned]") -or $Base.Contains("[Trans]")) {
        Remove-Item -LiteralPath $File -Force
        return
    }

    # Skip small files (<5GB)
    if ($_.Length -lt 5GB) {
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

    if (-not $NeedsConvert) {
        Write-Host "Skipping $File -- already in desired format"
        return
    }

    # Temp output
    $Tmp = Join-Path $Dir "$Base`[Trans`].tmp"

    if (Test-Path $Tmp) { Remove-Item $Tmp -Force }

    # Detect interlacing using idet
    $idet = ffmpeg -hide_banner -ss 300 -filter:v idet -frames:v 200 -an -f null - "$File" 2>&1
    $interlaceMatch = $idet | Select-String -Pattern "Interlaced:\s*(\d+)" -AllMatches
    $InterlacedCount = if ($interlaceMatch) { [int]$interlaceMatch.Matches.Groups[1].Value } else { 0 }

    if ([int]$InterlacedCount -gt 0) {
        $vf = "yadif"   # AMD has no hardware deinterlacer
    } else {
        $vf = ""
    }

    # Wait for job slots
    while ((Get-Job -State Running).Count -ge $MaxJobs) {
        Start-Sleep -Seconds 1
    }

    Write-Host "Processing $File"

    # Start encoding job
    Start-Job -ScriptBlock {
        param($File, $Tmp, $vf)
         
        if (Test-Path -LiteralPath $Tmp) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }

        if ([string]::IsNullOrEmpty($vf)) {
            ffmpeg -hide_banner `
                -hwaccel dxva2 `
                -i "$File" `
                -c:v hevc_amf `
                -b:v 1800k -maxrate 2000k -bufsize 4000k `
                -c:a aac -b:a 160k `
                -c:s copy `
                -f matroska `
                "$Tmp"
        } else {
            ffmpeg -hide_banner `
                -hwaccel dxva2 `
                -i "$File" `
                -vf "$vf" `
                -c:v hevc_amf `
                -b:v 1800k -maxrate 2000k -bufsize 4000k `
                -c:a aac -b:a 160k `
                -c:s copy `
                -f matroska `
                "$Tmp"
        }
        
        $ffmpegExitCode = $LASTEXITCODE
        
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
                Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
            }
            else {
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip_<basename> marker"
                $skipFile = Join-Path (Split-Path -LiteralPath $File) ".skip_$([System.IO.Path]::GetFileNameWithoutExtension($File))"
                New-Item -LiteralPath $skipFile -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $Tmp -Force
            }
        } else {
            if (Test-Path -LiteralPath $Tmp) {
                Remove-Item -LiteralPath $Tmp -Force
            }
        }

    } -ArgumentList $File, $Tmp, $vf

}

# Wait for all jobs
Get-Job | Wait-Job | Receive-Job
Get-Job | Remove-Job

# Cleanup all stray [Trans] temp files
Get-ChildItem -Recurse -Filter "*`[Trans`].tmp" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Filter "*`[Trans`].nfo" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Filter "*`[Trans`].jpg" | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Filter "*`[Trans`].trickplay" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
