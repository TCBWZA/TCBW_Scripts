<#
.SYNOPSIS
    Scans MKV files for foreign-only audio tracks and optionally triggers
    Sonarr episode replacement. Supports optional CSV logging.

.DESCRIPTION
    This script recursively scans a root directory for MKV files, extracts
    audio language metadata using ffprobe, and identifies files that contain
    no allowed languages (default: eng, und). When a file is foreign-only,
    the script can:
        - Log results to a CSV file (if CsvFile is provided)
        - Trigger Sonarr to delete and re-search the episode file (enabled by default)

    The script includes full audit-safe parameter validation to prevent
    ambiguous or unsafe behaviour, including:
        - Append requires CsvFile
        - CsvFile must be a valid file path
        - Sonarr logging requires valid log directory
        - Root must exist and be a directory

.PARAMETER Root
    The root directory to scan. Must be an existing directory.

.PARAMETER CsvFile
    Optional. Path to a CSV file for logging results. If omitted, CSV logging
    is disabled. If provided, the directory must exist.

.PARAMETER Append
    Appends to the existing CSV file instead of overwriting it.
    Requires CsvFile to be specified.

.PARAMETER NoSonarr
    Disables Sonarr integration. Sonarr is enabled by default.

.PARAMETER SonarrUrl
    Base URL for the Sonarr instance.

.PARAMETER SonarrLogFile
    Path to the Sonarr action log file. Directory must exist if Sonarr is enabled.

.EXAMPLE
    PS> .\Scan-ForeignAudio.ps1 -Root "D:\Media"

    Scans for foreign-only audio tracks with Sonarr enabled and no CSV logging.

.EXAMPLE
    PS> .\Scan-ForeignAudio.ps1 -Root "D:\Media" -CsvFile "D:\Logs\foreign.csv"

    Scans and logs results to the specified CSV file.

.EXAMPLE
    PS> .\Scan-ForeignAudio.ps1 -Root "D:\Media" -CsvFile "D:\Logs\foreign.csv" -Append

    Appends results to an existing CSV file.

.EXAMPLE
    PS> .\Scan-ForeignAudio.ps1 -Root "D:\Media" -NoSonarr

    Scans with Sonarr disabled.

.NOTES
    Author: Duncan
    Version: 1.1.0
    Requires: ffprobe, PowerShell 5.1+ or PowerShell 7+
#>

param(
    [string]$Root = ".\",

    [string]$CsvFile,

    [switch]$Append,

    # Sonarr enabled by default
    [switch]$NoSonarr,

    [string]$SonarrUrl = "http://docker:8989",

    [string]$SonarrLogFile = "D:\Work\SonarrLog.txt"
)

# -------------------------------
# Sonarr API Key
# -------------------------------
$SonarrApiKey = "YOUR_API_KEY_HERE"

# -------------------------------
# Compute effective Sonarr state
# -------------------------------
$EnableSonarr = -not $NoSonarr

# -------------------------------
# Parameter Validation (Audit-Safe)
# -------------------------------

# Validate: CsvFile must be a non-empty string if provided
if ($CsvFile -and [string]::IsNullOrWhiteSpace($CsvFile)) {
    Write-Error "CsvFile was provided but is empty or whitespace. Provide a valid literal path or omit the parameter."
    exit 1
}

# Validate: -Append requires CsvFile
if (-not $CsvFile -and $Append) {
    Write-Error "Invalid usage: -Append requires -CsvFile <path>. Append cannot be used when CSV logging is disabled."
    exit 1
}

# Validate: CsvFile must not be a directory
if ($CsvFile -and (Test-Path -LiteralPath $CsvFile -PathType Container)) {
    Write-Error "CsvFile points to a directory. Provide a file path, not a folder."
    exit 1
}

# Validate: CsvFile parent directory must exist
if ($CsvFile) {
    $CsvParent = Split-Path -LiteralPath $CsvFile -Parent
    if ($CsvParent -and -not (Test-Path -LiteralPath $CsvParent)) {
        Write-Error "The directory for CsvFile does not exist: $CsvParent"
        exit 1
    }
}

# Validate: Sonarr settings only if enabled
if ($EnableSonarr) {

    if ([string]::IsNullOrWhiteSpace($SonarrLogFile)) {
        Write-Error "Sonarr is enabled but SonarrLogFile is empty or whitespace."
        exit 1
    }

    $SonarrLogDir = Split-Path -LiteralPath $SonarrLogFile -Parent
    if (-not (Test-Path -LiteralPath $SonarrLogDir)) {
        Write-Error "SonarrLogFile directory does not exist: $SonarrLogDir"
        exit 1
    }

    if ($SonarrApiKey -eq "" -or $null -eq $SonarrApiKey) {
        Write-Error "Sonarr is enabled but SonarrApiKey is missing."
        exit 1
    }
}

# Validate: Root must exist and be a directory
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Error "Root path does not exist or is not a directory: $Root"
    exit 1
}

# -------------------------------
# Extract audio languages
# -------------------------------
function Get-AudioLanguages {
    param([string]$Path)

    $ProbeArgs = @(
        "-v", "error",
        "-select_streams", "a",
        "-show_entries", "stream_tags=language",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $Path
    )

    $Languages = & ffprobe @ProbeArgs 2>$null

    if (-not $Languages -or $Languages.Count -eq 0) {
        return @("und")
    }

    return $Languages | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_)) { "und" }
        else { $_.Trim().ToLower() }
    }
}

