<#
    TV Show Folder Cleaner & Dedupe Script
    ---------------------------------------

    This script recursively scans TV show folders, removes duplicate episodes,
    and deletes associated sidecar files based on S##E## or ##x## pattern matching.

    How it works:
        1. Scans all files recursively for S##E##, S##E###, ##x##, #x##, or ##x### patterns
           (e.g., S01E05, S18E012, 01x05, 1x05, 01x012)
        2. Groups files by their episode code within the same directory
        3. When duplicates exist (same episode, different extensions/names),
           keeps the largest file and deletes others
        4. Removes associated sidecar files (.nfo, .srt, etc.)

    Supported video extensions:
        .mkv, .mp4, .avi, .ts

    Dedupe priority (highest to lowest):
        MKV → MP4 → TS → AVI

    AUDIT MODE:
        Use -Audit to run the script in "safe mode" where NOTHING is deleted.
        Instead, the script will show what *would* be removed.

        Example:
            .\dedup.ps1 -Audit

        Without -Audit, the script performs real deletions.
#>

param(
    [switch]$Audit
)

# ============================================================
# SUMMARY TRACKING
# ============================================================

$Summary = [ordered]@{
    EpisodesProcessed = 0
    EpisodesKept      = @()
    EpisodesDeleted   = @()
    SidecarsDeleted   = @()
}

# ============================================================
# SAFE DELETE FUNCTION (AUDIT MODE AWARE)
# ============================================================

function Remove-ItemSafe {
    param(
        [string]$Path,
        [switch]$Recurse
    )

    if ($Audit) {
        Write-Host "AUDIT: Would delete: $Path" -ForegroundColor Yellow
    }
    else {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -Recurse:$Recurse -ProgressAction SilentlyContinue
    }
}

# ============================================================
# GET VIDEO PROPERTIES USING FFPROBE
# ============================================================

function Get-VideoProperties {
    param([string]$FilePath)

    try {
        $probeJson = ffprobe -v quiet -print_format json -show_streams -select_streams v "$FilePath"
        $probe = $probeJson | ConvertFrom-Json
        
        if (-not $probe.streams -or $probe.streams.Count -eq 0) {
            return @{ Resolution = 0; Bitrate = 0; Error = "No video stream found" }
        }

        $stream = $probe.streams[0]
        
        $height = [int]$stream.height
        $width  = [int]$stream.width
        $resolution = $height * $width
        
        $bitrate = [int]$stream.bit_rate
        
        return @{
            Resolution = $resolution
            Height     = $height
            Width      = $width
            Bitrate    = $bitrate
            Error      = $null
        }
    }
    catch {
        return @{
            Resolution = 0
            Bitrate    = 0
            Error      = "ffprobe failed: $_"
        }
    }
}

# ============================================================
# EXTRACT S##E## OR ##x## FROM FILENAME
# ============================================================

function Get-EpisodeCode {
    param([string]$Filename)

    # Match S##E## or S##E###
    if ($Filename -match 'S(\d{2})E(\d{2,3})') {
        $season  = $matches[1]
        $episode = $matches[2].PadLeft(3, '0')
        return "S${season}E${episode}"
    }

    # Match 1–2 digits x 2+ digits (1x01, 01x01, 1x123, etc.)
    if ($Filename -match '(\d{1,2})[xX](\d{2,})') {
        $season  = $matches[1].PadLeft(2, '0')
        $episode = $matches[2].PadLeft(3, '0')
        return "S${season}E${episode}"
    }

    return $null
}

# ============================================================
# MAIN PROCESSING
# ============================================================

Write-Host "Scanning for video files with S##E## or ##x## patterns..."

$validExtensions = ".mkv", ".mp4", ".avi", ".ts"

$allDirs = @(
    Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $validExtensions -contains $_.Extension.ToLower() } |
    Select-Object -ExpandProperty DirectoryName -Unique |
    Sort-Object
)

Write-Host "Found $($allDirs.Count) directories with video files"
Write-Host ""

