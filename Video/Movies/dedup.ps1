<#
    Movie Folder Cleaner & Dedupe Script
    ------------------------------------

    This script scans movie folders, removes duplicate video files,
    deletes associated sidecar files, and cleans up trickplay folders.

    Supported video extensions:
        .mkv, .mp4, .avi, .ts

    Dedupe priority (highest to lowest):
        MKV → MP4 → AVI → TS

    AUDIT MODE:
        Use -Audit to run the script in "safe mode" where NOTHING is deleted.
        Instead, the script will show what *would* be removed.

        Example:
            .\CleanMovies.ps1 -Audit

        Without -Audit, the script performs real deletions.
#>

param(
    [switch]$Audit
)

$root = Get-Location

# ============================================================
# SUMMARY TRACKING
# ============================================================

$Summary = [ordered]@{
    FoldersProcessed            = 0
    VideosKept                  = @()
    VideosDeleted               = @()
    SidecarsDeleted             = @()
    TrickplayDeleted            = @()
    OrphanedTrickplayDeleted    = @()
    TrailerTrickplayDeleted     = @()
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
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -Recurse:$Recurse
    }
}

# ============================================================
# PROGRESS BAR #1 — SCAN MOVIE FOLDERS
# ============================================================

Write-Host "Scanning movie folders..."

$movieFolders = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -ne "extras" -and
        $_.Name -ne "extrafanart" -and
        $_.Name -notlike "*.trickplay"
    }

$totalFolders = $movieFolders.Count
$scanIndex = 0

foreach ($folder in $movieFolders) {
    $scanIndex++
    $percent = if ($totalFolders -gt 0) {
        [math]::Floor(($scanIndex / $totalFolders) * 100)
    } else { 100 }

    Write-Progress -Id 1 -Activity "Scanning movie folders..." `
                   -Status "Found: $($folder.Name)" `
                   -PercentComplete $percent
}

Write-Progress -Id 1 -Activity "Scanning movie folders..." -Completed

# ============================================================
# PROGRESS BAR #2 — PROCESS MOVIE FOLDERS
# ============================================================

$totalFolders = $movieFolders.Count
$folderIndex = 0
$lastPercentShown = -1

