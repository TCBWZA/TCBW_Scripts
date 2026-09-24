<#
.SYNOPSIS
    Exports a WSL distro to a compressed 7z archive with retention.

.DESCRIPTION
    Shuts down WSL, exports the configured distro to a tar archive, compresses
    it with 7-Zip, deletes the intermediate tar, and prunes old compressed
    backups down to the retention count. The distro is left stopped.

.NOTES
    Requires wsl.exe and a 7-Zip installation.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# CONFIG
$DistroName = "Ubuntu"
$BackupRoot = "F:\Backups"
$RetentionCount = 6
$SevenZip = "C:\Program Files\7-Zip\7z.exe"

$Timestamp = (Get-Date).ToString("yyyy-MM-dd_HH-mm-ss")
$TarFile = Join-Path $BackupRoot "$DistroName-$Timestamp.tar"
$ZipFile = Join-Path $BackupRoot "$DistroName-$Timestamp.7z"

try {
    # Ensure backup directory exists
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

    # Shutdown WSL for a clean snapshot
    wsl --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed with exit code $LASTEXITCODE"
    }

    # Export the distro
    wsl --export $DistroName $TarFile
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --export failed with exit code $LASTEXITCODE"
    }

    # Compress the backup
    & $SevenZip a -t7z -mx=9 $ZipFile $TarFile
    if ($LASTEXITCODE -ne 0) {
        throw "7z compression failed with exit code $LASTEXITCODE"
    }

    # Remove the uncompressed tar only after the archive exists
    if (Test-Path $ZipFile) {
        Remove-Item $TarFile -Force
    } else {
        throw "Compressed archive missing - keeping $TarFile"
    }

    # Retention: keep only the most recent N compressed backups
    $Backups = Get-ChildItem $BackupRoot -Filter "*.7z" | Sort-Object LastWriteTime -Descending
    $Backups | Select-Object -Skip $RetentionCount | Remove-Item -Force

    Write-Output "Backup complete: $ZipFile"
    exit 0
}
catch {
    Write-Warning "Error: $_"
    exit 1
}