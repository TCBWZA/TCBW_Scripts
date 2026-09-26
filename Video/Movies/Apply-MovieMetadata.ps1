<#
.SYNOPSIS
Applies movie metadata from NFO files to MKV files using mkvpropedit.

.DESCRIPTION
Reads metadata from basename.nfo (preferred) or movie.nfo (fallback) and writes
it into MKV container tags. The script preserves file timestamps, supports
dry-run mode, optional debug output, and optional audit logging. Logging is
disabled when AuditLogPath is empty.

.PARAMETER DryRun
Performs all processing steps but does not modify any MKV files.

.PARAMETER Debug
Enables verbose debug output to the console. Debug messages are also written to
the audit log when logging is enabled.

.PARAMETER AuditLogPath
Specifies the path to the audit log file. Logging is disabled when this value
is empty or not provided.

.EXAMPLE
.\Apply-MovieMetadata.ps1 -Debug

.EXAMPLE
.\Apply-MovieMetadata.ps1 -AuditLogPath ".\movie_audit.log"

.NOTES
This script is literal-path safe and deterministic. It preserves the original
CreationTime and LastWriteTime of each MKV file after metadata updates.

.REQUIREMENTS
mkvtoolnix (mkvpropedit, mkvinfo)
PowerShell 5 or PowerShell 7

.CHOCOLATEY
choco install mkvtoolnix
choco install powershell-core

.LINK
https://mkvtoolnix.download/
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

function Write-DebugLog {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message"
        if ($LoggingEnabled) { Write-Audit "[DEBUG] $Message" }
    }
}

# Safe XML accessor
function Get-XmlValue {
    param($Node, [string]$Name)
    if ($null -eq $Node) { return $null }
    $prop = $Node.PSObject.Properties.Match($Name)
    if ($prop.Count -gt 0) { return $prop.Value }
    return $null
}

# MKV tags reader
function Get-MkvTags {
    param([string]$MkvPath)
    Write-DebugLog "Reading MKV tags via mkvextract: $MkvPath"
    $tmp = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), ".xml")
    try {
        & mkvextract $MkvPath tags $tmp 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $tmp) -or (Get-Item -LiteralPath $tmp).Length -eq 0) {
            return @{}
        }
        [xml]$xml = Get-Content -LiteralPath $tmp -Raw
        $result = @{}
        foreach ($simple in $xml.Tags.Tag.Simple) {
            if ($simple.Name) { $result[$simple.Name] = $simple.String }
        }
        return $result
    }
    catch { return @{} }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
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
Write-Audit "=== Movie run started ==="

$mkvs = Get-ChildItem -LiteralPath . -Recurse -Filter *.mkv

foreach ($mkv in $mkvs) {

    # Skip if directory .skip marker exists
    if (Test-Path -LiteralPath (Join-Path $mkv.DirectoryName ".skip")) {
        Write-Host "Skipping $($mkv.FullName) -- .skip directory marker found"
        continue
    }

    # Skip if per-file .skip_<basename> marker exists
    if (Test-Path -LiteralPath (Join-Path $mkv.DirectoryName ".skip_$($mkv.BaseName)")) {
        Write-Host "Skipping $($mkv.FullName) -- .skip_$($mkv.BaseName) per-file marker found"
        continue
    }

    Write-Host "----"
    Write-Host "Processing MKV: $($mkv.FullName)"
    Write-Audit "Processing MKV: $($mkv.FullName)"

    # Preferred: basename.nfo
    $basenameNfo = Join-Path $mkv.DirectoryName ($mkv.BaseName + ".nfo")

    # Fallback: movie.nfo
    $movieNfo = Join-Path $mkv.DirectoryName "movie.nfo"

    $nfoPath = $null

    if (Test-Path -LiteralPath $basenameNfo) {
        $nfoPath = $basenameNfo
    }
    elseif (Test-Path -LiteralPath $movieNfo) {
        $nfoPath = $movieNfo
    }
    else {
        Write-Host "Skipping: No NFO found."
        Write-Audit "Skipped: No NFO"
        continue
    }

    [xml]$xml = Get-Content -LiteralPath $nfoPath -Raw
    if ($null -eq $xml.movie) {
        Write-Host "Skipping: Not movie NFO."
        Write-Audit "Skipped: Not movie NFO"
        continue
    }

    $mv = $xml.movie

    # Extract metadata
    $title     = Get-XmlValue -Node $mv -Name "title"
    $plot      = Get-XmlValue -Node $mv -Name "plot"
    $premiered = Get-XmlValue -Node $mv -Name "premiered"
    if (-not $premiered) {
        $premiered = Get-XmlValue -Node $mv -Name "released"
    }
    $year = if ($premiered) { $premiered.Substring(0,4) } else { "" }

    $tags = @{
        TITLE         = $title
        DESCRIPTION   = $plot
        DATE_RELEASED = $year
    }

    # Check existing MKV tags
    $existingTags = Get-MkvTags -MkvPath $mkv.FullName
    Write-DebugLog "Existing TITLE tag:        '$($existingTags['TITLE'])'"
    Write-DebugLog "Existing DATE_RELEASED tag: '$($existingTags['DATE_RELEASED'])'"

    if ($existingTags['TITLE'] -eq $title -and $existingTags['DATE_RELEASED'] -eq $year) {
        Write-Host "Skipping: Already processed."
        Write-Audit "Skipped: Already processed"
        continue
    }

    # Preserve timestamps
    $file = Get-Item -LiteralPath $mkv.FullName
    $origCreation = $file.CreationTime
    $origModified = $file.LastWriteTime

    Write-DebugLog "Preserving timestamps."

    # Apply metadata
    $tagsXml = Build-TagsXml -Tags $tags
    $tempTags = Join-Path $env:TEMP "movie_tags_$(Get-Random).xml"
    $tagsXml | Out-File -LiteralPath $tempTags -Encoding UTF8

    if (-not $DryRun) {
        # Remove existing MKV title to ensure replacement works
        & mkvpropedit $mkv.FullName --edit info --set "title="
        & mkvpropedit $mkv.FullName --edit info --set "title=$title"
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

Write-Audit "=== Movie run complete ==="
