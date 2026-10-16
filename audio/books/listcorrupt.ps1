<#
.SYNOPSIS
    Scans a directory tree for corrupt audiobook folders and optionally cleans
    them up.

.DESCRIPTION
    Walks each book folder (author/book under the given base directory) and
    reports it as corrupt when it holds a zero-byte audio file, declares more
    "of NN" parts than it holds, or holds no audio files at all.

    With -Delete, the zero-byte audio files are removed, and any book folder
    left with no audio files, or missing declared parts, is removed. Author
    folders are never inspected or removed.

.PARAMETER BaseDir
    The audiobook library root (the folder that holds author folders).
    Defaults to the current directory (".").

.PARAMETER Delete
    When present, removes zero-byte audio files and the corrupt book folders
    described above.

.PARAMETER Debug
    Enables verbose diagnostic output showing directory traversal and matched files.

.EXAMPLE
    .\listcorrupt.ps1
    Scans the current directory for corrupt audiobook folders.

.EXAMPLE
    .\listcorrupt.ps1 -Debug -BaseDir "D:\Media\Audiobooks"
    Scans with verbose output.

.EXAMPLE
    .\listcorrupt.ps1 -Delete -BaseDir "D:\Media\Audiobooks"
    Removes zero-byte audio files and corrupt book folders.

.NOTES
    Purpose: Audiobook library integrity checking and cleanup
    Version: 2.0
#>

param(
    [string]$BaseDir = ".",
    [switch]$Delete,
    [switch]$Debug
)

$AudioExtensions = @(".mp3", ".m4b", ".m4a", ".flac", ".ogg", ".opus", ".wav", ".aac", ".wma")

function DebugLog {
    param([string]$Message)
    if ($Debug) {
        Write-Host "[DEBUG] $Message"
    }
}

function Get-AudioFiles {
    param([string]$Dir)
    Get-ChildItem -Path $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in $AudioExtensions }
}

function Get-DeclaredParts {
    param($Files)
    $declared = 0
    foreach ($f in $Files) {
        foreach ($m in [regex]::Matches($f.Name, '(?i)of[._ -]+(\d+)')) {
            $n = [int]$m.Groups[1].Value
            if ($n -gt $declared) { $declared = $n }
        }
    }
    return $declared
}

DebugLog "Starting scan in: $BaseDir"
DebugLog "Delete mode: $Delete"
DebugLog "Debug mode: $Debug"

# Resolve full path for safety
$BaseDir = (Resolve-Path $BaseDir).Path

# Book folders sit at author/book under the library root; author folders are
# never inspected or removed.
Get-ChildItem -Path $BaseDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $author = $_
    Get-ChildItem -Path $author.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $book = $_
        DebugLog "Checking book folder: $($book.FullName)"

        $audio = @(Get-AudioFiles $book.FullName)
        $nAudio = $audio.Count
        $zero = @($audio | Where-Object { $_.Length -eq 0 })
        $nZero = $zero.Count
        $nRemaining = $nAudio - $nZero
        $declared = Get-DeclaredParts $audio

        $reasons = @()
        if ($nZero -gt 0) { $reasons += "$nZero zero-byte file(s)" }
        if ($nRemaining -eq 0) { $reasons += "no audio files" }
        if ($declared -gt $nAudio) { $reasons += "missing files (declared $declared, present $nAudio)" }

        if ($reasons.Count -eq 0) { return }

        Write-Host "Corrupt book folder: $($book.FullName)"
        foreach ($r in $reasons) { Write-Host "  - $r" }

        if (-not $Delete) { return }

        if (($nRemaining -eq 0) -or ($declared -gt $nAudio)) {
            DebugLog "Removing folder: $($book.FullName)"
            Remove-Item -Path $book.FullName -Recurse -Force
        }
        elseif ($nZero -gt 0) {
            foreach ($z in $zero) {
                DebugLog "Deleting zero-byte file: $($z.FullName)"
                Remove-Item -Path $z.FullName -Force
            }
        }
    }
}
