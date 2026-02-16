#!/usr/bin/env pwsh
# Intel QSV H.265 encoder with intelligent audio/subtitle filtering

param(
    [int]$MAX_JOBS = 2
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
    
    # Skip files smaller than 5GB
    if ($sizeGb -lt 5) {
        continue
    }
    
    $baseNoExt = $f.BaseName
    $dir = $f.DirectoryName
    
    # Skip and delete cleaned/transcoded files
    if ($baseNoExt -match '\[Cleaned\]|\[Trans\]') {
        Remove-Item -Path $f.FullName -Force
        continue
    }
    
    Write-Host "Checking $($f.FullName)"
    
    #####################################################
    # Unified ffprobe JSON
    #####################################################
    
    $probe = & ffprobe -v quiet -print_format json -show_streams $f.FullName | ConvertFrom-Json
    
    $vcodec = ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).codec_name
    $vbitrate = ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).tags.BPS ?? ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).bit_rate ?? 0
    $acodec = ($probe.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1).codec_name
    $fieldOrder = ($probe.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1).field_order
    
    $needsConvert = $false
    
    if ($vcodec -ne "hevc") {
        $needsConvert = $true
    }
    if ($vbitrate -match '^\d+$' -and [int]$vbitrate -gt 2500000) {
        $needsConvert = $true
    }
    if ($acodec -ne "aac") {
        $needsConvert = $true
    }
    
    #####################################################
    # TELECINE + INTERLACE DETECTION (check first!)
    #####################################################
    
    $status = "progressive"
    
    # Quick check: if field_order explicitly indicates interlaced
    if ($fieldOrder -match '^(tt|bb|tb|bt)$') {
        $status = "interlaced"
    }
    # Otherwise, run deep scan unless explicitly progressive
    elseif ($fieldOrder -ne "progressive") {
        Write-Host "Running deep scan for interlace/telecine..."
        
        # Detect interlaced frames using idet filter
        $idetOutput = & ffmpeg -nostdin -hide_banner -skip_frame nokey -filter:v idet -frames:v 200 -an -f null - $f.FullName 2>&1
        $interlacedCount = [regex]::Match($idetOutput -join "`n", 'Interlaced:\s*(\d+)').Groups[1].Value
        if ([string]::IsNullOrEmpty($interlacedCount)) { $interlacedCount = 0 }
        
        # Detect telecine via repeat_pict
        $repeatPictOutput = & ffprobe -v error -select_streams v:0 -show_frames -read_intervals "%+#300" -show_entries frame=repeat_pict -of csv=p=0 $f.FullName 2>$null
        $telecineFlag = ($repeatPictOutput | Select-String '1' -MaxMatches 1)
        
        if ([int]$interlacedCount -gt 0) {
            $status = "interlaced"
        }
        elseif ($null -ne $telecineFlag) {
            $status = "telecine"
        }
        else {
            $status = "progressive"
        }
    }
    
    Write-Host "Detected: $status"
    
    # Interlaced or telecine ALWAYS requires conversion
    if ($status -ne "progressive") {
        $needsConvert = $true
    }
    
    #####################################################
    # VIDEO CODEC DECISION
    #####################################################
    
    $videoEncode = ""
    $vfChain = ""
    
    # If interlaced/telecine, must encode; otherwise check if we can copy
    if ($status -ne "progressive") {
        $videoEncode = "-c:v hevc_qsv -qp 24 -load_plugin hevc_hw -b:v 1800k -maxrate 2000k -bufsize 4000k"
        Write-Host "Interlaced/telecine detected: will encode video"
        $vfChain = ""
    }
    elseif ($vcodec -eq "hevc" -and $vbitrate -match '^\d+$' -and [int]$vbitrate -le 2500000) {
        $videoEncode = "-c:v copy"
        Write-Host "Video codec is x265 and within bitrate limits: copying"
        $vfChain = ""
    }
    else {
        $videoEncode = "-c:v hevc_qsv -qp 24 -load_plugin hevc_hw -b:v 1800k -maxrate 2000k -bufsize 4000k"
        Write-Host "Video codec is not x265 or exceeds bitrate limits: encoding"
        $vfChain = ""
    }
    
    #####################################################
    # FILTER CHAIN SELECTION (only if not copying video)
    #####################################################
    
    if ($videoEncode -ne "-c:v copy") {
        switch ($status) {
            "interlaced" {
                Write-Host "Using bwdif (interlaced)"
                $vfChain = "hwdownload,format=yuv420p,bwdif=mode=send_frame,format=nv12,hwupload"
            }
            "telecine" {
                Write-Host "Using fieldmatch+decimate+bwdif (telecine)"
                $vfChain = "hwdownload,format=yuv420p,fieldmatch,decimate,bwdif=mode=send_frame,format=nv12,hwupload"
            }
            "progressive" {
                Write-Host "Progressive -- no deinterlace"
                $vfChain = "hwdownload,format=yuv420p,format=nv12,hwupload"
            }
        }
    }
    
    #####################################################
    # AUDIO AND SUBTITLE TRACK ANALYSIS
    #####################################################
    
    $audioCount = ($probe.streams | Where-Object { $_.codec_type -eq "audio" }).Count
    $subtitleCount = ($probe.streams | Where-Object { $_.codec_type -eq "subtitle" }).Count
    
    Write-Host "Found $audioCount audio track(s) and $subtitleCount subtitle track(s)"
    
    # Build audio stream mapping (as array)
    $audioMapArgs = @()
    if ($audioCount -eq 1) {
        # Single audio track: copy it
        $audioMapArgs = @("-c:a", "copy")
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
        
        # Write-Host "  DEBUG: Found English audio indices: '$($englishAudio -join ', ')'"
        # Write-Host "  DEBUG: Found unknown/null audio indices: '$($unknownAudio -join ', ')'"
        
        if ($allAudio.Count -gt 0) {
            # Build -map commands for all matched audio tracks using STREAM indices
            $audioMapArgs = @("-map", "0:v:0", "-c:a", "copy")
            foreach ($idx in $allAudio) {
                $audioMapArgs += @("-map", "0:$idx")
            }
            Write-Host "  → Multiple audio tracks: keeping English/unknown tracks"
            Write-Host "  DEBUG: Audio map args: $($audioMapArgs -join ' ')"
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
            Write-Host "  → No English/unknown audio found, keeping first audio stream $firstAudioIdx ($firstAudioLang)"
        }
    }
    else {
        # No audio tracks
        $audioMapArgs = @()
        Write-Host "  → No audio tracks"
    }
    
    # Build subtitle stream mapping (as array)
    $subtitleMapArgs = @()
    if ($subtitleCount -eq 1) {
        # Single subtitle: copy it
        $subtitleIdx = ($probe.streams | Where-Object { $_.codec_type -eq "subtitle" } | Select-Object -First 1).index
        if ($audioMapArgs -notcontains "-map 0:v:0") {
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
        
        Write-Host "  DEBUG: Found English subtitle indices: '$($englishSubs -join ', ')'"
        Write-Host "  DEBUG: Found unknown/null subtitle indices: '$($unknownSubs -join ', ')'"
        
        if ($allSubs.Count -gt 0) {
            # MUST include -map 0:v:0 when using explicit -map for subtitles (v:0 skips attached pics)
            # Only add it if audio_map doesn't already have it
            if ($audioMapArgs -notcontains "-map 0:v:0") {
                $subtitleMapArgs = @("-map", "0:v:0", "-c:s", "copy")
            }
            else {
                $subtitleMapArgs = @("-c:s", "copy")
            }
            foreach ($idx in $allSubs) {
                $subtitleMapArgs += @("-map", "0:$idx")
            }
            Write-Host "  → Multiple subtitle tracks: keeping English/unknown tracks"
            Write-Host "  DEBUG: Subtitle map args: $($subtitleMapArgs -join ' ')"
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
    
    Write-Host "Input         : $($f.FullName)"
    Write-Host "Temp Out      : $tmpfile"
    
    if (Test-Path $tmpfile) {
        Remove-Item -Path $tmpfile -Force
    }
    
    # Build FFmpeg command arguments
    $ffmpegArgs = @("-nostdin", "-hide_banner")
    
    if ([string]::IsNullOrEmpty($vfChain)) {
        # No video filter (video is being copied)
        $ffmpegArgs += @("-i", $f.FullName, "-copyts") + $videoEncode.Split() + $audioMapArgs + $subtitleMapArgs + @("-f", "matroska", $tmpfile)
    }
    else {
        # Video filter chain needed
        $ffmpegArgs += @("-init_hw_device", "qsv=hw", "-hwaccel", "qsv", "-hwaccel_output_format", "qsv",
                        "-i", $f.FullName, "-copyts", "-fflags", "+genpts", "-fps_mode", "passthrough",
                        "-vf", $vfChain) + $videoEncode.Split() + $audioMapArgs + $subtitleMapArgs + @("-f", "matroska", $tmpfile)
    }
    
    Write-Host "  DEBUG: FFmpeg command: ffmpeg $($ffmpegArgs -join ' ')"
    
    # Start transcoding in background job
    $job = Start-Job -ScriptBlock {
        param($ffmpegArgs, $tmpfile, $originalFile)
        
        & ffmpeg $ffmpegArgs
        
        if ($LASTEXITCODE -eq 0) {
            # Only replace original if new file is smaller
            $origFile = Get-Item $originalFile
            $origSize = $origFile.Length
            $newSize = (Get-Item $tmpfile).Length
            
            if ($newSize -lt $origSize) {
                $origTime = $origFile.LastWriteTime
                Move-Item -Path $tmpfile -Destination $originalFile -Force
                (Get-Item $originalFile).LastWriteTime = $origTime
                Get-Item $originalFile | Set-ItemProperty -Name Attributes -Value (Get-Item $originalFile).Attributes -PassThru | Out-Null
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Replaced: ${origMB}MB → ${newMB}MB"
            }
            else {
                $origMB = [math]::Round($origSize / 1MB, 2)
                $newMB = [math]::Round($newSize / 1MB, 2)
                Write-Host "Skipped: new file not smaller (${origMB}MB → ${newMB}MB) - creating .skip file"
                $skipFile = Join-Path (Split-Path -LiteralPath $originalFile) '.skip'
                New-Item -LiteralPath $skipFile -ItemType File -Force | Out-Null
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
$activeJobs | ForEach-Object {
    Receive-Job -Job $_ -Wait -ErrorAction SilentlyContinue
    Remove-Job -Job $_
}

#####################################################
# Cleanup section
#####################################################

Write-Host "Cleaning up leftover [Cleaned] files..."

Get-ChildItem -Recurse -Include @("*[Cleaned].tmp", "*[Cleaned].nfo", "*[Cleaned].jpg") -Force |
    Remove-Item -Force -ErrorAction SilentlyContinue

Get-ChildItem -Recurse -Directory -Include "*[Cleaned].trickplay" |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "All tasks complete."
