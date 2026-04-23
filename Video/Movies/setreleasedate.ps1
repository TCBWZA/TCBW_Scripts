<#
.SYNOPSIS
    Sets file timestamps on movie video and NFO file pairs based on the NFO
    release date.

.DESCRIPTION
    Recursively scans the current directory for MKV and MP4 video files.
    For each video, the script looks for a matching <basename>.nfo file.

    Files are skipped when:
    - Any segment of the file path is named 'extras' (case-insensitive).
    - The file base name ends with a known non-feature suffix such as
      -trailer, -behindthescenes, -featurette, -interview, -scene, -short,
      -deleted, or -sample.
    - No matching NFO file is found.

    If the NFO contains a <premiered> date (YYYY-MM-DD), both the video file
    and the NFO file have their CreationTime and LastWriteTime set to midday
    (12:00:00) on that date.

    If <premiered> is absent or cannot be parsed, the script falls back to
    <year> and uses January 1 of that year at midday.

    If the NFO contains no recognisable date at all, the script compares the
    existing CreationTime and LastWriteTime of both files and sets both to
    midday on the day of the earliest timestamp found.

.PARAMETER NoNfo
    Optional path to a file. When provided, the full path of each video that
    has no matching NFO is appended to this file (one path per line). The file
    is created if it does not exist. The parent directory must already exist.

.PARAMETER DryRun
    Performs all processing steps but does not modify any file timestamps.
    Implies no changes are written.

.PARAMETER Debug
    Enables verbose debug output to the console.

.EXAMPLE
    Set-Location "Z:\Media\Movies"
    .\setreleasedate.ps1

.EXAMPLE
    .\setreleasedate.ps1 -DryRun -Debug

.NOTES
    - Requires PowerShell 5.1 or later.
    - Uses literal paths throughout to handle file names containing
      special regex characters such as [ and ].
    - No external tools required.
#>

param(
    [switch]$DryRun,
    [switch]$Debug,
    [string]$NoNfo = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DebugMode = $Debug.IsPresent

# Validate -NoNfo path if supplied
if ($NoNfo -ne '') {
    $noNfoLeaf   = [System.IO.Path]::GetFileName($NoNfo)
    $noNfoParent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($NoNfo))
    if ([string]::IsNullOrWhiteSpace($noNfoLeaf) -or $noNfoLeaf -eq '.' -or $noNfoLeaf -eq '..') {
        Write-Error "-NoNfo filename '$NoNfo' is not valid."
        exit 1
    }
    if (-not (Test-Path -LiteralPath $noNfoParent -PathType Container)) {
        Write-Error "-NoNfo parent directory '$noNfoParent' does not exist."
        exit 1
    }
}

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

# Suffixes that identify non-main-feature content (compared case-insensitively)
$skipSuffixes = @('-trailer', '-behindthescenes', '-featurette', '-interview',
                   '-scene', '-short', '-deleted', '-sample')

$videoFiles = Get-ChildItem -LiteralPath $rootPath -Recurse -File |
    Where-Object { $_.Extension -in @('.mkv', '.mp4') }

$processed = 0
$skipped   = 0
$filtered  = 0
$errors    = 0

