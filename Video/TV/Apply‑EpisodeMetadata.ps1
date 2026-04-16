<#
.SYNOPSIS
Applies episode metadata from NFO files to MKV files using mkvpropedit.

.DESCRIPTION
Reads metadata from basename.nfo (episode-level) and writes it into MKV
container tags. Supports multi-episode NFOs by merging titles, plots, and
episode ranges. If showtitle is missing, the script optionally falls back to
movie.nfo in the same directory. If still missing, the script falls back to the
parent directory name (series folder). The script preserves file timestamps,
supports dry-run mode, optional debug output, and optional audit logging.
Logging is disabled when AuditLogPath is empty.

.PARAMETER DryRun
Performs all processing steps but does not modify any MKV files.

.PARAMETER Debug
Enables verbose debug output to the console. Debug messages are also written to
the audit log when logging is enabled.

.PARAMETER AuditLogPath
Specifies the path to the audit log file. Logging is disabled when this value
is empty or not provided.

.NOTES
This script is literal-path safe and deterministic. It preserves the original
CreationTime and LastWriteTime of each MKV file after metadata updates.
#>

param(
    [switch]$DryRun,
    [switch]$Debug,
    [string]$AuditLogPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Logging enable/disable
$LoggingEnabled = -not [string]::IsNullOrWhiteSpace($AuditLogPath)

function Write-Audit {
    param([string]$Message)
    if (-not $LoggingEnabled) { return }
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    "$timestamp  $Message" | Out-File -LiteralPath $AuditLogPath -Append -Encoding UTF8
}

function DebugLog {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message"
        if ($LoggingEnabled) { Write-Audit "[DEBUG] $Message" }
    }
}

# Safe XML accessor
function Get-XmlValue {
    param($Node, [string]$Name)
    if ($Node -eq $null) { return $null }
    $prop = $Node.PSObject.Properties.Match($Name)
    if ($prop.Count -gt 0) { return $prop.Value }
    return $null
}

# Normalize titles for comparison
function Normalize-Title {
    param([string]$s)
    if (-not $s) { return "" }
    return ($s.Trim() -replace "\s+", " ")
}

