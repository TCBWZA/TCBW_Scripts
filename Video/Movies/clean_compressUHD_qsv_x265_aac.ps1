#!/usr/bin/env pwsh
# Intel QSV H.265 encoder for 4K UHD content with intelligent audio/subtitle filtering
# Optimized for file size while maintaining high-quality 4K streaming

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
        Write-Host "`nCleaning up temp files due to interruption..."
        foreach ($file in $tempFilesToCleanup) {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
Register-EngineEvent PowerShell.Exiting -Action $cleanupTrap | Out-Null

###############################################################
# CONFIGURABLE THRESHOLDS
###############################################################
$MinBitrate = 2500000            # Bitrate threshold (bps) - skip if > this
$MinFileSize = 8                  # Minimum file size (GB) - 4K content typically larger
$MinDiskSpace = 100               # Minimum free disk space (GB) - 4K needs more space

param(
    [int]$MAX_JOBS = 2,
    [bool]$DEBUG = $false
)

$ErrorActionPreference = 'Continue'

Write-Host "Starting up..."
Write-Host "Scanning for files..."

# Find all video files
$files = @(Get-ChildItem -Recurse -File -Include @("*.mkv", "*.mp4", "*.ts"))

Write-Host "Found $($files.Count) files."
Write-Host "Beginning processing..."

$activeJobs = @()

foreach ($f in $files) {
    $sizeGb = [math]::Floor($f.Length / 1GB)
    
    # Skip files smaller than minimum size
    if ($sizeGb -lt $MinFileSize) {
        continue
    }
    
    $baseNoExt = $f.BaseName
    $dir = $f.DirectoryName
    
    # Skip if directory contains .skip file
    $skipFile = Join-Path $dir '.skip'
    if (Test-Path $skipFile) {
        Write-Host "Skipping $($f.FullName) -- .skip file found in directory"
        continue
    }
    
    # Skip and delete cleaned/transcoded files
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Remove-Item -Path $f.FullName -Force
        continue
    }
    
    Write-Host "Checking $($f.FullName)"

    #####################################################
    # Check disk space before processing
    #####################################################
    $drive = $dir -replace '(^[a-zA-Z]).*', '$1'
    $diskInfo = Get-PSDrive -Name $drive[0]
    $freespaceGB = [math]::Floor($diskInfo.Free / 1GB)
    
    if ($freespaceGB -lt $MinDiskSpace) {
        Write-Host "Skipping $($f.FullName) -- insufficient disk space (${freespaceGB}GB free, need ${MinDiskSpace}GB)" -ForegroundColor Yellow
        continue
    }
    
    #####################################################
    # Unified ffprobe JSON
    #####################################################
    
    $probe = & ffprobe -v quiet -print_format json -show_streams $f.FullName | ConvertFrom-Json
    
    $vcodec = ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).codec_name
    $vbitrate = ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).tags.BPS ?? ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).bit_rate ?? 0
    $acodec = ($probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1).codec_name
    $width = ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).width
    
    # Skip AV1 files entirely
    if ($vcodec -eq "av1") {
        Write-Host "Skipping $($f.FullName) -- AV1 detected"
        continue
    }
    
    # Fast checks first, skip expensive detection if already need to convert
    $needsConvert = $false
    if ($acodec -ne "aac") {
        $needsConvert = $true
    }
    if (-not $needsConvert -and $vcodec -ne "hevc") {
        $needsConvert = $true
    }
    if (-not $needsConvert -and $vbitrate -match '^\d+$' -and [int]$vbitrate -gt $MinBitrate) {
        $needsConvert = $true
    }
    
    # For 4K, bitrate threshold for compression - Profile 6.2 standard is ~20 Mbps
    if ($width -ge 3840 -and -not $needsConvert -and $vbitrate -match '^\d+$' -and [int]$vbitrate -gt 20000000) {
        $needsConvert = $true
    }
    
    Write-Host "Detected: 4K/UHD content (progressive, no deinterlacing)"
    
    #####################################################
    # VIDEO CODEC DECISION
    #####################################################
    
    $videoEncode = ""
    $vfChain = ""
    
    # For 4K: Skip interlace detection, always assume progressive
    if ($vcodec -eq "hevc" -and $vbitrate -match '^\d+$' -and [int]$vbitrate -le 3500000) {
        $videoEncode = "-c:v copy"
        Write-Host "Video codec is x265 and within bitrate limits: copying"
        $vfChain = ""
    }
    else {
        # QP 24 with profile 6.2 for constant quality UHD encoding
        $videoEncode = "-c:v hevc_qsv -qp 24 -level 62 -load_plugin hevc_hw -preset slow"
        Write-Host "Video codec is not x265 or exceeds bitrate limits: encoding 4K with constant quality (QP 24, profile 6.2)"
        $vfChain = ""
    }
    
    #####################################################
    # AUDIO AND SUBTITLE TRACK ANALYSIS
    #####################################################
    
    $audioCount = ($probe.streams | Where-Object { $_.codec_type -eq "audio" }).Count
    $subtitleCount = ($probe.streams | Where-Object { $_.codec_type -eq "subtitle" }).Count
    
    Write-Host "Found $audioCount audio track(s) and $subtitleCount subtitle track(s)"
    
    # Build audio stream mapping (as array)
    $audioMapArgs = @()
    $hasVideoMap = $false
    
    if ($audioCount -eq 1) {
        # Single audio track: copy it
        $audioMapArgs = @("-map", "0:v:0", "-c:a", "copy")
        $hasVideoMap = $true
        Write-Host "  → Single audio track: copying as-is"
    }
    elseif ($audioCount -gt 1) {
        # Multiple audio tracks: look for English first
        $englishAudio = @($probe.streams | 
            Where-Object { $_.codec_type -eq "audio" } |
            Where-Object { 
                $_.tags.language -eq "eng" -or 
                $_.tags.language -eq "en" -or 
                ($_.tags.title -and $_.tags.title -like "*English*")
            } |
            Select-Object -ExpandProperty index)
        
        # Also get unknown/null language streams
        $unknownAudio = @($probe.streams |
            Where-Object { $_.codec_type -eq "audio" } |
            Where-Object { $null -eq $_.tags.language -or $_.tags.language -eq "und" } |
            Select-Object -ExpandProperty index)
        
        # Combine: English + unknown/null
        $allAudio = $englishAudio + $unknownAudio
        
        if ($DEBUG) {
            Write-Host "  DEBUG: Found English audio indices: '$($englishAudio -join ', ')'"
            Write-Host "  DEBUG: Found unknown/null audio indices: '$($unknownAudio -join ', ')'"
        }
        
        if ($allAudio.Count -gt 0) {
            # Build -map commands for all matched audio tracks using STREAM indices
            $audioMapArgs = @("-map", "0:v:0", "-c:a", "copy")
            $hasVideoMap = $true
            foreach ($idx in $allAudio) {
                $audioMapArgs += @("-map", "0:$idx")
            }
            Write-Host "  → Multiple audio tracks: keeping English/unknown tracks"
            if ($DEBUG) {
                Write-Host "  DEBUG: Audio map args: $($audioMapArgs -join ' ')"
            }
        }
        else {
            # No English or unknown found, map first audio explicitly
            $firstAudioIdx = ($probe.streams | 
                Where-Object { $_.codec_type -eq "audio" } |
                Select-Object -First 1).index
            $firstAudioLang = ($probe.streams |
                Where-Object { $_.codec_type -eq "audio" -and $_.index -eq $firstAudioIdx } |
                Select-Object -ExpandProperty tags).language ?? "unknown"
            $audioMapArgs = @("-map", "0:v:0", "-map", "0:$firstAudioIdx", "-c:a", "copy")
            $hasVideoMap = $true
            Write-Host "  → No English/unknown audio found, keeping first audio stream $firstAudioIdx ($firstAudioLang)"
        }
    }
    else {
        # No audio tracks
        $audioMapArgs = @("-map", "0:v:0")
        $hasVideoMap = $true
        Write-Host "  → No audio tracks"
    }
    
    # Build subtitle stream mapping (as array)
    $subtitleMapArgs = @()
    if ($subtitleCount -eq 1) {
        # Single subtitle: copy it
        $subtitleIdx = ($probe.streams | Where-Object { $_.codec_type -eq "subtitle" } | Select-Object -First 1).index
        if (-not $hasVideoMap) {
            $subtitleMapArgs = @("-map", "0:v:0", "-map", "0:$subtitleIdx", "-c:s", "copy")
        }
        else {
            $subtitleMapArgs = @("-map", "0:$subtitleIdx", "-c:s", "copy")
        }
        Write-Host "  → Single subtitle track: copying as-is"
    }
    elseif ($subtitleCount -gt 1) {
        # Multiple subtitles: look for English first
        $englishSubs = @($probe.streams |
            Where-Object { $_.codec_type -eq "subtitle" } |
            Where-Object {
                $_.tags.language -eq "eng" -or
                $_.tags.language -eq "en" -or
                ($_.tags.title -and $_.tags.title -like "*English*")
            } |
            Select-Object -ExpandProperty index)
        
        # Also get unknown/null language streams
        $unknownSubs = @($probe.streams |
            Where-Object { $_.codec_type -eq "subtitle" } |
            Where-Object { $null -eq $_.tags.language -or $_.tags.language -eq "und" } |
            Select-Object -ExpandProperty index)
        
        # Combine: English + unknown/null
        $allSubs = $englishSubs + $unknownSubs
        
        if ($DEBUG) {
            Write-Host "  DEBUG: Found English subtitle indices: '$($englishSubs -join ', ')'"
            Write-Host "  DEBUG: Found unknown/null subtitle indices: '$($unknownSubs -join ', ')'"
        }
        
        if ($allSubs.Count -gt 0) {
            # Only add -map 0:v:0 if not already added by audio mapping
            if (-not $hasVideoMap) {
                $subtitleMapArgs = @("-map", "0:v:0", "-c:s", "copy")
            }
            else {
                $subtitleMapArgs = @("-c:s", "copy")
            }
            foreach ($idx in $allSubs) {
                $subtitleMapArgs += @("-map", "0:$idx")
            }
            Write-Host "  → Multiple subtitle tracks: keeping English/unknown tracks"
            if ($DEBUG) {
                Write-Host "  DEBUG: Subtitle map args: $($subtitleMapArgs -join ' ')"
            }
        }
        else {
            Write-Host "  → No English/unknown subtitles found"
            $subtitleMapArgs = @()
        }
    }
    else {
        # No subtitles
        $subtitleMapArgs = @()
        Write-Host "  → No subtitle tracks"
    }
    
    # Check if any conversion is actually needed
    if (-not $needsConvert -and 
        (($audioMapArgs.Count -eq 0) -or ($audioMapArgs.Count -eq 2 -and $audioMapArgs[0] -eq "-c:a" -and $audioMapArgs[1] -eq "copy")) -and
        (($subtitleMapArgs.Count -eq 0) -or ($subtitleMapArgs.Count -eq 2 -and $subtitleMapArgs[0] -eq "-c:s" -and $subtitleMapArgs[1] -eq "copy"))) {
        Write-Host "Skipping $($f.FullName) -- already in desired format"
        continue
    }
    
    #####################################################
    # Transcoding section
    #####################################################
    
    $tmpfile = Join-Path $dir "$baseNoExt[Cleaned].tmp"
    $tempFilesToCleanup += $tmpfile

    Write-Host "Input         : $($f.FullName)"
    Write-Host "Temp Out      : $tmpfile"
    
    if (Test-Path $tmpfile) {
        Remove-Item -Path $tmpfile -Force
    }
    
    # Build FFmpeg command arguments
    $ffmpegArgs = @("-nostdin", "-hide_banner")
    
    if ([string]::IsNullOrEmpty($vfChain)) {
        # No video filter (video is being copied or already progressive)
        $ffmpegArgs += @("-i", $f.FullName, "-copyts") + $videoEncode.Split() + $audioMapArgs + $subtitleMapArgs + @("-f", "matroska", $tmpfile)
    }
    else {
        # Video filter chain needed
        $ffmpegArgs += @("-init_hw_device", "qsv=hw", "-hwaccel", "qsv", "-hwaccel_output_format", "qsv",
                        "-i", $f.FullName, "-copyts", "-fflags", "+genpts", "-fps_mode", "passthrough",
                        "-vf", $vfChain) + $videoEncode.Split() + $audioMapArgs + $subtitleMapArgs + @("-f", "matroska", $tmpfile)
    }
    
    if ($DEBUG) {
        Write-Host "  DEBUG: FFmpeg command: ffmpeg $($ffmpegArgs -join ' ')"
    }
    
    # Start transcoding in background job
    $job = Start-Job -ScriptBlock {
        param($ffmpegArgs, $tmpfile, $originalFile)
        
        # Clean up temp file immediately before ffmpeg runs
        if (Test-Path -LiteralPath $tmpfile) {
            Remove-Item -LiteralPath $tmpfile -Force -ErrorAction SilentlyContinue
        }
        
        Write-Host "[JOB] Starting ffmpeg transcoding..."
        & ffmpeg @ffmpegArgs 2>&1
        $ffmpegExitCode = $LASTEXITCODE
        Write-Host "[JOB] FFmpeg exit code: $ffmpegExitCode"
        
        # Verify output file exists and is not empty
        if ($ffmpegExitCode -ne 0 -or -not (Test-Path -LiteralPath $tmpfile)) {
            Write-Host "[JOB] ERROR: FFmpeg failed or output file not created"
            Remove-Item -LiteralPath $tmpfile -Force -ErrorAction SilentlyContinue
            return
        }
        
        if ($ffmpegExitCode -eq 0) {
            # Check if the transcoded file is valid (not 0 bytes)
            $newSize = (Get-Item -LiteralPath $tmpfile -ErrorAction SilentlyContinue).Length
            if ($newSize -eq 0) {
                Write-Host "[JOB] ERROR: Output file is empty (0 bytes), removing and returning"
                Remove-Item -LiteralPath $tmpfile -Force -ErrorAction SilentlyContinue
                return
            }
            
            # Only replace original if new file is smaller
            $origFile = Get-Item $originalFile
            $origSize = $origFile.Length
            
            if ($newSize -lt $origSize) {
                $origTime = $origFile.LastWriteTime
                # Use original basename with .mkv extension (output format is always matroska)
                $finalFile = Join-Path (Split-Path -LiteralPath $originalFile) "$((Get-Item $originalFile).BaseName).mkv"
                Move-Item -Path $tmpfile -Destination $finalFile -Force
                (Get-Item $finalFile).LastWriteTime = $origTime
                Get-Item $finalFile | Set-ItemProperty -Name Attributes -Value (Get-Item $finalFile).Attributes -PassThru | Out-Null
                Remove-Item -Path $originalFile -Force -ErrorAction SilentlyContinue
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
            }
            else {
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip file"
                $skipFile = Join-Path (Split-Path -Path $originalFile) '.skip'
                New-Item -Path $skipFile -ItemType File -Force | Out-Null
                Remove-Item -Path $tmpfile -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Remove-Item -Path $tmpfile -Force -ErrorAction SilentlyContinue
        }
    } -ArgumentList $ffmpegArgs, $tmpfile, $f.FullName
    
    $activeJobs += $job
    
    #####################################################
    # Job management (max 2 concurrent)
    #####################################################
    
    while ($activeJobs.Count -ge $MAX_JOBS) {
        $completed = $activeJobs | Wait-Job -Any
        $activeJobs = $activeJobs | Where-Object { $_.Id -ne $completed.Id }
        Receive-Job -Job $completed -ErrorAction SilentlyContinue
        Remove-Job -Job $completed
    }
}

# Wait for all remaining jobs to complete
Write-Host "Waiting for $($activeJobs.Count) remaining job(s)..."
$activeJobs | ForEach-Object {
    $jobOutput = Receive-Job -Job $_ -Wait
    if ($jobOutput) {
        Write-Host $jobOutput
    }
    Remove-Job -Job $_
}
Write-Host "All jobs completed."

#####################################################
# Final check: Remove any remaining [Cleaned]/[Trans] files
#####################################################

Write-Host "Running final check for leftover [Cleaned] and [Trans] video files..."

Get-ChildItem -Recurse -File -Include @("*.mkv", "*.mp4", "*.ts") | Where-Object {
    $_.BaseName -match '\[Cleaned\]|\[Trans\]'
} | ForEach-Object {
    Write-Host "Removing leftover: $($_.FullName)"
    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
}

#####################################################
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

Write-Host "All tasks complete."