foreach ($video in $videoFiles) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($video.FullName)
    $nfoPath  = [System.IO.Path]::Combine($video.DirectoryName, "$baseName.nfo")

    Write-DebugLog "Checking: $($video.FullName)"

    # Skip if directory .skip marker exists
    if (Test-Path -LiteralPath (Join-Path $video.DirectoryName ".skip")) {
        Write-DebugLog "  .skip directory marker found - skipping"
        $filtered++
        continue
    }

    # Skip if per-file .skip_<basename> marker exists
    if (Test-Path -LiteralPath (Join-Path $video.DirectoryName ".skip_$baseName")) {
        Write-DebugLog "  .skip_$baseName per-file marker found - skipping"
        $filtered++
        continue
    }

    # Skip files inside an 'extras' directory (any level)
    $pathParts = $video.FullName.Split([System.IO.Path]::DirectorySeparatorChar)
    if ($pathParts | Where-Object { $_ -ieq 'extras' }) {
        Write-DebugLog "  Inside 'extras' directory - skipping"
        $filtered++
        continue
    }

    # Skip files whose base name ends with a known non-feature suffix
    $isExtra = $false
    foreach ($suffix in $skipSuffixes) {
        if ($baseName.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isExtra = $true
            break
        }
    }
    if ($isExtra) {
        Write-DebugLog "  Non-feature suffix detected - skipping"
        $filtered++
        continue
    }

    if (-not (Test-Path -LiteralPath $nfoPath)) {
        # Fall back to movie.nfo in the same directory
        $movieNfoPath = [System.IO.Path]::Combine($video.DirectoryName, 'movie.nfo')
        if (Test-Path -LiteralPath $movieNfoPath) {
            Write-DebugLog "  '$([System.IO.Path]::GetFileName($nfoPath))' not found; using movie.nfo"
            $nfoPath = $movieNfoPath
        }
    }

    if (-not (Test-Path -LiteralPath $nfoPath)) {
        Write-DebugLog "  No NFO found - skipping"
        if ($NoNfo -ne '') {
            Add-Content -LiteralPath $NoNfo -Value $video.FullName -Encoding UTF8
        }
        $skipped++
        continue
    }

    Write-DebugLog "  NFO: $nfoPath"

    $targetDate = $null

    try {
        $nfoContent = Get-Content -LiteralPath $nfoPath -Raw -Encoding UTF8
        [xml]$nfo   = $nfoContent

        # Primary: <premiered>YYYY-MM-DD</premiered>
        $premieredStr = Get-NfoTextValue -Document $nfo -XPath '/movie/premiered'
        Write-DebugLog "  premiered = '$premieredStr'"

        if (-not [string]::IsNullOrWhiteSpace($premieredStr)) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact(
                    $premieredStr.Trim(),
                    'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::None,
                    [ref]$parsed)) {
                # Treat dates more than 30 days in the future as corrupted metadata
                # (e.g. typos like 2038-01-01). Leave $targetDate null so the
                # file-timestamp -> folder-date fallback chain resolves the date,
                # which also retroactively corrects files set by a previous bad run.
                if ($parsed.Date -gt (Get-Date).Date.AddDays(30)) {
                    # If <year> is present and earlier than the corrupt premiered year,
                    # substitute it to recover the correct date (keeps month and day).
                    $yearStr2 = Get-NfoTextValue -Document $nfo -XPath '/movie/year'
                    $yr2 = 0
                    if (-not [string]::IsNullOrWhiteSpace($yearStr2) -and
                        [int]::TryParse($yearStr2.Trim(), [ref]$yr2) -and
                        $yr2 -gt 1800 -and $yr2 -lt $parsed.Year) {
                        $corrected = [datetime]::new($yr2, $parsed.Month, $parsed.Day)
                        if ($corrected.Date -le (Get-Date).Date.AddDays(30)) {
                            $targetDate = $corrected
                            Write-DebugLog "  premiered year corrected using <year> $($yr2): $($targetDate.ToString('yyyy-MM-dd'))"
                        }
                        else {
                            Write-Warning "NFO premiered date '$premieredStr' in '$([System.IO.Path]::GetFileName($nfoPath))': year-corrected date $($corrected.ToString('yyyy-MM-dd')) is still in the future - falling back to file/folder timestamps"
                        }
                    }
                    else {
                        Write-Warning "NFO premiered date '$premieredStr' in '$([System.IO.Path]::GetFileName($nfoPath))' is more than 30 days in the future - treating as corrupt; falling back to file/folder timestamps"
                    }
                }
                else {
                    $targetDate = $parsed
                    Write-DebugLog "  Using premiered: $($targetDate.ToString('yyyy-MM-dd'))"
                }
            }
            else {
                Write-DebugLog "  premiered could not be parsed as yyyy-MM-dd"
            }
        }

        # Fallback: <year>YYYY</year>  ->  January 1 of that year
        if ($null -eq $targetDate) {
            $yearStr = Get-NfoTextValue -Document $nfo -XPath '/movie/year'
            Write-DebugLog "  year = '$yearStr'"
            if (-not [string]::IsNullOrWhiteSpace($yearStr)) {
                $yr = 0
                if ([int]::TryParse($yearStr.Trim(), [ref]$yr) -and $yr -gt 1800 -and $yr -lt 2200) {
                    $yearDate = [datetime]::new($yr, 1, 1)
                    if ($yearDate.Date -gt (Get-Date).Date.AddDays(30)) {
                        Write-Warning "NFO year '$yearStr' in '$([System.IO.Path]::GetFileName($nfoPath))' resolves to a date more than 30 days in the future - treating as corrupt; falling back to file/folder timestamps"
                    }
                    else {
                        $targetDate = $yearDate
                        Write-DebugLog "  Using year fallback: $($targetDate.ToString('yyyy-MM-dd'))"
                    }
                }
                else {
                    Write-DebugLog "  year value '$yearStr' is not a valid year"
                }
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
        $earliest  = Get-EarliestFileDate -FileA $video -FileB $nfoItem
        $candidate = [datetime]::new($earliest.Year, $earliest.Month, $earliest.Day, 12, 0, 0)
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
Write-Host "Done.  Processed: $processed   Skipped (no NFO): $skipped   Filtered (extras/trailers): $filtered   Errors: $errors"
