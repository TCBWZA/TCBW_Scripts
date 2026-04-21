#!/usr/bin/env bash
#
# =============================================================================
# SYNOPSIS
#   Sets file timestamps on TV episode video and NFO file pairs based on the
#   NFO air date.
#
# DESCRIPTION
#   Recursively scans the current directory for MKV and MP4 video files.
#   For each video, looks for a matching <basename>.nfo file. If found, the
#   NFO is parsed for <aired> (YYYY-MM-DD). The video and NFO file mtime
#   values are both set to midday (12:00:00) on the resolved date.
#
#   If the NFO contains no recognisable date, the earliest mtime of the two
#   files is used and both are set to midday on that day.
#
#   Video files without a matching NFO are skipped.
#
#   TV episode NFOs are expected to use the Kodi <episodedetails> schema
#   with an <aired> element.
#
# REQUIREMENTS
#   xmlstarlet
#   bash 4+
#   GNU coreutils (stat -c, date -d) or macOS equivalents
#
# USAGE
#   ./setairdate.sh
#   ./setairdate.sh --debug
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

# Return the birth time (creation time) of a directory as a Unix epoch integer.
# Falls back to mtime if birth time is unavailable (e.g. older kernels/filesystems).
get_dir_birth_epoch() {
    local dir="$1"
    local epoch
    # GNU stat: %W is birth time epoch (0 if unsupported)
    epoch=$(stat -c '%W' "$dir" 2>/dev/null || echo 0)
    if [[ "$epoch" -eq 0 ]]; then
        # macOS BSD stat: -f '%SB' -t '%s' prints birth time as epoch
        epoch=$(stat -f '%SB' -t '%s' "$dir" 2>/dev/null || echo 0)
    fi
    if [[ "$epoch" -eq 0 ]]; then
        # Last resort: use mtime of the directory
        epoch=$(stat -c '%Y' "$dir" 2>/dev/null \
            || stat -f '%m' "$dir" 2>/dev/null \
            || echo 0)
    fi
    echo "$epoch"
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

while IFS= read -r -d '' video; do
    # Remove the extension to construct the NFO path
    base="${video%.*}"
    nfo="${base}.nfo"

    log_debug "Checking: $video"

    if [[ ! -f "$nfo" ]]; then
        log_debug "  No NFO found - skipping"
        skipped=$((skipped + 1))
        continue
    fi

    log_debug "  NFO: $nfo"

    target_date=""

    # TV episode NFOs use <aired>YYYY-MM-DD</aired>
    aired=$(xml_get "$nfo" '/episodedetails/aired')
    log_debug "  aired = '$aired'"

    if [[ "$aired" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # Treat dates more than 30 days in the future as corrupted metadata
        # (e.g. typos like 2038-01-01). Leave target_date empty so the
        # file-timestamp -> folder-date fallback chain resolves the date,
        # which also retroactively corrects files set by a previous bad run.
        _aired_epoch=$(date -d "$aired" '+%s' 2>/dev/null \
            || date -jf '%Y-%m-%d' "$aired" '+%s' 2>/dev/null \
            || echo 0)
        _max_future=$(date -d "+30 days" '+%s' 2>/dev/null || date -v+30d '+%s')
        if [[ $_aired_epoch -gt $_max_future ]]; then
            printf 'WARNING: NFO aired date %s is more than 30 days in the future - treating as corrupt; falling back to file/folder timestamps\n' \
                "$aired" >&2
            log_debug "  Corrupt NFO date discarded"
        else
            target_date="$aired"
            log_debug "  Using aired: $target_date"
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

        # If the file timestamps are more than 30 days in the future, fall back
        # to the parent folder's creation date (birth time, or mtime if unavailable)
        _max_future=$(date -d "+30 days" '+%s' 2>/dev/null || date -v+30d '+%s')
        _file_epoch=$(date -d "$target_date" '+%s' 2>/dev/null \
            || date -jf '%Y-%m-%d' "$target_date" '+%s')
        if [[ $_file_epoch -gt $_max_future ]]; then
            _dir=$(dirname "$video")
            _folder_epoch=$(get_dir_birth_epoch "$_dir")
            target_date=$(epoch_to_date "$_folder_epoch") || {
                printf 'ERROR: Could not determine folder date for "%s"\n' "$video" >&2
                errors=$((errors + 1))
                continue
            }
            log_debug "  File timestamps future-dated; using folder date: $target_date"
        fi
    fi

    # Reject dates more than 30 days in the future
    target_epoch=$(date -d "$target_date" '+%s' 2>/dev/null || date -jf '%Y-%m-%d' "$target_date" '+%s')
    max_future_epoch=$(date -d "+30 days" '+%s' 2>/dev/null || date -v+30d '+%s')
    if [[ $target_epoch -gt $max_future_epoch ]]; then
        printf 'WARNING: Skipping "%s": resolved date %s is more than 30 days in the future\n' \
            "$video" "$target_date" >&2
        skipped=$((skipped + 1))
        continue
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
