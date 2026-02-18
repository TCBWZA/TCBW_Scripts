# Requires PowerShell 7+

$ErrorActionPreference = "Stop"

Register-EngineEvent PowerShell.Exiting -Action {
    Write-Host "Interrupted -- exiting safely"
}

$MAX_JOBS = 2

Write-Host "Starting up..."
Write-Host "Scanning for files..."

# Find all video files
$files = Get-ChildItem -Recurse -File -Include *.mkv, *.mp4, *.ts

Write-Host "Found $($files.Count) files."
Write-Host "Beginning processing..."

$jobs = @()

foreach ($f in $files) {

    # File size in GB
    $sizeGB = [math]::Floor($f.Length / 1GB)
    if ($sizeGB -lt 1) { continue }

    $basename = $f.BaseName
    $dir = $f.DirectoryName
    $baseNoExt = $basename

    # Extract show name (first word) for hierarchical skip markers
    $show_name = ($basename -split '\s+')[0]
    $show_skip_file = Join-Path $dir ".skip_$show_name"
    $parent_skip_file = Join-Path (Split-Path -LiteralPath $dir) ".skip"

    # Check for skip markers
    if (Test-Path -LiteralPath $parent_skip_file) {
        Write-Host "Skipping $($f.FullName) -- parent directory marked as done"
        continue
    }
    if (Test-Path -LiteralPath $show_skip_file) {
        Write-Host "Skipping $($f.FullName) -- show marked as uncompressible"
        continue
    }

    # Skip and delete cleaned/transcoded files
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Remove-Item -LiteralPath $f.FullName -Force
        continue
    }

    Write-Host "Checking $($f.FullName)"

    #####################################################
    # ffprobe JSON
    #####################################################

    $probeJson = ffprobe -v quiet -print_format json -show_streams $f.FullName
    $probe = $probeJson | ConvertFrom-Json

    $videoStream = $probe.streams | Where-Object { $_.codec_type -eq "video" }
    $audioStream = $probe.streams | Where-Object { $_.codec_type -eq "audio" }

    $vcodec = $videoStream.codec_name
    $vbitrate = [int]$videoStream.bit_rate
    $acodec = $audioStream.codec_name

    # Fast checks first, skip redundant checks once true
    $needs_convert = $false
    if ($acodec -ne "aac") { $needs_convert = $true }
    if (-not $needs_convert -and $vcodec -ne "hevc") { $needs_convert = $true }
    if (-not $needs_convert -and $vbitrate -gt 2500000) { $needs_convert = $true }

    if (-not $needs_convert) {
        Write-Host "Skipping $($f.FullName) -- already in desired format"
        continue
    }

    #####################################################
    # Transcoding section (HandBrakeCLI)
    #####################################################

    $tmpfile = Join-Path $dir "$baseNoExt`[Trans].tmp.mkv"

    Write-Host "Input    : $($f.FullName)"
    Write-Host "Temp Out : $tmpfile"

    if (Test-Path -LiteralPath $tmpfile) {
        Remove-Item -LiteralPath $tmpfile -Force
    }

    # Always apply decomb
    $hb_filter = "--decomb"

    #####################################################
    # Run HandBrake in background job
    #####################################################

    $jobs += Start-Job -ScriptBlock {
        param($inputFile, $tmpFile, $hbFilter)

        HandBrakeCLI `
            --input $inputFile `
            --output $tmpFile `
            --format mkv `
            --encoder qsv_h265 `
            --encoder-preset balanced `
            --quality 24 `
            --maxHeight 2160 `
            --aencoder av_aac `
            --ab 160 `
            --mixdown stereo `
            --subtitle copy `
            $hbFilter

        if ($LASTEXITCODE -eq 0) {
            # Only replace original if new file is smaller
            $orig = Get-Item -LiteralPath $inputFile
            $origSize = $orig.Length
            $newSize = (Get-Item -LiteralPath $tmpFile).Length
            
            if ($newSize -lt $origSize) {
                Set-ItemProperty -LiteralPath $tmpFile -Name LastWriteTime -Value $orig.LastWriteTime
                Remove-Item -LiteralPath $inputFile -Force
                Move-Item -LiteralPath $tmpFile -Destination $inputFile -Force
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
            }
            else {
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip_$show_name"
                New-Item -Path $show_skip_file -ItemType File -Force | Out-Null
                Remove-Item -LiteralPath $tmpFile -Force
            }
        }
        else {
            Remove-Item -LiteralPath $tmpFile -Force
        }

    } -ArgumentList $f.FullName, $tmpfile, $hb_filter

    #####################################################
    # Parallel job control
    #####################################################

    while (($jobs | Where-Object { $_.State -eq "Running" }).Count -ge $MAX_JOBS) {
        Receive-Job -Wait -AutoRemoveJob | Out-Null
    }
}

# Wait for all jobs to finish
$jobs | Wait-Job | Receive-Job | Out-Null

#####################################################
# Cleanup section
#####################################################

Write-Host "Cleaning up leftover [Trans] files..."

# Files
Get-ChildItem -Recurse -File |
    Where-Object {
        $_.Name -match '\[Trans\]\.tmp' -or
        $_.Name -match '\[Trans\]\.nfo' -or
        $_.Name -match '\[Trans\]\.jpg'
    } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
    }

# Directories
Get-ChildItem -Recurse -Directory |
    Where-Object { $_.Name -match '\[Trans\]\.trickplay' } |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
        } 

        Write-Host "All tasks complete."