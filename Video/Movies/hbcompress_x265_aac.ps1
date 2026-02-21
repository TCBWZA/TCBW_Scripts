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
        $deinterlace = "--deinterlace"
    } else {
        $deinterlace = ""
    }

    # Wait for job slots
    while ((Get-Job -State Running).Count -ge $MaxJobs) {
        Start-Sleep -Seconds 1
    }

    Write-Host "Processing $File"
    # Start encoding job
    Start-Job -ScriptBlock {
        param($File, $Tmp, $deinterlace)
         
        # Clean temp file immediately before HandBrake runs
        if (Test-Path -LiteralPath $Tmp) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
        }

        # Construct Handbrake command with optional deinterlace
        if ([string]::IsNullOrEmpty($deinterlace)) {
            & HandBrakeCLI `
                -i "$File" `
                -o "$Tmp" `
                -f mkv `
                -e hevc_qsv `
                -q 20 `
                -a 1 `
                -E aac `
                -B 160 `
                --all-subtitles `
                --all-audio
        } else {
            & HandBrakeCLI `
                -i "$File" `
                -o "$Tmp" `
                -f mkv `
                -e hevc_qsv `
                -q 20 `
                -a 1 `
                -E aac `
                -B 160 `
                --all-subtitles `
                --all-audio `
                $deinterlace
        }
        
        $hbExitCode = $LASTEXITCODE
        
        # Verify output file and is not empty
        if ($hbExitCode -ne 0 -or -not (Test-Path -LiteralPath $Tmp)) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
            return
        }
        
        $tmpSize = (Get-Item -LiteralPath $Tmp -ErrorAction SilentlyContinue).Length
        if ($tmpSize -eq 0) {
            Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
            return
        }

        if ($hbExitCode -eq 0) {
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

    } -ArgumentList $File, $Tmp, $deinterlace

}

# Wait for all jobs
Get-Job | Wait-Job | Receive-Job
Get-Job | Remove-Job

# Cleanup all [Cleaned] and [Trans] files
Write-Host "Cleaning up all [Cleaned] and [Trans] files and directories..."

Get-ChildItem -Recurse -Include "*[Cleaned].*" -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Directory -Include "*[Cleaned].trickplay" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Include "*[Trans].*" -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Directory -Include "*[Trans].trickplay" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Cleanup complete."
