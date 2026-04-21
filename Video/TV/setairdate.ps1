<#
.SYNOPSIS
    Sets file timestamps on TV episode video and NFO file pairs based on the
    NFO air date.

.DESCRIPTION
    Recursively scans the current directory for MKV and MP4 video files.
    For each video, the script looks for a matching <basename>.nfo file.

    If the NFO contains an <aired> date (YYYY-MM-DD), both the video file and
    the NFO file have their CreationTime and LastWriteTime set to midday
    (12:00:00) on that date.

    If the NFO contains no recognisable date, the script compares the existing
    CreationTime and LastWriteTime of both files and sets both to midday on the
    day of the earliest timestamp found.

    Video files without a matching NFO are skipped.

.PARAMETER DryRun
    Performs all processing steps but does not modify any file timestamps.
    Implies no changes are written.

.PARAMETER Debug
    Enables verbose debug output to the console.

.EXAMPLE
    Set-Location "Z:\Media\TV"
    .\setairdate.ps1

.EXAMPLE
    .\setairdate.ps1 -DryRun -Debug

.NOTES
    - Requires PowerShell 5.1 or later.
    - Uses literal paths throughout to handle file names containing
      special regex characters such as [ and ].
    - No external tools required.
    - TV episode NFOs are expected to use the Kodi <episodedetails> schema
      with an <aired> element.
#>

