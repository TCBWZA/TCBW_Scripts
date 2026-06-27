<#
.SYNOPSIS
    Scans a directory tree for zero-byte audiobook files (.mp3 / .m4b) and
    optionally deletes the offending directories.

.DESCRIPTION
    This script recursively scans the specified base directory (default: current directory)
    and checks each subdirectory for zero-byte audio files (.mp3 or .m4b).

    When a zero-byte file is found:
        * The directory is reported once.
        * If -Delete is specified, the entire directory is removed.
        * If -Debug is specified, detailed diagnostic output is shown.

.PARAMETER BaseDir
    The starting directory for the scan.
    Defaults to the current directory (".").

.PARAMETER Delete
    When present, deletes any directory that contains at least one zero-byte audio file.

.PARAMETER Debug
    Enables verbose diagnostic output showing directory traversal and matched files.

.EXAMPLE
    .\listcorrupt.ps1
    Scans the current directory for zero-byte audiobook files.

.EXAMPLE
    .\listcorrupt.ps1 -Debug -BaseDir "D:\Media\Audiobooks"
    Scans with verbose output.

.EXAMPLE
    .\listcorrupt.ps1 -Delete -BaseDir "D:\Media\Audiobooks"
    Deletes directories containing zero-byte audio files.

.NOTES
    Purpose: Audiobook library integrity checking and cleanup
    Version: 1.0
#>

param(
    [string]$BaseDir = ".",
    [switch]$Delete,
    [switch]$Debug
)

function DebugLog {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message"
    }
}

DebugLog "Starting scan in: $BaseDir"
DebugLog "Delete mode: $Delete"
DebugLog "Debug mode: $Debug"

# Resolve full path for safety
$BaseDir = (Resolve-Path $BaseDir).Path

# Enumerate all directories recursively
Get-ChildItem -Path $BaseDir -Directory -Recurse | ForEach-Object {
    $dir = $_.FullName
    DebugLog "Checking directory: $dir"

    # Find the first zero-byte mp3 or m4b file
    $file = Get-ChildItem -Path $dir -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Extension -in ".mp3", ".m4b") -and $_.Length -eq 0 } |
            Select-Object -First 1

    if ($file) {
        Write-Host "Zero-byte file found in: $dir"
        DebugLog "Matched file: $($file.FullName)"

        if ($Delete) {
            DebugLog "Deleting directory: $dir"
            Remove-Item -Path $dir -Recurse -Force
        }
    }
}
