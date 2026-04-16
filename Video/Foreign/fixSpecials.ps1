param(
    [switch]$DryRun
)

# Base path is always the current directory
$BasePath = (Get-Location).ProviderPath

# Create an audit log with timestamp
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logPath   = "$BasePath\specials_audit_$timestamp.log"

function Write-Audit {
    param([string]$Message)
    $entry = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $logPath -Value $entry
    Write-Host $entry
}

# Returns only meaningful items (ignores dotfiles for empty-check)
function Get-RealItems {
    param([string]$Path)

    Get-ChildItem -LiteralPath $Path -Force |
        Where-Object {
            $_.Name -notmatch '^\.' -and
            $_.Name -notin @("Thumbs.db", ".DS_Store")
        }
}

Write-Audit "=== Starting Specials → Season 00 processing ==="
Write-Audit "Base path: $BasePath"
if ($DryRun) { Write-Audit "DRY RUN ENABLED — no changes will be made" }

# Enumerate directories literally
$allDirs = Get-ChildItem -LiteralPath $BasePath -Directory -Recurse

foreach ($dir in $allDirs) {

    if ($dir.Name -ne "Specials") { continue }

    $specialsPath = $dir.FullName
    $parent       = $dir.Parent

    if ($null -eq $parent) {
        Write-Audit "SKIP: $specialsPath has no parent directory (unexpected)."
        continue
    }

    $parentPath   = $parent.FullName
    $season00Path = "$parentPath\Season 00"

    Write-Audit "Processing Specials folder: $specialsPath"

    #
    # If Season 00 does not exist → rename Specials → Season 00
    #
    if (-not (Test-Path -LiteralPath $season00Path)) {

        Write-Audit "Season 00 does not exist. Will rename Specials → Season 00"

        if (-not $DryRun) {
            Rename-Item -LiteralPath $specialsPath -NewName "Season 00"
        }

        Write-Audit "Renamed: $specialsPath → $season00Path (or would rename in dry-run)"
        continue
    }

    #
    # Season 00 exists → move files and directories
    #
    Write-Audit "Season 00 exists at: $season00Path"
    Write-Audit "Moving files and directories from Specials into Season 00"

    #
    # Move ALL files (including dotfiles)
    #
    $files = Get-ChildItem -LiteralPath $specialsPath -File -Force

    foreach ($file in $files) {
        $dest = "$season00Path\$($file.Name)"
        Write-Audit "Moving file: $($file.FullName) → $dest (overwrite)"

        if (-not $DryRun) {
            Move-Item -LiteralPath $file.FullName -Destination $dest -Force
        }
    }

    #
    # Move directories (merge if needed)
    #
    $dirs = Get-ChildItem -LiteralPath $specialsPath -Directory -Force

    foreach ($subdir in $dirs) {
        $destDir = "$season00Path\$($subdir.Name)"

        if (-not (Test-Path -LiteralPath $destDir)) {

            Write-Audit "Moving directory: $($subdir.FullName) → $destDir"

            if (-not $DryRun) {
                Move-Item -LiteralPath $subdir.FullName -Destination $destDir -Force
            }
        }
        else {
            Write-Audit "Directory exists: $destDir — merging contents"

            $subItems = Get-ChildItem -LiteralPath $subdir.FullName -Force

            foreach ($item in $subItems) {
                $dest = "$destDir\$($item.Name)"
                Write-Audit "  Moving: $($item.FullName) → $dest (overwrite)"

                if (-not $DryRun) {
                    Move-Item -LiteralPath $item.FullName -Destination $dest -Force
                }
            }

            # Remove empty directory (ignoring dotfiles)
            $remaining = Get-RealItems -Path $subdir.FullName
            if ($remaining.Count -eq 0) {
                Write-Audit "  Removing empty directory: $($subdir.FullName)"
                if (-not $DryRun) {
                    Remove-Item -LiteralPath $subdir.FullName
                }
            }
            else {
                Write-Audit "  Directory not empty after merge: $($subdir.FullName)"
            }
        }
    }

    #
    # Remove Specials if empty (ignoring dotfiles)
    #
    $remaining = Get-RealItems -Path $specialsPath
    if ($remaining.Count -eq 0) {
        Write-Audit "Specials folder is empty. Will remove: $specialsPath"

        if (-not $DryRun) {
            Remove-Item -LiteralPath $specialsPath
        }
    }
    else {
        Write-Audit "Specials folder NOT empty after move. Leaving in place: $specialsPath"
    }
}

Write-Audit "=== Completed Specials → Season 00 processing ==="
Write-Audit "Audit log saved to: $logPath"
