#!/usr/bin/env bash
#
# =============================================================================
# SYNOPSIS
#   Sets file timestamps on movie video and NFO file pairs based on the NFO
#   release date.
#
# DESCRIPTION
#   Recursively scans the current directory for MKV and MP4 video files.
#   For each video, looks for a matching <basename>.nfo file. If found, the
#   NFO is parsed for <premiered> (preferred, YYYY-MM-DD) or <year> (fallback,
#   resolved to January 1 of that year). Both the video and NFO file mtime
#   values are set to midday (12:00:00) on the resolved date.
#
#   Files are skipped when:
#   - Any path segment is named 'extras' (case-insensitive).
#   - The file base name ends with a known non-feature suffix such as
#     -trailer, -behindthescenes, -featurette, -interview, -scene, -short,
#     -deleted, or -sample.
#   - No matching NFO file is found.
#
#   If the NFO contains no recognisable date, the earliest mtime of the two
#   files is used and both are set to midday on that day.
#
# REQUIREMENTS
#   xmlstarlet
#   bash 4+
#   GNU coreutils (stat -c, date -d) or macOS equivalents
#
# USAGE
#   ./setreleasedate.sh
#   ./setreleasedate.sh --debug
# =============================================================================

# Reset any inherited shell options (Proxmox root shells often force -eu)
set +euo
set -e
set -u
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

DEBUG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) DEBUG=1 ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log_debug() {
    [[ $DEBUG -eq 1 ]] && printf '[DEBUG] %s\n' "$1" || true
}

# Extract a single text value from an XML file via XPath.
xml_get() {
    local file="$1" xpath="$2"
    xmlstarlet sel -t -v "$xpath" -n "$file" 2>/dev/null || true
}

# Return the mtime of a file as a Unix epoch integer.
get_mtime_epoch() {
    local file="$1"
    stat -c '%Y' "$file" 2>/dev/null \
        || stat -f '%m' "$file" 2>/dev/null \
        || echo 0
}

# Convert a Unix epoch to a YYYY-MM-DD string.
epoch_to_date() {
    local epoch="$1"
    date -d "@$epoch" '+%Y-%m-%d' 2>/dev/null \
        || date -r "$epoch" '+%Y-%m-%d'
}

# Set the mtime of a file to the given datetime string (YYYY-MM-DD HH:MM:SS).
set_timestamp() {
    local file="$1" ts_str="$2"
    # GNU date / Linux
    if touch -d "$ts_str" "$file" 2>/dev/null; then return 0; fi
    # BSD date / macOS
    local fmt
    fmt=$(date -jf '%Y-%m-%d %H:%M:%S' "$ts_str" '+%Y%m%d%H%M.%S' 2>/dev/null) || return 1
    touch -t "$fmt" "$file"
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

for cmd in xmlstarlet; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf 'ERROR: Required command "%s" not found\n' "$cmd" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

processed=0
skipped=0
errors=0

# Suffixes that identify non-main-feature content (lower-cased for comparison)
SKIP_SUFFIXES=(
    '-trailer'
    '-behindthescenes'
    '-featurette'
    '-interview'
    '-scene'
    '-short'
    '-deleted'
    '-sample'
)

while IFS= read -r -d '' video; do
    # Remove the extension to construct the NFO path
    base="${video%.*}"
    nfo="${base}.nfo"

    log_debug "Checking: $video"

    # Skip files inside an 'extras' directory (any level)
    if printf '%s' "$video" | grep -iqE '(^|/)extras/'; then
        log_debug "  Inside 'extras' directory - skipping"
        skipped=$((skipped + 1))
        continue
    fi

    # Skip files whose base name (no extension) ends with a non-feature suffix
    base_lower=$(printf '%s' "$(basename "$base")" | tr '[:upper:]' '[:lower:]')
    is_extra=0
    for suffix in "${SKIP_SUFFIXES[@]}"; do
        if [[ "$base_lower" == *"$suffix" ]]; then
            is_extra=1
            break
        fi
    done
    if [[ $is_extra -eq 1 ]]; then
        log_debug "  Non-feature suffix detected - skipping"
        skipped=$((skipped + 1))
        continue
    fi

    if [[ ! -f "$nfo" ]]; then
        log_debug "  No NFO found - skipping"
        skipped=$((skipped + 1))
        continue
    fi

    log_debug "  NFO: $nfo"

    target_date=""

    # Primary: <premiered>YYYY-MM-DD</premiered>
    premiered=$(xml_get "$nfo" '/movie/premiered')
    log_debug "  premiered = '$premiered'"

    if [[ "$premiered" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        target_date="$premiered"
        log_debug "  Using premiered: $target_date"
    fi

    # Fallback: <year>YYYY</year>  ->  January 1 of that year
    if [[ -z "$target_date" ]]; then
        yr=$(xml_get "$nfo" '/movie/year')
        log_debug "  year = '$yr'"
        if [[ "$yr" =~ ^[0-9]{4}$ ]]; then
            target_date="${yr}-01-01"
            log_debug "  Using year fallback: $target_date"
        fi
    fi

    # No date in NFO - use the earliest mtime of the two files
    if [[ -z "$target_date" ]]; then
        log_debug "  No date in NFO - comparing file timestamps"
        video_epoch=$(get_mtime_epoch "$video")
        nfo_epoch=$(get_mtime_epoch "$nfo")
        if [[ $video_epoch -le $nfo_epoch ]]; then
            earliest_epoch=$video_epoch
        else
            earliest_epoch=$nfo_epoch
        fi
        target_date=$(epoch_to_date "$earliest_epoch") || {
            printf 'ERROR: Could not determine date for "%s"\n' "$video" >&2
            errors=$((errors + 1))
            continue
        }
        log_debug "  Earliest timestamp date: $target_date"
    fi

    ts_str="${target_date} 12:00:00"
    printf '%s  ->  %s\n' "$video" "$ts_str"

    if set_timestamp "$video" "$ts_str" && set_timestamp "$nfo" "$ts_str"; then
        processed=$((processed + 1))
    else
        printf 'ERROR: Failed to set timestamps on "%s"\n' "$video" >&2
        errors=$((errors + 1))
    fi

done < <(find . -type f \( -iname '*.mkv' -o -iname '*.mp4' \) -print0)

printf '\nDone.  Processed: %d   Skipped (no NFO): %d   Errors: %d\n' \
    "$processed" "$skipped" "$errors"
