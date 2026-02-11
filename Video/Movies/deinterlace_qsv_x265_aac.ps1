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

    $NeedsConvert = $false

    if ($vcodec -ne "hevc") { $NeedsConvert = $true }
    if ([int]$vbitrate -gt 2500000) { $NeedsConvert = $true }
    if ($acodec -ne "aac") { $NeedsConvert = $true }
    if ($field -ne "progressive") { $NeedsConvert = $true }

    if (-not $NeedsConvert) {
        Write-Host "Skipping $File -- already in desired format"
        return
    }

    # Temp output
    $Tmp = Join-Path $Dir "$Base`[Trans`].tmp"

    if (Test-Path $Tmp) { Remove-Item $Tmp -Force }

    # Detect interlacing using idet
    $idet = ffmpeg -hide_banner -filter:v idet -frames:v 500 -an -f null - "$File" 2>&1
    $InterlacedCount = ($idet | Select-String -Pattern "Interlaced:\s*(\d+)" -AllMatches).Matches.Groups[1].Value

    if ([int]$InterlacedCount -gt 0) {
        $vf = "deinterlace_qsv"
    } else {
        $vf = "format=qsv"
    }

    # Wait for job slots
    while ((Get-Job -State Running).Count -ge $MaxJobs) {
        Start-Sleep -Seconds 1
    }

    Write-Host "Processing $File"
    # Start encoding job
    Start-Job -ScriptBlock {
        param($File, $Tmp, $vf)

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
            # Replace original
                $timestamp = (Get-Item -LiteralPath $File).LastWriteTime
                Remove-Item -LiteralPath $File -Force
                Move-Item -LiteralPath $Tmp -Destination $File -Force
                (Get-Item -LiteralPath $File).LastWriteTime = $timestamp
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

# Cleanup stray temp files
Get-ChildItem -Recurse -Filter "*`[Trans`].tmp" | Remove-Item -Force
Get-ChildItem -Recurse -Filter "*`[Trans`].nfo" | Remove-Item -Force
Get-ChildItem -Recurse -Filter "*`[Trans`].jpg" | Remove-Item -Force
Get-ChildItem -Recurse -Filter "*`[Trans`].trickplay" | Remove-Item -Recurse -Force
