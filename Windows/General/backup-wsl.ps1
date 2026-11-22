<#
.SYNOPSIS
    Exports a WSL distro to a compressed tar.gz archive and mirrors the backup folder.

.DESCRIPTION
    Shuts down WSL, exports the configured distro directly to a gzip-compressed
    tar archive, prunes old compressed backups down to the retention count, then
    mirrors the backup folder to the configured sync destination. The distro is
    left stopped.

.NOTES
    Requires wsl.exe with --format tar.gz support and robocopy.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# CONFIG
$DistroName = "Ubuntu"
$BackupRoot = "F:\Backups\hestia"
$RetentionCount = 6
$SyncDestination = "Z:\Backups\hestia\wsl"

$Timestamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
$ArchiveFile = Join-Path $BackupRoot "$DistroName-$Timestamp.tar.gz"

try {
    # Ensure backup directory exists
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

    # Shutdown WSL for a clean snapshot
    wsl --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed with exit code $LASTEXITCODE"
    }

    # Export the distro directly to a compressed archive
    wsl --export $DistroName $ArchiveFile --format tar.gz
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --export failed with exit code $LASTEXITCODE"
    }
    if (-not (Test-Path $ArchiveFile)) {
        throw "Compressed archive missing: $ArchiveFile"
    }

    # Retention: keep only the most recent N compressed backups
    $Backups = Get-ChildItem $BackupRoot -File | Where-Object { ($_.Name -like "*.tar.gz") -or ($_.Name -like "*.7z") } | Sort-Object LastWriteTime -Descending
    $Backups | Select-Object -Skip $RetentionCount | Remove-Item -Force

    # Mirror the backup folder to the off-host destination
    $RobocopyOpts = @(
        '/MIR',
        '/FFT',
        '/Z',
        '/XA:SH',
        '/R:1',
        '/W:1',
        '/DCOPY:T',
        '/COPY:DAT',
        '/NP',
        '/XF', '*.tmp', '*.temp'
    )
    robocopy $BackupRoot $SyncDestination * @RobocopyOpts
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy sync failed with exit code $LASTEXITCODE"
    }

    Write-Output "Backup complete: $ArchiveFile"
    Write-Output "Sync complete: $SyncDestination"
    exit 0
}
catch {
    Write-Warning "Error: $_"
    exit 1
}