# -------------------------------
# Sonarr: Replace episode by file path
# -------------------------------
function Invoke-SonarrReplaceFromPath {
    param(
        [string]$SonarrUrl,
        [string]$ApiKey,
        [string]$FilePath,
        [string]$LogFile
    )

    $Headers = @{ "X-Api-Key" = $ApiKey }

    function Log-SonarrAction {
        param([string]$File, [string]$Status)
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -LiteralPath $LogFile -Value "$timestamp,""$File"",$Status"
    }

    try {
        # Extract series name
        $seriesName = Split-Path (Split-Path $FilePath -Parent) -Parent | Split-Path -Leaf

        # Extract SxxEyy
        if ($FilePath -match 'S(\d{2})E(\d{2})') {
            $season = [int]$matches[1]
            $episode = [int]$matches[2]
        } else {
            Log-SonarrAction -File $FilePath -Status "ERROR: Could not parse SxxEyy"
            return
        }

        # 1. Find series
        $seriesList = Invoke-RestMethod -Method Get -Uri "$SonarrUrl/api/v3/series?term=$seriesName" -Headers $Headers

        $series = $seriesList |
            Where-Object {
                $_.title -like "*$seriesName*" -or
                $_.cleanTitle -like "*$seriesName*"
            } |
            Select-Object -First 1

        if (-not $series) {
            Log-SonarrAction -File $FilePath -Status "404 (series not found)"
            return
        }

        # 2. Get episodes
        $episodes = Invoke-RestMethod -Method Get -Uri "$SonarrUrl/api/v3/episode?seriesId=$($series.id)" -Headers $Headers

        $episodeObj = $episodes |
            Where-Object { $_.seasonNumber -eq $season -and $_.episodeNumber -eq $episode }

        if (-not $episodeObj) {
            Log-SonarrAction -File $FilePath -Status "404 (episode not found)"
            return
        }

        $episodeId = $episodeObj.id
        $episodeFileId = $episodeObj.episodeFileId

        if (-not $episodeFileId) {
            Log-SonarrAction -File $FilePath -Status "404 (episodeFileId missing)"
            return
        }

        # 4. DELETE the file
        $deleteResponse = Invoke-WebRequest -Method Delete -Uri "$SonarrUrl/api/v3/episodefile/$episodeFileId" -Headers $Headers -ErrorAction Stop
        Log-SonarrAction -File $FilePath -Status $deleteResponse.StatusCode

        # 5. Re-monitor
        $episodeObj.monitored = $true

        $monitorResponse = Invoke-WebRequest `
            -Method Put `
            -Uri "$SonarrUrl/api/v3/episode/$episodeId" `
            -Headers $Headers `
            -Body ($episodeObj | ConvertTo-Json -Depth 10) `
            -ContentType "application/json" `
            -ErrorAction Stop

        Log-SonarrAction -File $FilePath -Status $monitorResponse.StatusCode

        # 6. Trigger search
        $body = @{
            name       = "EpisodeSearch"
            episodeIds = @($episodeId)
        } | ConvertTo-Json

        $searchResponse = Invoke-WebRequest `
            -Method Post `
            -Uri "$SonarrUrl/api/v3/command" `
            -Headers $Headers `
            -Body $body `
            -ContentType "application/json" `
            -ErrorAction Stop

        Log-SonarrAction -File $FilePath -Status $searchResponse.StatusCode

    }
    catch {
        Log-SonarrAction -File $FilePath -Status "ERROR: $($_.Exception.Message)"
    }
}

# -------------------------------
# Script start
# -------------------------------
$AllowedLanguages = @("eng", "und")

# Prepare main CSV only if a file was supplied
if ($CsvFile) {

    if (-not $Append -and (Test-Path -LiteralPath $CsvFile)) {
        Remove-Item -LiteralPath $CsvFile -Force
    }

    if (-not (Test-Path -LiteralPath $CsvFile)) {
        "FilePath,Languages" | Out-File -LiteralPath $CsvFile -Encoding UTF8
    }
}

# Prepare Sonarr log
if ($EnableSonarr) {

    if (Test-Path -LiteralPath $SonarrLogFile) {
        Remove-Item -LiteralPath $SonarrLogFile -Force
    }

    "DateTime,FilePath,Status" | Out-File -LiteralPath $SonarrLogFile -Encoding UTF8
}

Write-Host "Scanning for MKVs with *foreign-only* audio tracks..." -ForegroundColor Cyan

Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.mkv" | ForEach-Object {

    $File = $_.FullName
    $LangList = Get-AudioLanguages -Path $File

    # Foreign-only = no eng, no und
    $HasAllowed = $LangList | Where-Object { $AllowedLanguages -contains $_ }

    if ($HasAllowed.Count -eq 0) {

        Write-Host "Foreign-only audio: $File" -ForegroundColor Yellow

        if ($CsvFile) {
            $LangString = $LangList -join ";"
            $csvLine = '"' + $File.Replace('"','""') + '","' + $LangString.Replace('"','""') + '"'
            Add-Content -LiteralPath $CsvFile -Value $csvLine
        }

        if ($EnableSonarr -and $SonarrApiKey) {
            Invoke-SonarrReplaceFromPath `
                -SonarrUrl $SonarrUrl `
                -ApiKey $SonarrApiKey `
                -FilePath $File `
                -LogFile $SonarrLogFile
        }
    }
}