foreach ($dir in $allDirs) {
    
    $filesInDir = @(
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $validExtensions -contains $_.Extension.ToLower() }
    )

    if ($filesInDir.Count -eq 0) { continue }

    Write-Host "Processing directory: $dir" -ForegroundColor Cyan
    Write-Host "  Found $($filesInDir.Count) video files"

    $episodeGroups = @{}

    foreach ($file in $filesInDir) {
        $episodeCode = Get-EpisodeCode $file.Name
        
        if ($episodeCode) {
            if (-not $episodeGroups.ContainsKey($episodeCode)) {
                $episodeGroups[$episodeCode] = @()
            }
            $episodeGroups[$episodeCode] += $file
        }
    }

    if ($episodeGroups.Count -eq 0) {
        Write-Host "  No files with S##E## or ##x## pattern found"
        Write-Host ""
        continue
    }

    Write-Host "  Found $($episodeGroups.Count) unique episodes"

    foreach ($episodeCode in $episodeGroups.Keys | Sort-Object) {
        $files = $episodeGroups[$episodeCode]

        if ($files.Count -le 1) {
            $Summary.EpisodesProcessed++
            $Summary.EpisodesKept += $files[0].FullName
            continue
        }

        Write-Host "  >>> $episodeCode (found $($files.Count) files)" -ForegroundColor Yellow

        $filesWithProps = @()
        foreach ($file in $files) {
            $props = Get-VideoProperties $file.FullName
            
            $extPriority = switch ($file.Extension.ToLower()) {
                ".mkv" { 4 }
                ".mp4" { 3 }
                ".ts"  { 2 }
                ".avi" { 1 }
                default { 0 }
            }
            
            $filesWithProps += @{
                File        = $file
                Extension   = $file.Extension.ToLower()
                ExtPriority = $extPriority
                Resolution  = $props.Resolution
                Height      = $props.Height
                Width       = $props.Width
                Bitrate     = $props.Bitrate
                Error       = $props.Error
            }
        }

        $fileToKeepInfo = $filesWithProps | Sort-Object `
            @{ Expression = { $_.ExtPriority }; Descending = $true },
            @{ Expression = { $_.File.Length }; Descending = $true } |
            Select-Object -First 1

        $fileToKeep = $fileToKeepInfo.File
        $resStr = if ($fileToKeepInfo.Height -gt 0 -and $fileToKeepInfo.Width -gt 0) {
            "$($fileToKeepInfo.Width)x$($fileToKeepInfo.Height)"
        } else { "unknown" }

        $bitrateStr = if ($fileToKeepInfo.Bitrate -gt 0) {
            ([math]::Round($fileToKeepInfo.Bitrate / 1MB, 2)).ToString() + " Mbps"
        } else { "unknown" }

        Write-Host "      Keeping: $($fileToKeep.Name) ($resStr, $bitrateStr)"

        $Summary.EpisodesKept += $fileToKeep.FullName
        $Summary.EpisodesProcessed++

        $filesToDelete = $files | Where-Object {
            $_.FullName -ne $fileToKeep.FullName
        }

        foreach ($file in $filesToDelete) {
            $fileInfo = $filesWithProps | Where-Object { $_.File.FullName -eq $file.FullName } | Select-Object -First 1

            $resStr = if ($fileInfo.Height -gt 0 -and $fileInfo.Width -gt 0) {
                "$($fileInfo.Width)x$($fileInfo.Height)"
            } else { "unknown" }

            $bitrateStr = if ($fileInfo.Bitrate -gt 0) {
                ([math]::Round($fileInfo.Bitrate / 1MB, 2)).ToString() + " Mbps"
            } else { "unknown" }

            Write-Host "      Deleting: $($file.Name) ($resStr, $bitrateStr)"
            $Summary.EpisodesDeleted += $file.FullName
            Remove-ItemSafe -Path $file.FullName
        }

        foreach ($file in $filesToDelete) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

            $sidecars = Get-ChildItem -LiteralPath $dir -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.BaseName.StartsWith($baseName, [System.StringComparison]::OrdinalIgnoreCase) -and
                    $_.FullName -ne $file.FullName
                }

            foreach ($sidecar in $sidecars) {
                Write-Host "        Removing sidecar: $($sidecar.Name)"
                $Summary.SidecarsDeleted += $sidecar.FullName
                Remove-ItemSafe -Path $sidecar.FullName -Recurse
            }
        }
    }

    Write-Host ""
}

# ============================================================
# SUMMARY REPORT
# ============================================================

Write-Host "==================== SUMMARY REPORT ====================" -ForegroundColor Cyan

if ($Audit) {
    Write-Host "AUDIT MODE - No files were actually deleted." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host ("Episodes processed: {0}" -f $Summary.EpisodesProcessed) -ForegroundColor Cyan
Write-Host ""

Write-Host ("Episodes kept: {0}" -f $Summary.EpisodesKept.Count) -ForegroundColor Green
Write-Host ("Episodes deleted: {0}" -f $Summary.EpisodesDeleted.Count) -ForegroundColor Red
Write-Host ("Sidecar files deleted: {0}" -f $Summary.SidecarsDeleted.Count) -ForegroundColor Red

Write-Host ""

function Show-List {
    param(
        [string]$Title,
        [ConsoleColor]$Color,
        [array]$Items
    )

    Write-Host $Title -ForegroundColor $Color
    if ($Items.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor DarkGray
    }
    else {
        $Items | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host ""
}

Show-List "Episodes kept:" Green $Summary.EpisodesKept
Show-List "Episodes deleted:" Red $Summary.EpisodesDeleted
Show-List "Sidecar files deleted:" Red $Summary.SidecarsDeleted

Write-Host "========================================================="
Write-Host ""
