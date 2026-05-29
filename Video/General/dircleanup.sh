#!/usr/bin/env bash
# dircleanup.sh
# Removes orphaned trickplay directories, stale .skip_<basename> markers, and
# dangling NFO sidecar files from a media library directory tree.
#
# Trickplay directories:
#   - A directory named 'trickplay' is removed when its parent contains no video files.
#   - A directory named '<basename>.trickplay' is removed when no video file with that
#     base name exists in the same parent directory.
#
# Stale .skip markers:
#   - Files matching .skip_<basename> are removed when no video file with that base name
#     exists in the same directory.
#
# Dangling NFO sidecars:
#   - Files matching <basename>.nfo are removed when no video file with that base name
#     exists in the same directory.
#   - Generic library-level NFO names (movie, movies, tvshow, series, show) are never removed.
#
# All operations respect a .skip marker: directories containing a .skip file and all of
# their subdirectories are excluded from processing.
#
# Usage:
#   ./dircleanup.sh [--root <dir>] [--audit] [--debug]
#
# Options:
#   --root <dir>   Root directory to scan. Defaults to the current directory.
#   --audit        Preview mode; no files or directories are removed.
#   --debug        Enable verbose debug output.

set -uo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

ROOT="."
AUDIT=false
DEBUG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            if [[ $# -lt 2 ]]; then
                printf 'ERROR: --root requires a directory argument\n' >&2
                exit 1
            fi
            ROOT="$2"
            shift 2
            ;;
        --audit)  AUDIT=true;  shift ;;
        --debug)  DEBUG=true;  shift ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

REMOVED_DIRS=0
REMOVED_SKIPS=0
REMOVED_NFOS=0

VIDEO_EXTENSIONS=('mkv' 'mp4' 'avi' 'ts')

# NFO base names that are never treated as per-video sidecars (lowercase for comparison)
GENERIC_NFO_NAMES=('movie' 'movies' 'tvshow' 'series' 'show')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_debug() {
    $DEBUG && printf '[DEBUG] %s\n' "$1" || true
}

do_remove_file() {
    local path="$1"
    if $AUDIT; then
        printf '[AUDIT] Would remove: %s\n' "$path"
    else
        rm -f -- "$path"
        printf 'Removed: %s\n' "$path"
    fi
}

do_remove_dir() {
    local path="$1"
    if $AUDIT; then
        printf '[AUDIT] Would remove: %s\n' "$path"
    else
        rm -rf -- "$path"
        printf 'Removed: %s\n' "$path"
    fi
}

# Returns 0 (true) if the argument is a generic NFO base name, 1 otherwise.
is_generic_nfo() {
    local base
    base=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    local g
    for g in "${GENERIC_NFO_NAMES[@]}"; do
        [[ "$base" == "$g" ]] && return 0
    done
    return 1
}

# Returns 0 (true) if a video file with the given base name exists in the given directory.
video_exists() {
    local dir="$1" base="$2" ext
    for ext in "${VIDEO_EXTENSIONS[@]}"; do
        [[ -f "$dir/$base.$ext" ]] && return 0
    done
    return 1
}

# Returns 0 (true) if the given directory contains at least one video file.
dir_has_videos() {
    local dir="$1" ext f
    for ext in "${VIDEO_EXTENSIONS[@]}"; do
        while IFS= read -r -d '' f; do
            return 0
        done < <(find "$dir" -maxdepth 1 -name "*.$ext" -print0 2>/dev/null)
    done
    return 1
}

# ---------------------------------------------------------------------------
# Per-directory cleanup
# ---------------------------------------------------------------------------

process_dir() {
    local dir="$1"

    if [[ -f "$dir/.skip" ]]; then
        log_debug ".skip found, skipping directory tree: $dir"
        return
    fi

    # --- Trickplay directories ---
    local subdir subname tp_base
    while IFS= read -r -d '' subdir; do
        subname=$(basename "$subdir")

        if [[ "$subname" == "trickplay" ]]; then
            # Generic trickplay: orphaned when parent has no video files
            if ! dir_has_videos "$dir"; then
                printf 'Orphaned trickplay directory: %s\n' "$subdir"
                do_remove_dir "$subdir"
                REMOVED_DIRS=$((REMOVED_DIRS + 1))
            else
                log_debug "Trickplay OK: $subdir"
            fi
        elif [[ "$subname" == *.trickplay ]]; then
            # Named trickplay: check for matching video in parent
            tp_base="${subname%.trickplay}"
            if ! video_exists "$dir" "$tp_base"; then
                printf 'Orphaned trickplay directory: %s\n' "$subdir"
                do_remove_dir "$subdir"
                REMOVED_DIRS=$((REMOVED_DIRS + 1))
            else
                log_debug "Trickplay OK: $subdir"
            fi
        fi
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d \
        \( -name 'trickplay' -o -name '*.trickplay' \) -print0 2>/dev/null)

    # --- Stale .skip_<basename> markers ---
    local skipfile marker_base
    while IFS= read -r -d '' skipfile; do
        marker_base="${skipfile##*/.skip_}"
        if ! video_exists "$dir" "$marker_base"; then
            printf 'Stale skip marker: %s\n' "$skipfile"
            do_remove_file "$skipfile"
            REMOVED_SKIPS=$((REMOVED_SKIPS + 1))
        else
            log_debug "Skip marker OK: $(basename "$skipfile")"
        fi
    done < <(find "$dir" -maxdepth 1 -name '.skip_*' -type f -print0 2>/dev/null)

    # --- Dangling NFO sidecars ---
    local nfofile nfo_base
    while IFS= read -r -d '' nfofile; do
        nfo_base=$(basename "${nfofile%.nfo}")
        if is_generic_nfo "$nfo_base"; then
            log_debug "Skipping generic NFO: $(basename "$nfofile")"
            continue
        fi
        if ! video_exists "$dir" "$nfo_base"; then
            printf 'Dangling NFO: %s\n' "$nfofile"
            do_remove_file "$nfofile"
            REMOVED_NFOS=$((REMOVED_NFOS + 1))
        else
            log_debug "NFO OK: $(basename "$nfofile")"
        fi
    done < <(find "$dir" -maxdepth 1 -name '*.nfo' -type f -print0 2>/dev/null)

    log_debug "Directory: $dir"

    # Recurse into subdirectories, skipping trickplay directories
    while IFS= read -r -d '' subdir; do
        subname=$(basename "$subdir")
        [[ "$subname" == "trickplay" || "$subname" == *.trickplay ]] && continue
        process_dir "$subdir"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if [[ ! -d "$ROOT" ]]; then
    printf 'ERROR: Root directory does not exist: %s\n' "$ROOT" >&2
    exit 1
fi

ROOT=$(cd "$ROOT" && pwd)
process_dir "$ROOT"

AUDIT_NOTE=""
$AUDIT && AUDIT_NOTE=" (audit - no changes made)"
printf '\nDone%s  |  Trickplay dirs: %d  |  Stale .skip markers: %d  |  Dangling NFOs: %d\n' \
    "$AUDIT_NOTE" "$REMOVED_DIRS" "$REMOVED_SKIPS" "$REMOVED_NFOS"
