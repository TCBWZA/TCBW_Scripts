param(
    [string]$Root = ".\",

    [Parameter(Mandatory = $true)]
    [string]$CsvFile,

    [switch]$Append,

    [switch]$EnableSonarr,

    [string]$SonarrUrl = "http://docker:8989",

    [string]$SonarrLogFile = "D:\Work\SonarrLog.txt"
)

# -------------------------------
# Sonarr API Key
# -------------------------------
$SonarrApiKey = "YOUR_API_KEY_HERE"

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

    function Write-SonarrLog {
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
            Write-SonarrLog -File $FilePath -Status "ERROR: Could not parse SxxEyy"
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
            Write-SonarrLog -File $FilePath -Status "404 (series not found)"
            return
        }

        # 2. Get episodes
        $episodes = Invoke-RestMethod -Method Get -Uri "$SonarrUrl/api/v3/episode?seriesId=$($series.id)" -Headers $Headers

        $episodeObj = $episodes |
            Where-Object { $_.seasonNumber -eq $season -and $_.episodeNumber -eq $episode }

        if (-not $episodeObj) {
            Write-SonarrLog -File $FilePath -Status "404 (episode not found)"
            return
        }

        $episodeId = $episodeObj.id
        $episodeFileId = $episodeObj.episodeFileId

        if (-not $episodeFileId) {
            Write-SonarrLog -File $FilePath -Status "404 (episodeFileId missing)"
            return
        }

        # 4. DELETE the file
        $deleteResponse = Invoke-WebRequest -Method Delete -Uri "$SonarrUrl/api/v3/episodefile/$episodeFileId" -Headers $Headers -ErrorAction Stop
        Write-SonarrLog -File $FilePath -Status $deleteResponse.StatusCode

        # 5. Re-monitor
        $episodeObj.monitored = $true

        $monitorResponse = Invoke-WebRequest `
            -Method Put `
            -Uri "$SonarrUrl/api/v3/episode/$episodeId" `
            -Headers $Headers `
            -Body ($episodeObj | ConvertTo-Json -Depth 10) `
            -ContentType "application/json" `
            -ErrorAction Stop

        Write-SonarrLog -File $FilePath -Status $monitorResponse.StatusCode

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

        Write-SonarrLog -File $FilePath -Status $searchResponse.StatusCode

    }
    catch {
        Write-SonarrLog -File $FilePath -Status "ERROR: $($_.Exception.Message)"
    }
}

# -------------------------------
# Script start
# -------------------------------
$AllowedLanguages = @("eng", "und")

# Prepare main CSV
if (-not $Append -and (Test-Path -LiteralPath $CsvFile)) {
    Remove-Item -LiteralPath $CsvFile -Force
}
if (-not (Test-Path -LiteralPath $CsvFile)) {
    "FilePath,Languages" | Out-File -LiteralPath $CsvFile -Encoding UTF8
}

# Prepare Sonarr log
if ($EnableSonarr) {
    $logDir = Split-Path -LiteralPath $SonarrLogFile
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

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

        $LangString = $LangList -join ";"
        $csvLine = '"' + $File.Replace('"','""') + '","' + $LangString.Replace('"','""') + '"'
        Add-Content -LiteralPath $CsvFile -Value $csvLine

        if ($EnableSonarr -and $SonarrApiKey) {
            Invoke-SonarrReplaceFromPath `
                -SonarrUrl $SonarrUrl `
                -ApiKey $SonarrApiKey `
                -FilePath $File `
                -LogFile $SonarrLogFile
        }
    }
}
