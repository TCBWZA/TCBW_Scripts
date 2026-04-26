<#
.SYNOPSIS
    Removes orphaned trickplay directories, stale .skip markers, and dangling NFO sidecar files.

.DESCRIPTION
    Recursively scans a directory tree and removes three categories of orphaned items:

    Trickplay directories:
      Directories named 'trickplay' that have no video files (.mkv, .mp4, .avi, .ts) in
      their parent directory are removed. Directories matching '*.trickplay' where no video
      file with the same base name exists in the same directory are also removed.

    Stale .skip markers:
      Files matching the pattern .skip_<basename> are removed when no video file with that
      basename (.mkv, .mp4, .avi, .ts) exists in the same directory.

    Dangling NFO files:
      Files matching <basename>.nfo are removed when no video file with that basename exists
      in the same directory. Generic library-level NFO names (movie, movies, tvshow, series,
      show) are never removed regardless of whether a matching video exists.

    All operations respect a .skip marker - if a directory contains a .skip file, it and
    all of its subdirectories are excluded from processing.

.PARAMETER Root
    Root directory to scan. Defaults to the current directory.

.PARAMETER Audit
    Preview mode. Reports what would be removed without deleting anything.

.PARAMETER Debug
    Enables verbose debug output.

.EXAMPLE
    .\dircleanup.ps1 -Audit

.EXAMPLE
    .\dircleanup.ps1 -Root "Z:\Media\Movies" -Audit

.EXAMPLE
    .\dircleanup.ps1 -Root "Z:\Media\Movies"

.NOTES
    - Requires PowerShell 5.1 or later.
    - Uses literal paths throughout to handle file names containing special characters.
    - Always run with -Audit first to review planned removals before performing live cleanup.
#>

param(
    [string]$Root  = ".",
    [switch]$Audit,
    [switch]$Debug
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DebugMode = $Debug.IsPresent

# Generic NFO names that are never treated as per-video sidecars
$GenericNfoNames = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('movie', 'movies', 'tvshow', 'series', 'show'),
    [System.StringComparer]::OrdinalIgnoreCase
)

$VideoExtensions = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('.mkv', '.mp4', '.avi', '.ts'),
    [System.StringComparer]::OrdinalIgnoreCase
)

$script:RemovedDirs  = 0
$script:RemovedSkips = 0
$script:RemovedNfos  = 0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-DebugLog {
    param([string]$Message)
    if ($DebugMode) { Write-Host "[DEBUG] $Message" -ForegroundColor DarkGray }
}

function Invoke-Remove {
    param(
        [string]$Path,
        [switch]$Recurse
    )
    if ($Audit) {
        Write-Host "[AUDIT] Would remove: $Path"
    } else {
        if ($Recurse) {
            Remove-Item -LiteralPath $Path -Recurse -Force
        } else {
            Remove-Item -LiteralPath $Path -Force
        }
        Write-Host "Removed: $Path"
    }
}

# ---------------------------------------------------------------------------
# Per-directory cleanup
# ---------------------------------------------------------------------------

function Invoke-CleanDirectory {
    param([string]$Dir)

    if (Test-Path -LiteralPath (Join-Path $Dir ".skip")) {
        Write-DebugLog ".skip found, skipping directory tree: $Dir"
        return
    }

    # Collect basenames of all video files present in this directory
    $videoBasenames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $VideoExtensions.Contains($_.Extension) } |
        ForEach-Object { $null = $videoBasenames.Add($_.BaseName) }

    Write-DebugLog "Directory: $Dir  |  Video files: $($videoBasenames.Count)"

    # --- Trickplay directories ---
    Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'trickplay' -or $_.Name.EndsWith('.trickplay') } |
        ForEach-Object {
            $tpDir   = $_
            $orphaned = $false

            if ($tpDir.Name -eq 'trickplay') {
                # Generic trickplay folder: orphaned when the parent has no video files at all
                $orphaned = $videoBasenames.Count -eq 0
            } else {
                # Named trickplay (e.g. Movie.Title.trickplay): check for a matching video basename
                $base     = [System.IO.Path]::GetFileNameWithoutExtension($tpDir.Name)
                $orphaned = -not $videoBasenames.Contains($base)
            }

            if ($orphaned) {
                Write-Host "Orphaned trickplay directory: $($tpDir.FullName)"
                Invoke-Remove -Path $tpDir.FullName -Recurse
                $script:RemovedDirs++
            } else {
                Write-DebugLog "Trickplay OK: $($tpDir.FullName)"
            }
        }

    # --- Stale .skip_<basename> markers ---
    Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.skip_*' } |
        ForEach-Object {
            $markerBase = $_.Name.Substring(6)   # strip leading '.skip_' (6 chars)
            if (-not $videoBasenames.Contains($markerBase)) {
                Write-Host "Stale skip marker: $($_.FullName)"
                Invoke-Remove -Path $_.FullName
                $script:RemovedSkips++
            } else {
                Write-DebugLog "Skip marker OK: $($_.Name)"
            }
        }

    # --- Dangling NFO sidecars ---
    Get-ChildItem -LiteralPath $Dir -File -Filter '*.nfo' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $nfoBase = $_.BaseName
            if ($GenericNfoNames.Contains($nfoBase)) {
                Write-DebugLog "Skipping generic NFO: $($_.Name)"
                return
            }
            if (-not $videoBasenames.Contains($nfoBase)) {
                Write-Host "Dangling NFO: $($_.FullName)"
                Invoke-Remove -Path $_.FullName
                $script:RemovedNfos++
            } else {
                Write-DebugLog "NFO OK: $($_.Name)"
            }
        }

    # Recurse into subdirectories, skipping trickplay directories (already handled above)
    Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'trickplay' -and -not $_.Name.EndsWith('.trickplay') } |
        ForEach-Object { Invoke-CleanDirectory -Dir $_.FullName }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

$resolvedRoot = (Resolve-Path -LiteralPath $Root).ProviderPath
Invoke-CleanDirectory -Dir $resolvedRoot

$mode = if ($Audit) { ' (audit - no changes made)' } else { '' }
Write-Host ""
Write-Host "Done$mode  |  Trickplay dirs: $($script:RemovedDirs)  |  Stale .skip markers: $($script:RemovedSkips)  |  Dangling NFOs: $($script:RemovedNfos)"
