#!/usr/bin/env bash
#
# =============================================================================
# SYNOPSIS
#   Applies episode metadata from NFO files to MKV files using mkvpropedit.
#
# DESCRIPTION
#   Reads metadata from basename.nfo (episode-level) and writes it into MKV
#   container tags. If <showtitle> is missing, the script optionally falls back
#   to movie.nfo in the same directory. If still missing, the script falls back
#   to the parent directory name (series folder).
#
#   The script preserves file timestamps (mtime only on Linux), supports
#   dry-run mode, optional debug output, and optional audit logging.
#
# REQUIREMENTS
#   mkvtoolnix (mkvpropedit, mkvinfo)
#   xmlstarlet
#   bash 4+
#
# USAGE
#   ./apply-episode-metadata.sh --debug
#   ./apply-episode-metadata.sh --audit-log "./audit.log"
#   ./apply-episode-metadata.sh --dry-run
#
# NOTES
#   Linux cannot restore ctime or creation time. Only mtime is preserved.
# =============================================================================

set +euo
IFS=$'\n\t'

# ------------------------------
# Argument parsing
# ------------------------------
DRYRUN=0
DEBUG=0
AUDIT_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log)
            AUDIT_LOG="$2"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

LOGGING_ENABLED=0
[[ -n "$AUDIT_LOG" ]] && LOGGING_ENABLED=1


echo "AUDIT_LOG='$AUDIT_LOG' LOGGING_ENABLED=$LOGGING_ENABLED"

# ------------------------------
# Dependency checks
# ------------------------------
for cmd in xmlstarlet mkvmerge mkvpropedit jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done

# ------------------------------
# Logging helpers
# ------------------------------
log_audit() {
    [[ $LOGGING_ENABLED -eq 1 ]] || return
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$AUDIT_LOG"
}

log_debug() {
    if [[ $DEBUG -eq 1 ]]; then
        printf '[DEBUG] %s\n' "$1"
        [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[DEBUG] $1"
    fi
}

# ------------------------------
# XML helper
# ------------------------------
xml_get() {
    local file="$1"
    local xpath="$2"
    xmlstarlet sel -t -v "$xpath" -n "$file" 2>/dev/null || true
}

# ------------------------------
# MKV title reader (safe)
# ------------------------------
get_mkv_title() {
    local mkv="$1"
    mkvmerge --identify --identification-format json "$mkv" 2>/dev/null \
        | jq -r '.container.properties.title // empty'
}

# ------------------------------
# Build tags XML
# ------------------------------
build_tags_xml() {
    local outfile="$1"
    {
        echo "<Tags>"
        echo "  <Tag>"
        for key in TITLE SERIES SEASON EPISODE DESCRIPTION DATE_RELEASED; do
            local val="${TAGS[$key]}"
            local esc
            esc=$(printf '%s' "$val" | xmlstarlet esc)
            printf '    <Simple><Name>%s</Name><String>%s</String></Simple>\n' \
                "$key" "$esc"
        done
        echo "  </Tag>"
        echo "</Tags>"
    } > "$outfile"
}

# ------------------------------
# Begin processing
# ------------------------------
echo "Scanning recursively for MKV files..."
log_audit "=== Episode run started ==="

# Corrected loop — no subshell
tmpfile=$(mktemp)
find . -type f -iname '*.mkv' -print0 > "$tmpfile"
while IFS= read -r -d '' mkv; do

    echo "----"
    echo "Processing MKV: $mkv"
    log_audit "Processing MKV: $mkv"

    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)
    nfo="$dir/$base.nfo"

    if [[ ! -f "$nfo" ]]; then
        echo "Skipping: No matching NFO found."
        log_audit "Skipped: Missing NFO"
        continue
    fi

    # Validate episode NFO safely
    count=$(xmlstarlet sel -t -v "count(/episodedetails)" "$nfo" 2>/dev/null || echo 0)
    if [[ "$count" != "1" ]]; then
        echo "Skipping: Not episode NFO."
        log_audit "Skipped: Not episode NFO"
        continue
    fi

    # ------------------------------
    # Extract metadata
    # ------------------------------
    ep_title=$(xml_get "$nfo" "/episodedetails/title")
    ep_season=$(xml_get "$nfo" "/episodedetails/season")
    ep_number=$(xml_get "$nfo" "/episodedetails/episode")
    ep_plot=$(xml_get "$nfo" "/episodedetails/plot")
    ep_aired=$(xml_get "$nfo" "/episodedetails/aired")
    ep_year="${ep_aired:0:4}"

    # Resolve series title
    series=$(xml_get "$nfo" "/episodedetails/showtitle")

    # Fallback: movie.nfo
    if [[ -z "$series" ]]; then
        movie_nfo="$dir/movie.nfo"
        if [[ -f "$movie_nfo" ]]; then
            log_debug "Loading title from movie.nfo"
            series=$(xml_get "$movie_nfo" "/movie/title")
        fi
    fi

    # Fallback: parent folder
    if [[ -z "$series" ]]; then
        series=$(basename "$(dirname "$dir")")
        log_debug "Fallback to series root folder name: $series"
    fi

    # ------------------------------
    # Build tag map
    # ------------------------------
    declare -A TAGS=(
        [TITLE]="$ep_title"
        [SERIES]="$series"
        [SEASON]="$ep_season"
        [EPISODE]="$ep_number"
        [DESCRIPTION]="$ep_plot"
        [DATE_RELEASED]="$ep_year"
    )

    # ------------------------------
    # Compare existing MKV title
    # ------------------------------
    existing_title=$(get_mkv_title "$mkv")
    new_global_title="${series}: ${ep_title}"

    if [[ -n "$existing_title" && "$existing_title" == "$new_global_title" ]]; then
        echo "Skipping: Already processed."
        log_audit "Skipped: Already processed"
        continue
    fi

    # ------------------------------
    # Preserve timestamps (mtime only)
    # ------------------------------
    orig_mtime=$(stat -c %y "$mkv")
    log_debug "Preserving timestamps (mtime only)."

    # ------------------------------
    # Apply metadata
    # ------------------------------
    temp_tags=$(mktemp /tmp/episode_tags_XXXXXX.xml)
    build_tags_xml "$temp_tags"

    if [[ $DRYRUN -eq 0 ]]; then
        mkvpropedit "$mkv" --edit info --set "title="
        mkvpropedit "$mkv" --edit info --set "title=$new_global_title"
        mkvpropedit "$mkv" --tags all:"$temp_tags"

        touch -d "$orig_mtime" "$mkv"

        log_audit "Metadata applied"
    else
        log_audit "Dry-run: No changes applied"
    fi

    rm -f "$temp_tags"

done < "$tmpfile"

rm -f "$tmpfile"

log_audit "=== Episode run complete ==="
