#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# TV Chapter File Repair and Normalisation Script (ASCII ONLY)
#
# Purpose:
#   Fix broken chapter folder structures inside TV season directories.
#   Typical broken layouts:
#       - Season XX/
#       - Season XX/chapters/
#       - Season XX/.chapters/
#       - Season XX/.chapters/chapters/
#       - Season XX/.chapters/.chapters/
#
#   This script, per Season or Specials folder:
#       1. Deletes any existing "chapters" and ".chapters" folders.
#       2. Finds ALL *_chapters.xml files at ANY depth.
#       3. Moves them into a temporary rescue folder.
#       4. Deduplicates by episode key, keeping the LARGEST file.
#       5. Rebuilds a clean ".chapters" folder.
#       6. Moves deduplicated files into ".chapters".
#       7. Sets folder perms to 754 and XML perms to 664.
#       8. Sets owner:group to 1000:1000.
#
# Notes:
#   - Safe for Proxmox: does NOT use "set -e".
#   - Uses null-delimited paths (print0 / -d '') to handle spaces, quotes, etc.
#   - Script itself is ASCII only.
# -----------------------------------------------------------------------------

set -uo pipefail   # No undefined vars, pipeline failure detection, no -e

ROOT="./"    # Root of your TV library

# Find all Season or Specials folders (case-insensitive)
find "$ROOT" -type d \( -iname "season *" -o -iname "special*" \) -print0 |
while IFS= read -r -d '' season_dir; do
    echo "Processing: $season_dir"

    # -------------------------------------------------------------------------
    # 1. DELETE ANY EXISTING CHAPTER FOLDERS
    # -------------------------------------------------------------------------
    # Remove all "chapters" and ".chapters" directories first, so we start clean.
    # This also avoids accidentally putting the rescue folder inside something
    # that will later be deleted.
    find "$season_dir" -type d \( -name "chapters" -o -name ".chapters" \) \
        -print0 2>/dev/null | xargs -0r rm -rf

    # -------------------------------------------------------------------------
    # 2. FIND ALL CHAPTER XML FILES
    # -------------------------------------------------------------------------
    # Collect every "*_chapters.xml" file at any depth under this Season folder.
    mapfile -d '' -t chapter_files < <(
        find "$season_dir" -type f -name '*_chapters.xml' -print0 2>/dev/null
    )

    if [[ ${#chapter_files[@]} -eq 0 ]]; then
        echo "  No chapter files found."
        continue
    fi

    echo "  Found ${#chapter_files[@]} raw chapter files."

    # -------------------------------------------------------------------------
    # 3. CREATE RESCUE FOLDER AND MOVE ALL CHAPTER FILES INTO IT
    # -------------------------------------------------------------------------
    # Rescue folder is placed directly under the Season folder, not inside
    # ".chapters", so it will not be deleted by the cleanup step.
    rescue="$season_dir/.chapters_rescue_tmp"
    mkdir -p "$rescue"

    # Move all discovered chapter files into the rescue folder (null-safe).
    for f in "${chapter_files[@]}"; do
        mv -v -- "$f" "$rescue/"
    done

    # -------------------------------------------------------------------------
    # 4. DEDUPLICATE: KEEP ONLY THE LARGEST FILE PER EPISODE KEY
    # -------------------------------------------------------------------------
    # We use associative arrays:
    #   best_file[key] = path to best file
    #   best_size[key] = size of best file
    # where "key" is the filename without the "_chapters.xml" suffix.
    echo "  Deduplicating chapter files (keeping largest per episode)..."

    declare -A best_file
    declare -A best_size

    # Scan all rescued chapter files.
    find "$rescue" -maxdepth 1 -type f -name '*_chapters.xml' -print0 |
    while IFS= read -r -d '' f; do
        base=$(basename "$f")
        # Episode key = filename without "_chapters.xml"
        key="${base%_chapters.xml}"
        # File size in bytes
        size=$(stat -c%s "$f")

        # If no entry yet for this key, or this file is larger, keep it.
        if [[ -z "${best_size[$key]+x}" || $size -gt ${best_size[$key]} ]]; then
            best_size[$key]=$size
            best_file[$key]="$f"
        fi
    done

    # -------------------------------------------------------------------------
    # 5. CREATE CLEAN .chapters FOLDER
    # -------------------------------------------------------------------------
    clean="$season_dir/.chapters"
    mkdir -p "$clean"

    # -------------------------------------------------------------------------
    # 6. MOVE ONLY THE DEDUPLICATED FILES INTO .chapters
    # -------------------------------------------------------------------------
    for key in "${!best_file[@]}"; do
        mv -v -- "${best_file[$key]}" "$clean/"
    done

    # -------------------------------------------------------------------------
    # 7. APPLY PERMISSIONS AND OWNERSHIP
    # -------------------------------------------------------------------------
    # Folder: 754 (rwx r-x r--)
    chmod 754 "$clean"
    # Owner:Group = 1000:1000
    chown 1000:1000 "$clean"

    # All chapter XML files: 664 (rw-rw-r--)
    find "$clean" -type f -name '*_chapters.xml' -print0 \
        | xargs -0r chmod 664

    # Ensure XML files also have owner:group 1000:1000
    find "$clean" -type f -name '*_chapters.xml' -print0 \
        | xargs -0r chown 1000:1000

    # -------------------------------------------------------------------------
    # 8. REMOVE RESCUE FOLDER
    # -------------------------------------------------------------------------
    rm -rf "$rescue"

    echo "  Rebuilt .chapters folder with ${#best_file[@]} files."
done

echo "Done."
