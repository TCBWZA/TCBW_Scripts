<#
.SYNOPSIS
    Incremental Robocopy-based sync wrapper with optional dry-run, logging,
    and exclusion of temporary files.

.DESCRIPTION
    This script mirrors a source directory to a destination directory using Robocopy.
    It supports default paths, optional dry-run mode, and optional automatic log file
    creation. Logging is only enabled when -Log is passed. When enabled, the script
    generates a timestamped log file in the current working directory.

    Temporary files (*.tmp, *.temp) are excluded from all operations.

.PARAMETER Source
    The source directory to sync from. Defaults to "D:\Media".

.PARAMETER Destination
    The destination directory to sync to. Defaults to "Z:\Backup".

.PARAMETER DryRun
    Enables Robocopy dry-run mode (/L), showing what would be copied or deleted
    without making any changes.

.PARAMETER Log
    Enables logging. When supplied, a timestamped log file is created automatically.

.NOTES
    - Dotfiles are included because '*' is used instead of '*.*'.
    - FAT/exFAT timestamp drift is handled via /FFT.
    - Permissions, ownership, and ACLs are not copied (COPY:DAT).
    - Temporary files (*.tmp, *.temp) are excluded.
#>

param(
    [string]$Source = "Z:\media\Video",
    [string]$Destination = "N:\media\Video",
    [switch]$DryRun,
    [switch]$Log
)

# Build robocopy options
$opts = @(
    '/MIR',        # mirror source to dest
    '/FFT',        # FAT/exFAT timestamp tolerance
    '/Z',          # restartable mode
    '/XA:SH',      # skip system + hidden
    '/R:1',        # retry once
    '/W:1',        # wait 1 sec
    '/DCOPY:T',    # copy directory timestamps
    '/COPY:DAT',   # copy data, attributes, timestamps
    '/NP',         # no % progress
    '/XF', '*.tmp', '*.temp'   # exclude temporary files
)

# Add dry-run mode
if ($DryRun) {
    $opts += '/L'
}

# Add logging only if -Log is passed
if ($Log) {
    $logFile = "robocopy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $opts += "/LOG+:$logFile"
    $opts += '/TEE'
}

Write-Host "Source: $Source"
Write-Host "Destination: $Destination"
Write-Host "Dry Run: $DryRun"
if ($Log) { Write-Host "Logging to: $logFile" } else { Write-Host "Logging: Disabled" }
Write-Host ""

robocopy $Source $Destination * $opts