param(
    [switch]$DryRun,
    [switch]$Debug
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DebugMode = $Debug.IsPresent

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-DebugLog {
    param([string]$Message)
    if ($DebugMode) {
        Write-Host "[DEBUG] $Message" -ForegroundColor DarkGray
    }
}

# ---------------------------------------------------------------------------
# XML helper - returns inner text for the first matching XPath node
# ---------------------------------------------------------------------------

function Get-NfoTextValue {
    param(
        [xml]$Document,
        [string]$XPath
    )
    $node = $Document.SelectSingleNode($XPath)
    if ($null -ne $node) {
        return $node.InnerText.Trim()
    }
    return $null
}

# ---------------------------------------------------------------------------
# Timestamp setter - applies CreationTime and LastWriteTime to a single file
# ---------------------------------------------------------------------------

function Set-FileTimestamps {
    param(
        [string]$LiteralPath,
        [datetime]$Timestamp
    )
    if ($DryRun) {
        Write-Host "  [DRY RUN] $LiteralPath  ->  $($Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Cyan
        return
    }
    $item = Get-Item -LiteralPath $LiteralPath
    $item.CreationTime  = $Timestamp
    $item.LastWriteTime = $Timestamp
    Write-DebugLog "  Timestamps set: '$LiteralPath'  ->  $($Timestamp.ToString('yyyy-MM-dd HH:mm:ss'))"
}

# ---------------------------------------------------------------------------
# Returns the earliest datetime across the CreationTime and LastWriteTime of
# two FileInfo objects
# ---------------------------------------------------------------------------

function Get-EarliestFileDate {
    param(
        [System.IO.FileInfo]$FileA,
        [System.IO.FileInfo]$FileB
    )
    $candidates = @(
        $FileA.CreationTime,
        $FileA.LastWriteTime,
        $FileB.CreationTime,
        $FileB.LastWriteTime
    )
    return ($candidates | Sort-Object)[0]
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$rootPath = (Get-Location).Path
Write-DebugLog "Scanning root: $rootPath"

$videoFiles = Get-ChildItem -LiteralPath $rootPath -Recurse -File |
    Where-Object { $_.Extension -in @('.mkv', '.mp4') }

$processed = 0
$skipped   = 0
$errors    = 0

foreach ($video in $videoFiles) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($video.FullName)
    $nfoPath  = [System.IO.Path]::Combine($video.DirectoryName, "$baseName.nfo")

    Write-DebugLog "Checking: $($video.FullName)"

    if (-not (Test-Path -LiteralPath $nfoPath)) {
        Write-DebugLog "  No NFO found - skipping"
        $skipped++
        continue
    }

    Write-DebugLog "  NFO: $nfoPath"

    $targetDate = $null

    try {
        $nfoContent = Get-Content -LiteralPath $nfoPath -Raw -Encoding UTF8
        [xml]$nfo   = $nfoContent

        # TV episode NFOs use <aired>YYYY-MM-DD</aired>
        $airedStr = Get-NfoTextValue -Document $nfo -XPath '/episodedetails/aired'
        Write-DebugLog "  aired = '$airedStr'"

        if (-not [string]::IsNullOrWhiteSpace($airedStr)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact(
                    $airedStr.Trim(),
                    'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$parsed)) {
                # Treat dates more than 30 days in the future as corrupted metadata
                # (e.g. typos like 2038-01-01). Leave $targetDate null so the
                # file-timestamp -> folder-date fallback chain resolves the date,
                # which also retroactively corrects files set by a previous bad run.
                if ($parsed.Date -gt (Get-Date).Date.AddDays(30)) {
                    Write-Warning "NFO aired date '$airedStr' in '$([System.IO.Path]::GetFileName($nfoPath))' is more than 30 days in the future - treating as corrupt; falling back to file/folder timestamps"
                }
                else {
                    $targetDate = $parsed
                    Write-DebugLog "  Using aired: $($targetDate.ToString('yyyy-MM-dd'))"
                }
            }
            else {
                Write-DebugLog "  aired could not be parsed as yyyy-MM-dd"
            }
        }
    }
    catch {
        Write-Warning "Failed to parse NFO '$nfoPath': $_"
        $errors++
        continue
    }

    $nfoItem = Get-Item -LiteralPath $nfoPath

    if ($null -eq $targetDate) {
        # No recognisable date in the NFO - fall back to the earliest existing
        # timestamp across both files
        Write-DebugLog "  No date in NFO - using earliest existing file timestamp"
        $earliest   = Get-EarliestFileDate -FileA $video -FileB $nfoItem
        $candidate  = [datetime]::new($earliest.Year, $earliest.Month, $earliest.Day, 12, 0, 0)
        Write-DebugLog "  Earliest timestamp: $($candidate.ToString('yyyy-MM-dd HH:mm:ss'))"

        $maxFutureCheck = (Get-Date).Date.AddDays(30)
        if ($candidate.Date -gt $maxFutureCheck) {
            # File timestamps are in the future - use the parent folder creation date instead
            $folderItem = Get-Item -LiteralPath $video.DirectoryName
            $folderDate = $folderItem.CreationTime
            Write-DebugLog "  File timestamps are future-dated; using folder creation date: $($folderDate.ToString('yyyy-MM-dd'))"
            $targetDate = [datetime]::new($folderDate.Year, $folderDate.Month, $folderDate.Day, 12, 0, 0)
        }
        else {
            $targetDate = $candidate
        }
    }
    else {
        # Anchor to midday on the resolved date
        $targetDate = [datetime]::new($targetDate.Year, $targetDate.Month, $targetDate.Day, 12, 0, 0)
    }

    # Reject dates more than 30 days in the future
    $maxFuture = (Get-Date).Date.AddDays(30)
    if ($targetDate.Date -gt $maxFuture) {
        Write-Warning "Skipping '$($video.Name)': resolved date $($targetDate.ToString('yyyy-MM-dd')) is more than 30 days in the future"
        $skipped++
        continue
    }

    Write-Host "$($video.Name)  ->  $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))"

    try {
        Set-FileTimestamps -LiteralPath $video.FullName -Timestamp $targetDate
        Set-FileTimestamps -LiteralPath $nfoPath         -Timestamp $targetDate
        $processed++
    }
    catch {
        Write-Warning "Failed to set timestamps on '$($video.Name)': $_"
        $errors++
    }
}

Write-Host ""
Write-Host "Done.  Processed: $processed   Skipped (no NFO): $skipped   Errors: $errors"
