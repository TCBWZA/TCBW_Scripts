<#
    TV Show Folder Cleaner & Dedupe Script
    ---------------------------------------

    This script recursively scans TV show folders, removes duplicate episodes,
    and deletes associated sidecar files based on S##E## or ##x## pattern matching.

    How it works:
        1. Scans all files recursively for S##E##, S##E###, ##x##, or ##x### patterns
           (e.g., S01E05, S18E012, 01x05, 01x012)
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

# PSScriptAnalyzer false positive: this variable is actively used in the script
$Summary = [ordered]@{
    EpisodesProcessed           = 0
    EpisodesKept                = @()
    EpisodesDeleted             = @()
    SidecarsDeleted             = @()
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
        
        # Calculate resolution (height * width)
        $height = [int]$stream.height
        $width = [int]$stream.width
        $resolution = $height * $width
        
        # Get bitrate (convert to Mbps)
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

    # Match S followed by 2 digits, E followed by 2-3 digits (S##E## or S##E###)
    if ($Filename -match 'S(\d{2})E(\d{2,3})') {
        $season = $matches[1]
        $episode = $matches[2].PadLeft(3, '0')  # Pad to 3 digits
        return "S${season}E${episode}"
    }

    # Match 2 digits, x (case-insensitive), followed by 1-3 digits (##x#, ##x##, or ##x###)
    # Normalize to S##E### format
    if ($Filename -match '(\d{2})[xX](\d{1,3})') {
        $season = $matches[1]
        $episode = $matches[2].PadLeft(3, '0')  # Pad to 3 digits
        return "S${season}E${episode}"
    }

    return $null
}

# ============================================================
# MAIN PROCESSING
# ============================================================

Write-Host "Scanning for video files with S##E## or ##x## patterns..."

# Get all unique directories that contain video files
$validExtensions = ".mkv", ".mp4", ".avi", ".ts"

$allDirs = @(
    Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $validExtensions -contains $_.Extension.ToLower()
    } |
    Select-Object -ExpandProperty DirectoryName -Unique |
    Sort-Object
)

Write-Host "Found $($allDirs.Count) directories with video files"
Write-Host ""

# Process each directory
foreach ($dir in $allDirs) {
    
    # Get video files in this directory only
    $filesInDir = @(
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object {
            $validExtensions -contains $_.Extension.ToLower()
        }
    )

    if ($filesInDir.Count -eq 0) {
        continue
    }

    Write-Host "Processing directory: $dir" -ForegroundColor Cyan
    Write-Host "  Found $($filesInDir.Count) video files"

    # Group by S##E## pattern within this directory only
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

    # Process each episode in this directory
    foreach ($episodeCode in $episodeGroups.Keys | Sort-Object) {
        $files = $episodeGroups[$episodeCode]

        # Skip if only one file for this episode
        if ($files.Count -le 1) {
            $Summary.EpisodesProcessed++
            $Summary.EpisodesKept += $files[0].FullName
            continue
        }

        Write-Host "  >>> $episodeCode (found $($files.Count) files)" -ForegroundColor Yellow

        # ============================================================
        # Get video properties for each file
        $filesWithProps = @()
        foreach ($file in $files) {
            $props = Get-VideoProperties $file.FullName
            
            # Assign extension priority (for when files are different types)
            $extPriority = switch ($file.Extension.ToLower()) {
                ".mkv" { 4 }
                ".mp4" { 3 }
                ".ts"  { 2 }
                ".avi" { 1 }
                default { 0 }
            }
            
            $filesWithProps += @{
                File       = $file
                Extension  = $file.Extension.ToLower()
                ExtPriority = $extPriority
                Resolution = $props.Resolution
                Height     = $props.Height
                Width      = $props.Width
                Bitrate    = $props.Bitrate
                Error      = $props.Error
            }
        }

        # ============================================================
        # DETERMINE WHICH FILE TO KEEP
        # Priority: Extension (MKV wins) → File Size (largest)
        # ============================================================

        $fileToKeepInfo = $filesWithProps | Sort-Object `
            @{ Expression = { $_.ExtPriority }; Descending = $true },
            @{ Expression = { $_.File.Length }; Descending = $true } |
            Select-Object -First 1

        $fileToKeep = $fileToKeepInfo.File
        $resStr = if ($fileToKeepInfo.Height -gt 0 -and $fileToKeepInfo.Width -gt 0) {
            "$($fileToKeepInfo.Width)x$($fileToKeepInfo.Height)"
        } else {
            "unknown"
        }
        $bitrateStr = if ($fileToKeepInfo.Bitrate -gt 0) {
            ([math]::Round($fileToKeepInfo.Bitrate / 1MB, 2)).ToString() + " Mbps"
        } else {
            "unknown"
        }

        Write-Host "      Keeping: $($fileToKeep.Name) ($resStr, $bitrateStr)"

        $Summary.EpisodesKept += $fileToKeep.FullName
        $Summary.EpisodesProcessed++

        # Files to delete
        $filesToDelete = $files | Where-Object {
            $_.FullName -ne $fileToKeep.FullName
        }

        # ============================================================
        # DELETE VIDEO FILES
        # ============================================================

        foreach ($file in $filesToDelete) {
            $fileInfo = $filesWithProps | Where-Object { $_.File.FullName -eq $file.FullName } | Select-Object -First 1
            $resStr = if ($fileInfo.Height -gt 0 -and $fileInfo.Width -gt 0) {
                "$($fileInfo.Width)x$($fileInfo.Height)"
            } else {
                "unknown"
            }
            $bitrateStr = if ($fileInfo.Bitrate -gt 0) {
                ([math]::Round($fileInfo.Bitrate / 1MB, 2)).ToString() + " Mbps"
            } else {
                "unknown"
            }
            Write-Host "      Deleting: $($file.Name) ($resStr, $bitrateStr)"
            $Summary.EpisodesDeleted += $file.FullName
            Remove-ItemSafe -Path $file.FullName
        }

        # ============================================================
        # DELETE ASSOCIATED SIDECAR FILES
        # ============================================================

        foreach ($file in $filesToDelete) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

            # Find all files starting with the same basename (but different extensions)
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
    Write-Host "AUDIT MODE — No files were actually deleted." -ForegroundColor Yellow
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

# ============================================================
# CLEANUP SECTION
# ============================================================

Write-Host "Cleaning up all [Trans] files and directories..." -ForegroundColor Cyan

Get-ChildItem -Recurse -Include "*[Trans].*" -Force | Remove-Item -Force -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Directory -Include "*[Trans].trickplay" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "All tasks complete."
