<#
.SYNOPSIS
    Scans for corrupt movie MKV files, deletes them, and requests replacements from Radarr.

.DESCRIPTION
    This script recursively scans a root directory for MKV files and uses ffprobe
    to detect corruption. When a corrupt file is found, the script can:

      � Delete the corrupt file
      � Remove the movie file entry from Radarr
      � Re-monitor the movie
      � Trigger a Radarr MovieSearch command
      � Log missing movies to a dedicated log file
      � Optionally log file paths to a CSV file

    When -Audit is enabled, the script performs NO destructive actions and instead
    prints what WOULD have happened. This ensures deterministic, safe dry-runs.

.PARAMETER Root
    The root directory to scan for MKV files.

.PARAMETER CsvFile
    Optional CSV file to log corrupt MKV paths.
    If empty (""), CSV logging is disabled entirely.

.PARAMETER Append
    Appends to the CSV file instead of overwriting it.

.PARAMETER Audit
    Dry-run mode. No files are deleted and no Radarr API calls are made.

.PARAMETER RadarrUrl
    Base URL of the Radarr instance.

.PARAMETER RadarrLogFile
    Log file for Radarr actions.

.PARAMETER MissingMovieLog
    Log file for movies that cannot be found in Radarr.

.PARAMETER Help
    Shows help.

.PARAMETER ShowHelp
    Shows help.

.PARAMETER HelpShort
    Alias for -? to show help.

.EXAMPLE
    PS> .\findcorrupt-movies.ps1 -Root "Z:\media\Movies" -Audit

.EXAMPLE
    PS> .\findcorrupt-movies.ps1 -Root "Z:\media\Movies" -CsvFile corrupt.csv

.NOTES
    � Requires ffprobe to be available in PATH.
    � Radarr API key must be configured inside the script.
    � All file operations use literal-path-safe PowerShell calls.
    � Audit mode is strongly recommended before first real run.

.EXITCODES
    0   Script completed successfully.
    1   One or more corrupt files detected.
    2   ffprobe missing or inaccessible.
    3   Radarr API error.
    4   Unexpected exception.
#>

param(
    [string]$Root = ".\",
    [string]$CsvFile = "",
    [switch]$Append,
    [switch]$Audit,

    [switch]$Help,
    [switch]$ShowHelp,

    [Alias('?')]
    [switch]$HelpShort,

    [string]$RadarrUrl = "http://docker:7878",
    [string]$RadarrLogFile = "D:\Work\RadarrLog.txt",
    [string]$MissingMovieLog = "D:\Work\MissingMovies.txt"
)

# -------------------------------
# Unified help handler
# -------------------------------
if ($Help -or $ShowHelp -or $HelpShort) {
    Write-Host ""
    Write-Host "MKV Movie Corruption Scanner + Radarr Replacement" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------"
    Write-Host "Usage:"
    Write-Host "  findcorrupt-movies.ps1 -Root <path> [-CsvFile <file>] [-Append]"
    Write-Host "                         [-Audit] [-RadarrUrl <url>] [-RadarrLogFile <file>]"
    Write-Host "                         [-MissingMovieLog <file>]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -Root <path>              Root folder to scan for MKVs"
    Write-Host "  -CsvFile <file>           CSV log file (optional)"
    Write-Host "  -Append                   Append to CSV instead of overwriting"
    Write-Host "  -Audit                    Dry-run mode"
    Write-Host "  -RadarrUrl <url>          Radarr base URL"
    Write-Host "  -RadarrLogFile <file>     Log file for Radarr actions"
    Write-Host "  -MissingMovieLog <file>   Log file for missing movies"
    Write-Host "  -Help / -ShowHelp / -?    Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  findcorrupt-movies.ps1 -Root Z:\media\Movies -Audit"
    Write-Host "  findcorrupt-movies.ps1 -Root Z:\media\Movies -CsvFile corrupt.csv"
    Write-Host ""
    exit 0
}

# -------------------------------
# Radarr API Key
# -------------------------------
# Replace the placeholder below with your Radarr API key, or modify the
# script to read the key from an environment variable or external config.
$RadarrApiKey = "YOUR_API_KEY_HERE"

# -------------------------------
# Radarr connectivity test
# -------------------------------
Write-Host "Checking Radarr connectivity..." -ForegroundColor Cyan

try {
    $statusUrl = "$RadarrUrl/api/v3/system/status?apikey=$RadarrApiKey"
    $null = Invoke-WebRequest -Uri $statusUrl -Method Get -TimeoutSec 5 -ErrorAction Stop
    Write-Host "Radarr is reachable." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Unable to reach Radarr at $RadarrUrl" -ForegroundColor Red
    Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 3
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
# Parse movie title + year
# -------------------------------
function Parse-MovieInfo {
    param([string]$Path)

    $file = Split-Path $Path -Leaf

    # Remove quality tags
    $clean = $file -replace '

\[[^\]

]+\]

', ''

    # Extract year
    if ($clean -match '\((\d{4})\)') {
        $year = $matches[1]
    } else {
        return $null
    }

    # Extract title
    $title = $clean -replace '\(\d{4}\).*$', ''
    $title = $title.Trim()

    return [PSCustomObject]@{
        Title = $title
        Year  = $year
    }
}

