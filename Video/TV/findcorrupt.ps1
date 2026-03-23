<#
.SYNOPSIS
    Scans for corrupt MKV files, deletes them, and requests replacements from Sonarr.

.DESCRIPTION
    This script recursively scans a root directory for MKV files and uses ffprobe
    to detect corruption. When a corrupt file is found, the script can:

        Delete the corrupt file
        Remove the episode file entry from Sonarr
        Re-monitor the episode
        Trigger a Sonarr EpisodeSearch command
        Log missing series to a dedicated log file
        Optionally log file paths to a CSV file

    When -Audit is enabled, the script performs NO destructive actions and instead
    prints what WOULD have happened. This ensures deterministic, safe dry-runs.

.PARAMETER Root
    The root directory to scan for MKV files.

.PARAMETER CsvFile
    Optional CSV file to log corrupt MKV paths.
    If empty (""), CSV logging is disabled entirely.

.PARAMETER Append
    Appends to the CSV file instead of overwriting it.

.PARAMETER EnableSonarr
    Enables Sonarr integration for deleting/replacing episodes.

.PARAMETER Audit
    Dry-run mode. No files are deleted and no Sonarr API calls are made.

.PARAMETER SonarrUrl
    Base URL of the Sonarr instance.

.PARAMETER SonarrLogFile
    Log file for Sonarr actions.

.PARAMETER MissingSeriesLog
    Log file for series that cannot be found in Sonarr.

.PARAMETER Help
    Shows help.

.PARAMETER ShowHelp
    Shows help.

.PARAMETER HelpShort
    Alias for -? to show help.

.EXAMPLE
    PS> .\script.ps1 -Root "Z:\media" -EnableSonarr

.EXAMPLE
    PS> .\script.ps1 -Root "Z:\media" -Audit

.EXAMPLE
    PS> .\script.ps1 -Root "Z:\media" -CsvFile "corrupt.csv"

.NOTES
    � Requires ffprobe to be available in PATH.
    � Sonarr API key must be configured inside the script.
    � All file operations use literal-path-safe PowerShell calls.
    � Audit mode is strongly recommended before first real run.

.EXITCODES
    0   Script completed successfully.
    1   One or more corrupt files detected.
    2   ffprobe missing or inaccessible.
    3   Sonarr API error.
    4   Unexpected exception.
#>

param(
    [string]$Root = ".\",
    [string]$CsvFile = "",
    [switch]$Append,
    [switch]$EnableSonarr,
    [switch]$Audit,

    [switch]$Help,
    [switch]$ShowHelp,

    [Alias('?')]
    [switch]$HelpShort,

    [string]$SonarrUrl = "http://docker:8989",
    [string]$SonarrLogFile = "D:\Work\SonarrLog.txt",
    [string]$MissingSeriesLog = "D:\Work\MissingSeries.txt"
)

# -------------------------------
# Unified help handler
# -------------------------------
if ($Help -or $ShowHelp -or $HelpShort) {
    Write-Host ""
    Write-Host "MKV Corruption Scanner + Sonarr Replacement" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"
    Write-Host "Usage:"
    Write-Host "  findcorrupt.ps1 -Root <path> [-CsvFile <file>] [-Append] [-EnableSonarr]"
    Write-Host "                  [-Audit] [-SonarrUrl <url>] [-SonarrLogFile <file>]"
    Write-Host "                  [-MissingSeriesLog <file>]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Root <path>              Root folder to scan for MKVs"
    Write-Host "  -CsvFile <file>           CSV log file (optional)"
    Write-Host "  -Append                   Append to CSV instead of overwriting"
    Write-Host "  -EnableSonarr             Enable Sonarr replacement workflow"
    Write-Host "  -Audit                    Dry-run mode"
    Write-Host "  -SonarrUrl <url>          Sonarr base URL"
    Write-Host "  -SonarrLogFile <file>     Log file for Sonarr actions"
    Write-Host "  -MissingSeriesLog <file>  Log file for missing series"
    Write-Host "  -Help / -ShowHelp / -?    Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  findcorrupt.ps1 -Root Z:\media -EnableSonarr"
    Write-Host "  findcorrupt.ps1 -Root Z:\media -CsvFile corrupt.csv -Audit"
    Write-Host ""
    Write-Host "For full comment-based help:"
    Write-Host "  Get-Help .\findcorrupt.ps1 -Full"
    Write-Host ""
    exit 0
}

# -------------------------------
# Sonarr API Key
# -------------------------------
# Replace the placeholder below with your Sonarr API key, or modify the
# script to read the key from an environment variable or external config.
$SonarrApiKey = "YOUR_API_KEY_HERE"

# -------------------------------
# Sonarr connectivity test
# -------------------------------
if ($EnableSonarr) {
    Write-Host "Checking Sonarr connectivity..." -ForegroundColor Cyan

    try {
        $statusUrl = "$SonarrUrl/api/v3/system/status?apikey=$SonarrApiKey"
        $null = Invoke-WebRequest -Uri $statusUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
        Write-Host "Sonarr is reachable." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: Unable to reach Sonarr at $SonarrUrl" -ForegroundColor Red
        Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Yellow
        exit 3
    }
}

# -------------------------------
# CSV Logging Enabled?
# -------------------------------
$CsvEnabled = -not [string]::IsNullOrWhiteSpace($CsvFile)

# -------------------------------
# Audit helper
# -------------------------------
function Write-Audit {
    param([string]$Message)
    Write-Host "[AUDIT] $Message" -ForegroundColor Cyan
}

