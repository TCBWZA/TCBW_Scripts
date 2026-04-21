#!/usr/bin/env bash
# organize-chapters.sh
# Recursively moves *_chapters.xml files into a 'chapters' subdirectory
# within each folder that contains them. Directories containing a .skip
# file are skipped entirely, including all of their subdirectories.
#
# Usage: ./organize-chapters.sh [--root <dir>] [--dry-run] [--debug]

set -euo pipefail

DEBUG=false
DRY_RUN=false
ROOT="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   DEBUG=true;  shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --root)    ROOT="$2";   shift 2 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

moved=0
skipped_dirs=0

debug() { if $DEBUG; then printf '[DEBUG] %s\n' "$*"; fi; }

process_dir() {
    local dir="$1"

    if [[ -f "$dir/.skip" ]]; then
        debug ".skip found, skipping directory tree: $dir"
        skipped_dirs=$((skipped_dirs + 1))
        return
    fi

    # Collect *_chapters.xml files in this directory only (not recursive)
    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 1 -name '*_chapters.xml' -print0 2>/dev/null)

    if [[ ${#files[@]} -gt 0 ]]; then
        local dest="$dir/chapters"
        debug "Creating: $dest"
        if ! $DRY_RUN; then
            mkdir -p "$dest"
        fi
        for f in "${files[@]}"; do
            printf 'Moving: %s  ->  %s/\n' "$(basename "$f")" "$dest"
            if ! $DRY_RUN; then
                mv -- "$f" "$dest/"
            fi
            moved=$((moved + 1))
        done
    else
        debug "No _chapters.xml files in: $dir"
    fi

    # Recurse into subdirectories, skipping any existing 'chapters' folder
    while IFS= read -r -d '' subdir; do
        if [[ "$(basename "$subdir")" == "chapters" ]]; then
            continue
        fi
        process_dir "$subdir"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
}

process_dir "$ROOT"

printf '\nDone.  Moved: %d  |  Directories skipped (.skip): %d\n' "$moved" "$skipped_dirs"