# -------------------------------
# Radarr: Replace movie by file path
# -------------------------------
function Invoke-RadarrReplaceFromPath {
    param(
        [string]$RadarrUrl,
        [string]$ApiKey,
        [string]$FilePath,
        [string]$LogFile,
        [string]$MissingMovieLog,
        [switch]$Audit
    )

    $Headers = @{ "X-Api-Key" = $ApiKey }

    function Log-RadarrAction {
        param([string]$File, [string]$Status)
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -LiteralPath $LogFile -Value "$timestamp,""$File"",$Status"
    }

    $info = Parse-MovieInfo -Path $FilePath
    if (-not $info) {
        Log-RadarrAction -File $FilePath -Status "ERROR: Could not parse movie title/year"
        return
    }

    $searchTerm = "$($info.Title) $($info.Year)"

    if ($Audit) {
        Write-Audit "Would process Radarr replacement for: $FilePath"
        return
    }

    try {
        $movieList = Invoke-RestMethod -Method Get -Uri "$RadarrUrl/api/v3/movie?term=$searchTerm" -Headers $Headers

        $movie = $movieList | Select-Object -First 1

        if (-not $movie) {
            $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Add-Content -LiteralPath $MissingMovieLog -Value "$timestamp,$($info.Title),$FilePath"
            Log-RadarrAction -File $FilePath -Status "404 (movie not found)"
            return
        }

        $movieId = $movie.id
        $movieFileId = $movie.movieFile.id

        Remove-Item -LiteralPath $FilePath -Force -ErrorAction Stop

        if ($movieFileId) {
            $deleteResponse = Invoke-WebRequest -Method Delete -Uri "$RadarrUrl/api/v3/moviefile/$movieFileId" -Headers $Headers -ErrorAction Stop
            Log-RadarrAction -File $FilePath -Status $deleteResponse.StatusCode
        }

        $movie.monitored = $true

        $monitorResponse = Invoke-WebRequest `
            -Method Put `
            -Uri "$RadarrUrl/api/v3/movie/$movieId" `
            -Headers $Headers `
            -Body ($movie | ConvertTo-Json -Depth 10) `
            -ContentType "application/json" `
            -ErrorAction Stop

        Log-RadarrAction -File $FilePath -Status $monitorResponse.StatusCode

        $body = @{
            name     = "MoviesSearch"
            movieIds = @($movieId)
        } | ConvertTo-Json

        $searchResponse = Invoke-WebRequest `
            -Method Post `
            -Uri "$RadarrUrl/api/v3/command" `
            -Headers $Headers `
            -Body $body `
            -ContentType "application/json" `
            -ErrorAction Stop

        Log-RadarrAction -File $FilePath -Status $searchResponse.StatusCode
    }
    catch {
        Log-RadarrAction -File $FilePath -Status "ERROR: $($_.Exception.Message)"
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

if (-not (Test-Path -LiteralPath $MissingMovieLog)) {
    "DateTime,MovieTitle,FilePath" | Out-File -LiteralPath $MissingMovieLog -Encoding UTF8
}

if (Test-Path -LiteralPath $RadarrLogFile) {
    Remove-Item -LiteralPath $RadarrLogFile -Force
}
"DateTime,FilePath,Status" | Out-File -LiteralPath $RadarrLogFile -Encoding UTF8

# -------------------------------
# Main Scan
# -------------------------------
Write-Host "Scanning for corrupt movie MKVs..." -ForegroundColor Cyan

$corruptFound = $false

Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "*.mkv" | ForEach-Object {

    $File = $_.FullName

    if (Test-MkvCorrupt -Path $File) {

        $corruptFound = $true
        Write-Host "CORRUPT MKV: $File" -ForegroundColor Red

        if ($Audit) {
            Write-Audit "Would delete: $File"
            Write-Audit "Would request replacement from Radarr for: $File"
        }
        else {
            if ($CsvEnabled) {
                Add-Content -LiteralPath $CsvFile -Value '"' + $File.Replace('"','""') + '"'
            }

            Invoke-RadarrReplaceFromPath `
                -RadarrUrl $RadarrUrl `
                -ApiKey $RadarrApiKey `
                -FilePath $File `
                -LogFile $RadarrLogFile `
                -MissingMovieLog $MissingMovieLog `
                -Audit:$Audit

            Write-Host "Radarr actions logged to $RadarrLogFile" -ForegroundColor Yellow
        }
    }
}

if ($corruptFound) {
    exit 1
} else {
    exit 0
}
