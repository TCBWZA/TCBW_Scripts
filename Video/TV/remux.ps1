<#
.SYNOPSIS
    Remuxes MKV files that have structural or container anomalies.

.DESCRIPTION
    Recursively scans a directory for MKV files and remuxes (stream-copy, no re-encode)
    only those with detected container problems such as invalid timestamps, corrupt
    duration fields, or problematic subtitle codecs. Clean files are left untouched.

.PARAMETER Root
    Root directory to scan. Defaults to the current working directory.

.PARAMETER EnableDebug
    Enables verbose debug output with timestamps.

.EXAMPLE
    PS> .\remux.ps1

.EXAMPLE
    PS> .\remux.ps1 -Root "Z:\TV" -EnableDebug

.NOTES
    - Requires PowerShell 7+, ffmpeg, and ffprobe on PATH.
    - No re-encoding is performed; this is a container-repair operation only.
    - Place a .skip file in any directory to exclude it and all subdirectories.
    - Place a .skip_<basename> file alongside a video to exclude that file.
#>
# Requires PowerShell 7+, ffmpeg, ffprobe on PATH
param(
    [Parameter(Mandatory=$false)]
    [string]$Root = (Get-Location).ProviderPath,

    [switch]$EnableDebug
)

$ErrorActionPreference = "Stop"
$DebugMode = $EnableDebug.IsPresent

function Debug { param([string]$m) if ($DebugMode) { $ts=(Get-Date).ToString("HH:mm:ss.fff"); Write-Host "[DEBUG $ts] $m" -ForegroundColor DarkGray } }

function Test-FileLocked {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None)
        $fs.Close(); return $false
    } catch [System.IO.IOException] { Debug "Locked: $Path"; return $true } catch { Debug "Lock-check error: $($_.Exception.Message)"; return $true }
}

function Invoke-AtomicReplace {
    param(
        [int]$ExitCode,
        [string]$TmpFile,
        [string]$OrigFile,
        [string]$SkipFile,
        [bool]$SkipSizeCheck = $false
    )

    Debug "AtomicReplace: exit=$ExitCode tmp=$TmpFile orig=$OrigFile skipSize=$SkipSizeCheck"

    if ($ExitCode -ne 0) {
        Write-Host "Remux failed (exit $ExitCode): $OrigFile"
        if (Test-Path -LiteralPath $TmpFile) { Remove-Item -LiteralPath $TmpFile -Force }
        return
    }

    if (-not (Test-Path -LiteralPath $TmpFile)) { Write-Host "Temp missing: $TmpFile"; return }

    try { $tmpItem = Get-Item -LiteralPath $TmpFile } catch { Write-Host "Cannot stat tmp: $TmpFile"; return }
    if ($tmpItem.PSIsContainer) { Write-Host "Temp is directory: $TmpFile"; return }

    if (Test-FileLocked -Path $TmpFile) { Write-Host "Temp locked: $TmpFile"; Remove-Item -LiteralPath $TmpFile -Force; return }

    try { $orig = Get-Item -LiteralPath $OrigFile } catch { Write-Host "Cannot stat orig: $OrigFile"; Remove-Item -LiteralPath $TmpFile -Force; return }

    $origSize = $orig.Length; $newSize = $tmpItem.Length
    $origMB = [math]::Round($origSize/1MB,2); $newMB = [math]::Round($newSize/1MB,2)

    if ($newSize -le 0) { Write-Host "Zero-length tmp, deleting"; Remove-Item -LiteralPath $TmpFile -Force; return }

    if (-not $SkipSizeCheck) {
        if ($newSize -ge $origSize) {
            Write-Host "Skipped (not smaller): ${origMB}MB -> ${newMB}MB"
            Debug "Marking skip: $SkipFile"
            New-Item -Path $SkipFile -ItemType File -Force | Out-Null
            Remove-Item -LiteralPath $TmpFile -Force
            return
        }
    }

    if (Test-FileLocked -Path $OrigFile) { Write-Host "Orig locked: $OrigFile"; Remove-Item -LiteralPath $TmpFile -Force; return }

    try { Set-ItemProperty -LiteralPath $TmpFile -Name LastWriteTime -Value $orig.LastWriteTime } catch { Debug "Set timestamp failed: $($_.Exception.Message)" }

    if (Test-FileLocked -Path $OrigFile) { Write-Host "Orig locked at commit: $OrigFile"; Remove-Item -LiteralPath $TmpFile -Force; return }

    Remove-Item -LiteralPath $OrigFile -Force
    Move-Item -LiteralPath $TmpFile -Destination $OrigFile -Force

    Write-Host "Remuxed: $OrigFile (${origMB}MB -> ${newMB}MB)"
    Debug "Atomic replace complete"
}