# Safe MKV title reader
function Get-MkvTitle {
    param([string]$MkvPath)
    DebugLog "Reading MKV title via mkvinfo: $MkvPath"
    $mkvinfo = & mkvinfo $MkvPath 2>$null
    $match = [regex]::Match($mkvinfo, "Title:\s*(.+)")
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

# Build MKV tags XML
function Build-TagsXml {
    param([hashtable]$Tags)
    $xml = "<Tags>`n  <Tag>`n"
    foreach ($key in $Tags.Keys) {
        $escaped = [System.Security.SecurityElement]::Escape($Tags[$key])
        $xml += "    <Simple><Name>$key</Name><String>$escaped</String></Simple>`n"
    }
    $xml += "  </Tag>`n</Tags>"
    return $xml
}

Write-Host "Scanning recursively for MKV files..."
Write-Audit "=== Episode run started ==="

$mkvs = Get-ChildItem -LiteralPath . -Recurse -Filter *.mkv

foreach ($mkv in $mkvs) {

    Write-Host "----"
    Write-Host "Processing MKV: $($mkv.FullName)"
    Write-Audit "Processing MKV: $($mkv.FullName)"

    $nfoPath = Join-Path $mkv.DirectoryName ($mkv.BaseName + ".nfo")

    if (-not (Test-Path -LiteralPath $nfoPath)) {
        Write-Host "Skipping: No matching NFO found."
        Write-Audit "Skipped: Missing NFO"
        continue
    }

    #
    # MULTI-EPISODE SAFE NFO PARSING
    #
    $nfoRaw = Get-Content -LiteralPath $nfoPath -Raw
    $episodeBlocks = [regex]::Matches($nfoRaw, "<episodedetails>.*?</episodedetails>", "Singleline")

    if ($episodeBlocks.Count -eq 0) {
        Write-Host "Skipping: Not episode NFO."
        Write-Audit "Skipped: Not episode NFO"
        continue
    }

    # Parse all episodes into an array
    $episodes = @()
    foreach ($block in $episodeBlocks) {
        [xml]$xmlEp = $block.Value
        $episodes += $xmlEp.episodedetails
    }

    # Episode 1 is authoritative for most metadata
    $ep1 = $episodes[0]

    # Extract base metadata from episode 1
    $season = Get-XmlValue -Node $ep1 -Name "season"
    $aired  = Get-XmlValue -Node $ep1 -Name "aired"
    $airedYear = if ($aired) { $aired.Substring(0,4) } else { "" }

    #
    # SERIES TITLE RESOLUTION
    #
    $series = Get-XmlValue -Node $ep1 -Name "showtitle"

    if (-not $series) {
        $movieNfo = Join-Path $mkv.DirectoryName "movie.nfo"
        if (Test-Path -LiteralPath $movieNfo) {
            DebugLog "Loading title from movie.nfo"
            [xml]$movieXml = Get-Content -LiteralPath $movieNfo -Raw
            $series = Get-XmlValue -Node $movieXml.movie -Name "title"
        }
    }

    if (-not $series) {
        $seriesRoot = $mkv.Directory.Parent
        if ($seriesRoot -ne $null) {
            $series = Split-Path $seriesRoot.FullName -Leaf
            DebugLog "Fallback to series root folder name: $series"
        }
    }

    #
    # MERGE TITLES, PLOTS, AND EPISODE RANGE
    #
    $titles = @()
    $plots  = @()
    $episodeNums = @()

    foreach ($ep in $episodes) {
        $t = Get-XmlValue -Node $ep -Name "title"
        $p = Get-XmlValue -Node $ep -Name "plot"
        $e = Get-XmlValue -Node $ep -Name "episode"

        if ($t) { $titles += $t.Trim() }
        if ($p) { $plots  += $p }
        if ($e) { $episodeNums += [int]$e }
    }

    # Merge titles: Title1 / Title2 / Title3 ...
    $mergedTitle = ($titles -join " / ")

    # Enforce max title length of 30 characters
    $maxLen = 30
    if ($mergedTitle.Length -gt $maxLen) {
        $mergedTitle = $mergedTitle.Substring(0, $maxLen)
    }

    # Merge plots:
    # Part 1 – Plot1
    # Part 2 – Plot2
    # ...
    $mergedPlot = ""
    for ($i = 0; $i -lt $plots.Count; $i++) {
        $partNum = $i + 1
        $mergedPlot += "Part $partNum – $($plots[$i])"
        if ($i -lt $plots.Count - 1) { $mergedPlot += "`n" }
    }

    # Episode range: min-max
    $minEp = ($episodeNums | Measure-Object -Minimum).Minimum
    $maxEp = ($episodeNums | Measure-Object -Maximum).Maximum
    $episodeTag = if ($minEp -eq $maxEp) { "$minEp" } else { "$minEp-$maxEp" }

    # Final merged values
    $title = $mergedTitle
    $plot  = $mergedPlot
    $episodeNum = $episodeTag

    #
    # BUILD TAGS
    #
    $tags = @{
        TITLE         = $title
        SERIES        = $series
        SEASON        = $season
        EPISODE       = $episodeNum
        DESCRIPTION   = $plot
        DATE_RELEASED = $airedYear
    }

    #
    # TITLE CHECK
    #
    $existingTitle = Get-MkvTitle -MkvPath $mkv.FullName
    $newGlobalTitle = "$series - $title"

    $existingNorm = Normalize-Title $existingTitle
    $newNorm      = Normalize-Title $newGlobalTitle

    DebugLog "Existing MKV title: '$existingTitle'"
    DebugLog "Expected MKV title: '$newGlobalTitle'"

    if ($existingNorm -eq $newNorm) {
        Write-Host "Skipping: Already processed."
        Write-Audit "Skipped: Already processed"
        continue
    }

    #
    # PRESERVE TIMESTAMPS
    #
    $file = Get-Item -LiteralPath $mkv.FullName
    $origCreation = $file.CreationTime
    $origModified = $file.LastWriteTime

    DebugLog "Preserving timestamps."

    #
    # APPLY METADATA
    #
    $tagsXml = Build-TagsXml -Tags $tags
    $tempTags = Join-Path $env:TEMP "episode_tags_$(Get-Random).xml"
    $tagsXml | Out-File -LiteralPath $tempTags -Encoding UTF8

    if (-not $DryRun) {

        & mkvpropedit $mkv.FullName --edit info --set "title="
        & mkvpropedit $mkv.FullName --edit info --set "title=$newGlobalTitle"
        & mkvpropedit $mkv.FullName --tags all:$tempTags

        Set-ItemProperty -LiteralPath $mkv.FullName -Name CreationTime -Value $origCreation
        Set-ItemProperty -LiteralPath $mkv.FullName -Name LastWriteTime -Value $origModified

        Write-Audit "Metadata applied"
    }
    else {
        Write-Audit "Dry-run: No changes applied"
    }

    Remove-Item -LiteralPath $tempTags -Force
}

Write-Audit "=== Episode run complete ==="