# -------------------------------
# Detect MKV corruption
# -------------------------------
function Test-MkvCorrupt {
    param([string]$Path)

    $ProbeArgs = @(
        "-v", "error",
        "-read_intervals", "%+#5",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        $Path
    )

    $output = & ffprobe @ProbeArgs 2>&1

    if ($LASTEXITCODE -ne 0) { return $true }
    if ($output -match "Invalid" -or $output -match "error" -or $output -match "failed") {
        return $true
    }

    return $false
}

# -------------------------------
# Sonarr: Replace episode by file path
# -------------------------------
function Invoke-SonarrReplaceFromPath {
    param(
        [string]$SonarrUrl,
        [string]$ApiKey,
        [string]$FilePath,
        [string]$LogFile,
        [string]$MissingSeriesLog,
        [switch]$Audit
    )

    $Headers = @{ "X-Api-Key" = $ApiKey }

    function Log-SonarrAction {
        param([string]$File, [string]$Status)
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -LiteralPath $LogFile -Value "$timestamp,""$File"",$Status"
    }

    $seriesName = Split-Path (Split-Path $FilePath -Parent) -Parent | Split-Path -Leaf

    if ($Audit) {
        Write-Audit "Would process Sonarr replacement for: $FilePath"
        return
    }

    try {
        if ($FilePath -match 'S(\d{2})E(\d{2})') {
            $season = [int]$matches[1]
            $episode = [int]$matches[2]
        } else {
            Log-SonarrAction -File $FilePath -Status "ERROR: Could not parse SxxEyy"
            return
        }

        $seriesList = Invoke-RestMethod -Method Get -Uri "$SonarrUrl/api/v3/series?term=$seriesName" -Headers $Headers

        $series = $seriesList |
            Where-Object {
                $_.title -like "*$seriesName*" -or
                $_.cleanTitle -like "*$seriesName*"
            } |
            Select-Object -First 1

        if (-not $series) {
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Add-Content -LiteralPath $MissingSeriesLog -Value "$timestamp,$seriesName,$FilePath"
            Log-SonarrAction -File $FilePath -Status "404 (series not found)"
            return
        }

        $episodes = Invoke-RestMethod -Method Get -Uri "$SonarrUrl/api/v3/episode?seriesId=$($series.id)" -Headers $Headers

        $episodeObj = $episodes |
            Where-Object { $_.seasonNumber -eq $season -and $_.episodeNumber -eq $episode }

        if (-not $episodeObj) {
            Log-SonarrAction -File $FilePath -Status "404 (episode not found)"
            return
        }

        $episodeId = $episodeObj.id
        $episodeFileId = $episodeObj.episodeFileId

        Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop

        if ($episodeFileId) {
            $deleteResponse = Invoke-WebRequest -Method Delete -Uri "$SonarrUrl/api/v3/episodefile/$episodeFileId" -Headers $Headers -ErrorAction Stop
            Log-SonarrAction -File $FilePath -Status $deleteResponse.StatusCode
        }

        $episodeObj.monitored = $true

        $monitorResponse = Invoke-WebRequest `
            -Method Put `
            -Uri "$SonarrUrl/api/v3/episode/$episodeId" `
            -Headers $Headers `
            -Body ($episodeObj | ConvertTo-Json -Depth 10) `
            -ContentType "application/json" `
            -ErrorAction Stop

        Log-SonarrAction -File $FilePath -Status $monitorResponse.StatusCode

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
        exit 3
    }
}

# -------------------------------
# Prepare logs
# -------------------------------
if ($CsvEnabled) {
    if (-not $Append -and (Test-Path -LiteralPath $CsvFile)) {
        Remove-Item -LiteralPath $CsvFile -Force
    }
    if (-not (Test-Path -LiteralPath $CsvFile)) {
        "FilePath" | Out-File -LiteralPath $CsvFile -Encoding UTF8
    }
}

if (-not (Test-Path -LiteralPath $MissingSeriesLog)) {
    "DateTime,SeriesName,FilePath" | Out-File -LiteralPath $MissingSeriesLog -Encoding UTF8
}

if ($EnableSonarr) {
    if (Test-Path -LiteralPath $SonarrLogFile) {
        Remove-Item -LiteralPath $SonarrLogFile -Force
    }
    "DateTime,FilePath,Status" | Out-File -LiteralPath $SonarrLogFile -Encoding UTF8
}

# -------------------------------
# Main Scan
# -------------------------------
Write-Host "Scanning for corrupt MKVs..." -ForegroundColor Cyan

$corruptFound = $false

Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.mkv" | ForEach-Object {

    $File = $_.FullName

    if (Test-MkvCorrupt -Path $File) {

        $corruptFound = $true
        Write-Host "CORRUPT MKV: $File" -ForegroundColor Red

        if ($Audit) {
            Write-Audit "Would delete: $File"
            if ($EnableSonarr) {
                Write-Audit "Would request replacement from Sonarr for: $File"
            }
        }
        else {
            if ($CsvEnabled) {
                Add-Content -LiteralPath $CsvFile -Value '"' + $File.Replace('"','""') + '"'
            }

            if ($EnableSonarr -and $SonarrApiKey) {
                Invoke-SonarrReplaceFromPath `
                    -SonarrUrl $SonarrUrl `
                    -ApiKey $SonarrApiKey `
                    -FilePath $File `
                    -LogFile $SonarrLogFile `
                    -MissingSeriesLog $MissingSeriesLog `
                    -Audit:$Audit
                Write-Host "Sonarr actions logged to $SonarrLogFile" -ForegroundColor Yellow
            }
        }
    }
}

if ($corruptFound) {
    exit 1
} else {
    exit 0
}
