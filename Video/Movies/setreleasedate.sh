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
#   ./setreleasedate.sh --nonfo <file>
#
# OPTIONS
#   --nonfo <file>
#       Append the full path of each video skipped due to a missing NFO to
#       <file>. The file is created if it does not exist. <file> must be a
#       valid Linux filename (no null bytes; not '.' or '..'; the parent
#       directory must exist and be writable).
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
NONFO_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) DEBUG=1 ;;
        --nonfo)
            if [[ $# -lt 2 ]]; then
                printf 'ERROR: --nonfo requires a file argument\n' >&2
                exit 1
            fi
            shift
            NONFO_FILE="$1"
            # Validate: no null bytes (bash strings can't contain them anyway),
            # not '.' or '..', and the parent directory must exist and be writable.
            _nonfo_base=$(basename "$NONFO_FILE")
            _nonfo_dir=$(dirname "$NONFO_FILE")
            if [[ -z "$_nonfo_base" || "$_nonfo_base" == '.' || "$_nonfo_base" == '..' ]]; then
                printf 'ERROR: --nonfo filename "%s" is not valid\n' "$NONFO_FILE" >&2
                exit 1
            fi
            if [[ ! -d "$_nonfo_dir" ]]; then
                printf 'ERROR: --nonfo parent directory "%s" does not exist\n' "$_nonfo_dir" >&2
                exit 1
            fi
            if [[ ! -w "$_nonfo_dir" ]]; then
                printf 'ERROR: --nonfo parent directory "%s" is not writable\n' "$_nonfo_dir" >&2
                exit 1
            fi
            ;;
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
filtered=0
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
    _dir=$(dirname "$video")
    _base_no_ext=$(basename "$base")

    log_debug "Checking: $video"

    # Skip if directory .skip marker exists
    if [[ -f "${_dir}/.skip" ]]; then
        log_debug "  .skip directory marker found - skipping"
        filtered=$((filtered + 1))
        continue
    fi

    # Skip if per-file .skip_<basename> marker exists
    if [[ -f "${_dir}/.skip_${_base_no_ext}" ]]; then
        log_debug "  .skip_${_base_no_ext} per-file marker found - skipping"
        filtered=$((filtered + 1))
        continue
    fi

    # Skip files inside an 'extras' directory (any level)
    if printf '%s' "$video" | grep -iqE '(^|/)extras/'; then
        log_debug "  Inside 'extras' directory - skipping"
        filtered=$((filtered + 1))
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
        filtered=$((filtered + 1))
        continue
    fi

    if [[ ! -f "$nfo" ]]; then
        # Fall back to movie.nfo in the same directory
        _movie_nfo="$(dirname "$video")/movie.nfo"
        if [[ -f "$_movie_nfo" ]]; then
            log_debug "  '$(basename "$nfo")' not found; using movie.nfo"
            nfo="$_movie_nfo"
        fi
    fi

    if [[ ! -f "$nfo" ]]; then
        log_debug "  No NFO found - skipping"
        if [[ -n "$NONFO_FILE" ]]; then
            printf '%s\n' "$video" >> "$NONFO_FILE"
        fi
        skipped=$((skipped + 1))
        continue
    fi

    log_debug "  NFO: $nfo"

    target_date=""

    # Primary: <premiered>YYYY-MM-DD</premiered>
    premiered=$(xml_get "$nfo" '/movie/premiered')
    log_debug "  premiered = '$premiered'"

    if [[ "$premiered" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        # Treat dates more than 30 days in the future as corrupted metadata
        # (e.g. typos like 2038-01-01). Leave target_date empty so the
        # file-timestamp -> folder-date fallback chain resolves the date,
        # which also retroactively corrects files set by a previous bad run.
        _premiered_epoch=$(date -d "$premiered" '+%s' 2>/dev/null \
            || date -jf '%Y-%m-%d' "$premiered" '+%s' 2>/dev/null \
            || echo 0)
        _max_future=$(date -d "+30 days" '+%s' 2>/dev/null || date -v+30d '+%s')
        if [[ $_premiered_epoch -gt $_max_future ]]; then
            # If <year> is present and earlier than the corrupt premiered year,
            # substitute it to recover the correct date (keeps month and day).
            _premiered_yr="${premiered:0:4}"
            _yr=$(xml_get "$nfo" '/movie/year')
            if [[ "$_yr" =~ ^[0-9]{4}$ ]] && [[ $_yr -lt $_premiered_yr ]]; then
                _corrected="${_yr}${premiered:4}"  # replace year, keep -MM-DD
                _corrected_epoch=$(date -d "$_corrected" '+%s' 2>/dev/null \
                    || date -jf '%Y-%m-%d' "$_corrected" '+%s' 2>/dev/null \
                    || echo 0)
                if [[ $_corrected_epoch -gt 0 ]] && [[ $_corrected_epoch -le $_max_future ]]; then
                    target_date="$_corrected"
                    log_debug "  premiered year corrected using <year> $_yr: $target_date"
                else
                    printf 'WARNING: NFO premiered date %s: year-corrected date %s is still in the future - falling back to file/folder timestamps\n' \
                        "$premiered" "$_corrected" >&2
                    log_debug "  Corrupt NFO date discarded after year correction attempt"
                fi
            else
                printf 'WARNING: NFO premiered date %s is more than 30 days in the future - treating as corrupt; falling back to file/folder timestamps\n' \
                    "$premiered" >&2
                log_debug "  Corrupt NFO date discarded"
            fi
        else
            target_date="$premiered"
            log_debug "  Using premiered: $target_date"
        fi
    fi

    # Fallback: <year>YYYY</year>  ->  January 1 of that year
    if [[ -z "$target_date" ]]; then
        yr=$(xml_get "$nfo" '/movie/year')
        log_debug "  year = '$yr'"
        if [[ "$yr" =~ ^[0-9]{4}$ ]]; then
            _year_date="${yr}-01-01"
            _year_epoch=$(date -d "$_year_date" '+%s' 2>/dev/null \
                || date -jf '%Y-%m-%d' "$_year_date" '+%s' 2>/dev/null \
                || echo 0)
            _max_future=$(date -d "+30 days" '+%s' 2>/dev/null || date -v+30d '+%s')
            if [[ $_year_epoch -gt $_max_future ]]; then
                printf 'WARNING: NFO year %s resolves to a date more than 30 days in the future - treating as corrupt; falling back to file/folder timestamps\n' \
                    "$yr" >&2
                log_debug "  Corrupt year value discarded"
            else
                target_date="$_year_date"
                log_debug "  Using year fallback: $target_date"
            fi
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

printf '\nDone.  Processed: %d   Skipped (no NFO): %d   Filtered (extras/trailers): %d   Errors: %d\n' \
    "$processed" "$skipped" "$filtered" "$errors"
