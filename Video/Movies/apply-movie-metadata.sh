#!/usr/bin/env bash
#
# =============================================================================
# MOVIE METADATA APPLIER
#   Applies movie metadata from NFO files to MKV files using mkvpropedit.
#
# RULES
#   - Primary metadata source: <basename>.nfo
#   - Fallback metadata source: movie.nfo
#   - If <title> missing: use directory name
#   - No episode logic at all
#
# FEATURES
#   - Preserves mtime
#   - Debug mode
#   - Dry-run mode
#   - Optional audit logging
#   - Proxmox-safe (no process substitution, no pipefail)
# =============================================================================

# Reset inherited shell options (Proxmox root shells often force -eu)
set +euo
set -e
set -u
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
# Logging helpers
# ------------------------------
log_audit() {
    if [[ $LOGGING_ENABLED -eq 1 ]]; then
        printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$AUDIT_LOG"
    fi
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
    log_debug "xml_get accessed"
    xmlstarlet sel -t -v "$2" "$1" 2>/dev/null || true
}

# ------------------------------
# MKV title reader
# ------------------------------
get_mkv_title() {
    local mkv="$1"
    mkvinfo "$mkv" 2>/dev/null | grep -Po 'Title:\s*\K.*' | head -n1 || true
}

# ------------------------------
# Build tags XML
# ------------------------------
build_tags_xml() {
    local outfile="$1"
    {
        echo "<Tags>"
        echo "  <Tag>"
        for key in TITLE YEAR TAGLINE PLOT PREMIERED; do
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
# Dependency checks
# ------------------------------
for cmd in xmlstarlet mkvinfo mkvpropedit; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done

# ------------------------------
# Prepare TAGS array (fix for set -u)
# ------------------------------
declare -A TAGS

# ------------------------------
# Begin processing
# ------------------------------
echo "Scanning recursively for MKV files..."
log_audit "=== Movie run started ==="

tmpfile=$(mktemp)
find . -type f -iname '*.mkv' -print0 > "$tmpfile"

while IFS= read -r -d '' mkv; do
    echo "----"
    echo "Processing MKV: $mkv"
    log_audit "Processing MKV: $mkv"

    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)

    primary_nfo="$dir/$base.nfo"
    fallback_nfo="$dir/movie.nfo"

    # ------------------------------
    # Select metadata source
    # ------------------------------
    nfo=""
    if [[ -f "$primary_nfo" ]]; then
        nfo="$primary_nfo"
        log_debug "Using primary NFO: $primary_nfo"
    elif [[ -f "$fallback_nfo" ]]; then
        nfo="$fallback_nfo"
        log_debug "Using fallback NFO: $fallback_nfo"
    else
        echo "Skipping: No NFO found."
        log_audit "Skipped: No NFO"
        continue
    fi

    # Validate movie NFO
    count=$(xmlstarlet sel -t -v "count(/movie)" "$nfo" 2>/dev/null || echo 0)
    if [[ "$count" != "1" ]]; then
        echo "Skipping: Invalid movie NFO."
        log_audit "Skipped: Invalid movie NFO"
        continue
    fi

    # ------------------------------
    # Extract metadata
    # ------------------------------
    log_debug "Process Metadata"
    title=$(xml_get "$nfo" "/movie/title")
    log_debug "Title: $title"
    plot=$(xml_get "$nfo" "/movie/plot")
    log_debug "Plot: $plot"
    tagline=$(xml_get "$nfo" "/movie/tagline")
    log_debug "Tagline: $tagline"
    premiered=$(xml_get "$nfo" "/movie/premiered")
    log_debug "Premiered: $premiered"
    year=""
    if [[ -n "$premiered" ]]; then
        year="${premiered:0:4}"
    fi
    log_debug "Year: $year"


    # ------------------------------
    # Title fallback: directory name
    # ------------------------------
    if [[ -z "$title" ]]; then
        title=$(basename "$dir")
        log_debug "Fallback: using directory name as title: $title"
    fi

    # Build MKV title
    new_title="$title"
    [[ -n "$year" ]] && new_title="$title ($year)"

    # ------------------------------
    # Compare existing MKV title
    # ------------------------------
    existing_title=$(get_mkv_title "$mkv")
    if [[ -n "$existing_title" && "$existing_title" == "$new_title" ]]; then
        echo "Skipping: Already processed."
        log_audit "Skipped: Already processed"
        continue
    fi

    # ------------------------------
    # Build tag map
    # ------------------------------
    TAGS[TITLE]="$title"
    TAGS[YEAR]="$year"
    TAGS[TAGLINE]="$tagline"
    TAGS[PLOT]="$plot"
    TAGS[PREMIERED]="$premiered"

    # ------------------------------
    # Preserve timestamps
    # ------------------------------
    orig_mtime=$(stat -c %y "$mkv")
    log_debug "Preserving timestamps (mtime only)."

    # ------------------------------
    # Apply metadata
    # ------------------------------
    temp_tags=$(mktemp /tmp/movie_tags_XXXXXX.xml)
    build_tags_xml "$temp_tags"

    if [[ $DRYRUN -eq 0 ]]; then
        log_debug "Setting MKV title: $new_title"
        mkvpropedit "$mkv" --edit info --set "title=$new_title"

        log_debug "Applying XML tags from $temp_tags"
        mkvpropedit "$mkv" --tags all:"$temp_tags"

        touch -d "$orig_mtime" "$mkv"
        log_audit "Metadata applied"
    else
        log_audit "Dry-run: No changes applied"
    fi

    rm -f "$temp_tags"

done < "$tmpfile"

rm -f "$tmpfile"

log_audit "=== Movie run complete ==="

