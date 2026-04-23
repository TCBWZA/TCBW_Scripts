<#
.SYNOPSIS
    Moves chapter XML files into per-folder chapters subdirectories.

.DESCRIPTION
    Recursively scans a directory tree for *_chapters.xml files and moves them
    into a chapters/ subdirectory alongside the source files. Skips directories
    containing a .skip marker file.

    Features:
    - Recursive directory traversal
    - Dry-run mode for safe preview
    - Debug output with path details
    - .skip directory marker support

.PARAMETER Root
    Root directory to scan. Defaults to the current directory.

.PARAMETER DryRun
    Preview changes without moving any files.

.PARAMETER Debug
    Enables verbose debug output.

.EXAMPLE
    PS> .\organize-chapters.ps1

.EXAMPLE
    PS> .\organize-chapters.ps1 -DryRun

.EXAMPLE
    PS> .\organize-chapters.ps1 -Root "D:\TV" -DryRun

.NOTES
    - Run from the root directory containing your TV show folders, or pass -Root.
    - Place a .skip file in any directory to exclude it and all subdirectories.
#>
param(
    [string]$Root    = ".",
    [switch]$DryRun,
    [switch]$Debug
)

$moved       = 0
$skippedDirs = 0

function Invoke-OrganizeDirectory {
    param([string]$Dir)

    if (Test-Path -LiteralPath (Join-Path $Dir ".skip")) {
        if ($Debug) { Write-Host "[DEBUG] .skip found, skipping directory tree: $Dir" }
        $script:skippedDirs++
        return
    }

    $chapterFiles = Get-ChildItem -LiteralPath $Dir -Filter "*_chapters.xml" -File -ErrorAction SilentlyContinue

    if ($chapterFiles) {
        $dest = Join-Path $Dir "chapters"
        if ($Debug) { Write-Host "[DEBUG] Creating: $dest" }
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        }
        foreach ($f in $chapterFiles) {
            Write-Host "Moving: $($f.Name)  ->  $dest\"
            if (-not $DryRun) {
                Move-Item -LiteralPath $f.FullName -Destination $dest
            }
            $script:moved++
        }
    } elseif ($Debug) {
        Write-Host "[DEBUG] No _chapters.xml files in: $Dir"
    }

    # Recurse into subdirectories, skipping any existing 'chapters' folder
    Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'chapters' } |
        ForEach-Object { Invoke-OrganizeDirectory -Dir $_.FullName }
}

Invoke-OrganizeDirectory -Dir (Resolve-Path $Root).ProviderPath

Write-Host ""
Write-Host "Done.  Moved: $moved  |  Directories skipped (.skip): $skippedDirs"