foreach ($folder in $movieFolders) {

    $Summary.FoldersProcessed++
    $folderIndex++

    # Progress bar update
    $percent2 = if ($totalFolders -gt 0) {
        [math]::Floor(($folderIndex / $totalFolders) * 100)
    } else { 100 }

    if ($percent2 -ne $lastPercentShown) {
        Write-Progress -Id 2 -Activity "Processing movie folders..." `
                       -Status "Folder $folderIndex of $totalFolders" `
                       -PercentComplete $percent2
        $lastPercentShown = $percent2
    }

    Write-Host ""
    Write-Host ">>> Processing: $($folder.FullName)" -ForegroundColor Cyan

    # .skip check
    $skipFile = Join-Path $folder.FullName ".skip"
    if (Test-Path -LiteralPath $skipFile) {
        Write-Host "  .skip found, skipping folder"
        continue
    }

    # Valid video extensions
    $validExtensions = ".mkv", ".mp4", ".avi", ".ts"

    # Get video files (ignore trailers and behind-the-scenes)
    $videoFiles = @(
        Get-ChildItem -LiteralPath $folder.FullName -File -ErrorAction SilentlyContinue |
        Where-Object {
            ($validExtensions -contains $_.Extension.ToLower()) -and
            ($_.Name -notlike "*-trailer.*") -and
            ($_.Name -notlike "*-behindthescenes.*")
        }
    )

    # ============================================================
    # REMOVE ORPHANED TRICKPLAY FOLDERS
    # ============================================================

    $trickplayFolders = Get-ChildItem -LiteralPath $folder.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*.trickplay" }

    foreach ($tp in $trickplayFolders) {
        $base = $tp.Name -replace "\.trickplay$", ""

        $matchingVideo = $videoFiles | Where-Object {
            [System.IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $base
        }

        if ($matchingVideo.Count -eq 0) {
            Write-Host "  Removing ORPHANED trickplay folder: $($tp.FullName)"
            $Summary.OrphanedTrickplayDeleted += $tp.FullName
            Remove-ItemSafe -Path $tp.FullName -Recurse
        }
    }

    # If only one or zero video files remain, nothing to dedupe
    if ($videoFiles.Count -le 1) {
        Write-Host "  Only one or zero video files — nothing to dedupe"
        continue
    }

    # Group by extension
    $mkvFiles = @($videoFiles | Where-Object { $_.Extension.ToLower() -eq ".mkv" })
    $mp4Files = @($videoFiles | Where-Object { $_.Extension.ToLower() -eq ".mp4" })
    $aviFiles = @($videoFiles | Where-Object { $_.Extension.ToLower() -eq ".avi" })
    $tsFiles  = @($videoFiles | Where-Object { $_.Extension.ToLower() -eq ".ts" })

    Write-Host "  Found $($mkvFiles.Count) MKV(s), $($mp4Files.Count) MP4(s), $($aviFiles.Count) AVI(s), $($tsFiles.Count) TS file(s)"

    # ============================================================
    # DEDUPE PRIORITY: MKV → MP4 → AVI → TS
    # ============================================================

    if ($mkvFiles.Count -gt 0) {
        $fileToKeep = $mkvFiles | Sort-Object Length -Descending | Select-Object -First 1
        Write-Host "  Keeping largest MKV: $($fileToKeep.Name)"
    }
    elseif ($mp4Files.Count -gt 0) {
        $fileToKeep = $mp4Files | Sort-Object Length -Descending | Select-Object -First 1
        Write-Host "  Keeping largest MP4: $($fileToKeep.Name)"
    }
    elseif ($aviFiles.Count -gt 0) {
        $fileToKeep = $aviFiles | Sort-Object Length -Descending | Select-Object -First 1
        Write-Host "  Keeping largest AVI: $($fileToKeep.Name)"
    }
    else {
        $fileToKeep = $tsFiles | Sort-Object Length -Descending | Select-Object -First 1
        Write-Host "  Keeping largest TS: $($fileToKeep.Name)"
    }

    $Summary.VideosKept += $fileToKeep.FullName

    # Files to delete
    $filesToDelete = $videoFiles | Where-Object {
        $_.FullName -ne $fileToKeep.FullName
    }

    # ============================================================
    # DELETE VIDEO FILES
    # ============================================================

    foreach ($file in $filesToDelete) {
        Write-Host "  Deleting video: $($file.Name)"
        $Summary.VideosDeleted += $file.FullName
        Remove-ItemSafe -Path $file.FullName
    }

    # ============================================================
    # DELETE ASSOCIATED FILES
    # ============================================================

    foreach ($file in $filesToDelete) {

        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)

        # Sidecars
        $sidecars = Get-ChildItem -LiteralPath $folder.FullName -ErrorAction SilentlyContinue |
            Where-Object {
                $_.BaseName.StartsWith($baseName, [System.StringComparison]::OrdinalIgnoreCase) -and
                ($_.Name -notlike "*-trailer.*") -and
                ($_.Name -notlike "*-behindthescenes.*")
            }

        foreach ($s in $sidecars) {
            Write-Host "    Removing related item: $($s.FullName)"
            $Summary.SidecarsDeleted += $s.FullName
            Remove-ItemSafe -Path $s.FullName -Recurse
        }

        # Trickplay folder
        $trickplay = Join-Path $folder.FullName ($baseName + ".trickplay")
        if (Test-Path -LiteralPath $trickplay) {
            Write-Host "    Removing trickplay folder: $trickplay"
            $Summary.TrickplayDeleted += $trickplay
            Remove-ItemSafe -Path $trickplay -Recurse
        }
    }

    # ============================================================
    # DELETE TRAILER TRICKPLAY FOLDERS
    # ============================================================

    $trailerTP = Get-ChildItem -LiteralPath $folder.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*-trailer.trickplay" }

    foreach ($tp in $trailerTP) {
        Write-Host "  Removing trailer trickplay folder: $($tp.FullName)"
        $Summary.TrailerTrickplayDeleted += $tp.FullName
        Remove-ItemSafe -Path $tp.FullName -Recurse
    }
}

# ============================================================
# SUMMARY REPORT
# ============================================================

Write-Progress -Id 2 -Activity "Processing movie folders..." -Completed

Write-Host ""
Write-Host "==================== SUMMARY REPORT ====================" -ForegroundColor Cyan

if ($Audit) {
    Write-Host "AUDIT MODE — No files were actually deleted." -ForegroundColor Yellow
    Write-Host ""
}

Write-Host ("Folders processed: {0}" -f $Summary.FoldersProcessed) -ForegroundColor Cyan
Write-Host ""

Write-Host ("Videos kept: {0}" -f $Summary.VideosKept.Count) -ForegroundColor Green
Write-Host ("Videos deleted: {0}" -f $Summary.VideosDeleted.Count) -ForegroundColor Red
Write-Host ("Sidecar files deleted: {0}" -f $Summary.SidecarsDeleted.Count) -ForegroundColor Red
Write-Host ("Trickplay folders deleted: {0}" -f $Summary.TrickplayDeleted.Count) -ForegroundColor Red
Write-Host ("Orphaned trickplay folders deleted: {0}" -f $Summary.OrphanedTrickplayDeleted.Count) -ForegroundColor Yellow
Write-Host ("Trailer trickplay folders deleted: {0}" -f $Summary.TrailerTrickplayDeleted.Count) -ForegroundColor Red

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

Show-List "Videos kept:" Green $Summary.VideosKept
Show-List "Videos deleted:" Red $Summary.VideosDeleted
Show-List "Sidecar files deleted:" Red $Summary.SidecarsDeleted
Show-List "Trickplay folders deleted:" Red $Summary.TrickplayDeleted
Show-List "Orphaned trickplay folders deleted:" Yellow $Summary.OrphanedTrickplayDeleted
Show-List "Trailer trickplay folders deleted:" Red $Summary.TrailerTrickplayDeleted

Write-Host "========================================================="
Write-Host ""
