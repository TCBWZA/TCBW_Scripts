<#
.SYNOPSIS
    Batch compresses movie MKV files using Intel Quick Sync Video (QSV).

.DESCRIPTION
    Recursively scans the current directory for MKV and TS files 5 GB or larger
    and re-encodes files that are not already HEVC+AAC or exceed 2.5 Mbps video
    bitrate. Encoding uses hevc_qsv via Intel Quick Sync hardware acceleration.
    Interlace detection is performed with ffprobe/idet. The original file is
    replaced only when the new file is smaller. Up to $MaxJobs parallel encoding
    jobs run at once.

.NOTES
    - Edit $MaxJobs and $TempDir at the top of the script.
    - Requires ffmpeg and ffprobe on PATH.
    - Requires an Intel CPU or GPU with Quick Sync Video support.
    - Files tagged [Cleaned] or [Trans] are deleted automatically.
    - A .skip_<basename> marker is created when output is not smaller.

.PARAMETER Debug
    Enable verbose debug output.

.EXAMPLE
    Set-Location "Z:\Media\Movies"
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

    # Detect interlacing using idet, skipping first 5 minutes to avoid credits/intros, then check 200 frames, skipping first 5 minutes and checking 200 frames
    $idet = ffmpeg -hide_banner -ss 300 -filter:v idet -frames:v 200 -an -f null - "$File" 2>&1
    $interlaceMatch = $idet | Select-String -Pattern "Interlaced:\s*(\d+)" -AllMatches
    $InterlacedCount = if ($interlaceMatch) { [int]$interlaceMatch.Matches.Groups[1].Value } else { 0 }

    if ([int]$InterlacedCount -gt 0) {
        $vf = "deinterlace_qsv"
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
         
        # Clean temp file immediately before ffmpeg runs
        if (Test-Path -LiteralPath $Tmp) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }

        if ([string]::IsNullOrEmpty($vf)) {
            ffmpeg -hide_banner `
                -hwaccel qsv -hwaccel_output_format qsv `
                -i "$File" `
                -c:v hevc_qsv `
                -b:v 1800k -maxrate 2000k -bufsize 4000k `
                -c:a aac -b:a 160k `
                -c:s copy `
                -f matroska `
                "$Tmp"
        } else {
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
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip file"
                $skipFile = Join-Path (Split-Path -LiteralPath $File) '.skip'
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