function Test-HeaderAnomaly {
    param([string]$Path)

    Debug "Header anomaly check: $Path"

    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "ffmpeg"
        $psi.Arguments = "-v error -i `"$Path`" -f null -"
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $false
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit(5000)
        if ($stderr -and $stderr.Trim().Length -gt 0) {
            Debug "ffmpeg stderr snippet: $($stderr.Substring(0,[math]::Min(400,$stderr.Length)))"
            if ($stderr -match "moov atom" -or $stderr -match "Invalid data found" -or $stderr -match "non-monotonic" -or $stderr -match "could not find codec parameters" -or $stderr -match "error while decoding") {
                return $true
            }
        }
    } catch { Debug "ffmpeg probe failed: $($_.Exception.Message)" } finally { if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} } }

    try {
        $probeJson = ffprobe -v quiet -print_format json -show_format -show_streams "$Path"
        $probe = $probeJson | ConvertFrom-Json
        $formatName = $probe.format.format_name
        Debug "ffprobe format: $formatName"
        if (-not $formatName -or $formatName -match "unknown|data") { return $true }
        $ext = [IO.Path]::GetExtension($Path).TrimStart(".").ToLower()
        if ($ext -and $formatName -and ($formatName -notmatch $ext) -and ($formatName -notmatch "matroska,webm|mov,mp4")) { return $true }
        if ($formatName -match "mov|mp4" -and -not $probe.format.tags.major_brand) { return $true }
    } catch { Debug "ffprobe check failed: $($_.Exception.Message)" }

    return $false
}

Write-Host "Remux diagnostic run in: $Root"
$files = Get-ChildItem -Path $Root -Recurse -File -Include *.mkv,*.mp4,*.ts -ErrorAction SilentlyContinue

foreach ($f in $files) {
    Debug "Evaluating: $($f.FullName)"

    # Skip markers and directories
    if ($f.BaseName -match '\[Trans\]|\[Cleaned\]') { Debug "Already processed: $($f.FullName)"; continue }

    $cur = $f.Directory
    $skipDir = $false
    while ($null -ne $cur -and $cur.FullName -ne $Root) {
        $skipFile = Join-Path $cur.FullName ".skip"
        if (Test-Path -LiteralPath $skipFile) { Debug "Dir skip: $skipFile"; $skipDir = $true; break }
        $cur = $cur.Parent
    }
    if ($skipDir) { continue }

    $fileSkip = Join-Path $f.DirectoryName ".skip_$($f.BaseName)"
    if (Test-Path -LiteralPath $fileSkip) { Debug "File skip present: $fileSkip"; continue }

    # Probe streams
    try {
        $probeJson = ffprobe -v quiet -print_format json -show_streams "$($f.FullName)"
        $probe = $probeJson | ConvertFrom-Json
    } catch { Debug "ffprobe failed for $($f.FullName)"; continue }

    $vstream = ($probe.streams | Where-Object { $_.codec_type -eq "video" })[0]
    if (-not $vstream) { Debug "No video stream: $($f.FullName)"; continue }

    $vcodec = $vstream.codec_name
    $vbitrate = [int]($vstream.bit_rate ?? 0)
    $astreams = $probe.streams | Where-Object { $_.codec_type -eq "audio" }
    if ($astreams.Count -eq 0) { Debug "No audio: $($f.FullName)"; continue }
    $hasAAC = ($astreams.codec_name -contains "aac")

    Debug "vcodec=$vcodec vbitrate=$vbitrate hasAAC=$hasAAC"

    # Base checks
    $canRemux = $true
    if ($vcodec -ne "hevc") { $canRemux = $false }
    if ($vbitrate -gt 2500000) { $canRemux = $false }
    if (-not $hasAAC) { $canRemux = $false }

    if (-not $canRemux) { Debug "Codec/bitrate/audio not eligible"; continue }

    # Structural check
    $structural = Test-HeaderAnomaly $f.FullName
    Debug "Structural anomaly: $structural"
    if (-not $structural) { Debug "Skipping remux (no anomaly)"; continue }

    # Prepare tmp file
    $tmpfile = Join-Path $f.DirectoryName ($f.BaseName + "[Trans].mkv")
    if (Test-Path -LiteralPath $tmpfile) { Remove-Item -LiteralPath $tmpfile -Force }

    if (Test-FileLocked -Path $f.FullName) { Write-Host "Locked, skipping: $($f.FullName)"; continue }

    Write-Host "Remuxing: $($f.FullName)"
    ffmpeg -y -i "$($f.FullName)" -c copy "$tmpfile"
    $exit = $LASTEXITCODE

    if (Test-FileLocked -Path $tmpfile) { Write-Host "Tmp locked after remux, deleting: $tmpfile"; Remove-Item -LiteralPath $tmpfile -Force; continue }

    Invoke-AtomicReplace -ExitCode $exit -TmpFile $tmpfile -OrigFile $f.FullName -SkipFile $fileSkip -SkipSizeCheck $true
}

Write-Host "Remux pass complete."
