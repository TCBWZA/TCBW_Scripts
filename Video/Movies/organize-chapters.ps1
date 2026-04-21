param(
    [string]$Root    = ".",
    [switch]$DryRun,
    [switch]$Debug
)

$moved       = 0
$skippedDirs = 0

function Invoke-OrganizeDirectory {
    param([string]$Dir)

    if (Test-Path -LiteralPath (Join-Path $Dir ".skip")) {
        if ($Debug) { Write-Host "[DEBUG] .skip found, skipping directory tree: $Dir" }
        $script:skippedDirs++
        return
    }

    $chapterFiles = Get-ChildItem -LiteralPath $Dir -Filter "*_chapters.xml" -File -ErrorAction SilentlyContinue

    if ($chapterFiles) {
        $dest = Join-Path $Dir "chapters"
        if ($Debug) { Write-Host "[DEBUG] Creating: $dest" }
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
        }
        foreach ($f in $chapterFiles) {
            Write-Host "Moving: $($f.Name)  ->  $dest\"
            if (-not $DryRun) {
                Move-Item -LiteralPath $f.FullName -Destination $dest
            }
            $script:moved++
        }
    } elseif ($Debug) {
        Write-Host "[DEBUG] No _chapters.xml files in: $Dir"
    }

    # Recurse into subdirectories, skipping any existing 'chapters' folder
    Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'chapters' } |
        ForEach-Object { Invoke-OrganizeDirectory -Dir $_.FullName }
}

Invoke-OrganizeDirectory -Dir (Resolve-Path $Root).ProviderPath

Write-Host ""
Write-Host "Done.  Moved: $moved  |  Directories skipped (.skip): $skippedDirs"
