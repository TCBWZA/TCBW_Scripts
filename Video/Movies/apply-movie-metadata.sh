#!/usr/bin/env bash
#
# =============================================================================
# MOVIE METADATA APPLIER (Proxmox‑safe, colourised)
# =============================================================================
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

# ------------------------------
# Shell options (Proxmox‑safe)
# ------------------------------
set -ou pipefail
IFS=$'\n\t'

# ------------------------------
# Colour definitions
# ------------------------------
CLR_RESET="\033[0m"
CLR_DEBUG="\033[1;35m"
CLR_INFO="\033[1;36m"
CLR_WARN="\033[1;33m"
CLR_ERROR="\033[1;31m"

# ------------------------------
# Logging helpers
# ------------------------------
log_audit() {
    if [[ $LOGGING_ENABLED -eq 1 ]]; then
        printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$AUDIT_LOG"
    fi
}

log_info() {
    >&2 printf "${CLR_INFO}[INFO]${CLR_RESET} %s\n" "$1"
    [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[INFO] $1"
}

log_warn() {
    >&2 printf "${CLR_WARN}[WARN]${CLR_RESET} %s\n" "$1"
    [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[WARN] $1"
}

log_error() {
    >&2 printf "${CLR_ERROR}[ERROR]${CLR_RESET} %s\n" "$1"
    [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[ERROR] $1"
}

log_debug() {
    if [[ $DEBUG -eq 1 ]]; then
        >&2 printf "${CLR_DEBUG}[DEBUG]${CLR_RESET} %s\n" "$1"
        [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[DEBUG] $1"
    fi
}

# ------------------------------
# xml_get (YOUR WORKING VERSION)
# ------------------------------
xml_get() {
    local file="$1"
    local path="$2"
    local value

    value=$(xmlstarlet sel -t -v "$path" "$file" 2>/dev/null || true)

    # Send debug to stderr so it does NOT interfere with command substitution
    >&2 log_debug "xml_get $path => '$value'"

    printf '%s' "$value"
}

# ------------------------------
# MKV tag reader
# ------------------------------
get_mkv_tag() {
    local xmlfile="$1"
    local tagname="$2"
    xmlstarlet sel -t -v "//Simple[Name='$tagname']/String" "$xmlfile" 2>/dev/null || true
}

# ------------------------------
# Build tags XML
# ------------------------------
build_tags_xml() {
    local outfile="$1"
    {
        echo "<Tags>"
        echo "  <Tag>"
        for key in TITLE DATE_RELEASED TAGLINE PLOT PREMIERED; do
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
for cmd in xmlstarlet mkvmerge mkvpropedit mkvextract jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command '$cmd' not found"
        exit 1
    fi
done

# ------------------------------
# Argument parsing
# ------------------------------
DRYRUN=0
DEBUG=0
AUDIT_LOG=""
LOGGING_ENABLED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log)
            AUDIT_LOG="$2"
            shift
            ;;
        *)
            log_error "Unknown argument: $1"
            exit 1
            ;;
    esac
    shift
done

[[ -n "$AUDIT_LOG" ]] && LOGGING_ENABLED=1

declare -A TAGS

# ------------------------------
# Begin processing
# ------------------------------
log_info "Scanning recursively for MKV files..."
log_audit "=== Movie run started ==="

tmpfile=$(mktemp)
find . -type f -iname '*.mkv' \
    ! -iname '*-trailer.*' \
    ! -iname '*-deleted.*' \
    ! -iname '*-behindthescenes.*' \
    ! -iname '*-interview.*' \
    -print0 > "$tmpfile"

while IFS= read -r -d '' mkv; do
    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)

    # Skip markers
    if [[ -f "${dir}/.skip" ]]; then
        log_warn "Skipping $mkv -- .skip directory marker found"
        continue
    fi

    if [[ -f "${dir}/.skip_${base}" ]]; then
        log_warn "Skipping $mkv -- .skip_${base} per-file marker found"
        continue
    fi

    log_info "Processing MKV: $mkv"
    log_audit "Processing MKV: $mkv"

    primary_nfo="$dir/$base.nfo"
    fallback_nfo="$dir/movie.nfo"
    nfo=""

    # Select metadata source
    if [[ -f "$primary_nfo" ]]; then
        nfo="$primary_nfo"
        log_debug "Using primary NFO: $primary_nfo"
    elif [[ -f "$fallback_nfo" ]]; then
        nfo="$fallback_nfo"
        log_debug "Using fallback NFO: $fallback_nfo"
    else
        log_warn "Skipping: No NFO found."
        log_audit "Skipped: No NFO"
        continue
    fi

    # ------------------------------
    # Robust movie NFO validation
    # ------------------------------
    root=$(xmlstarlet sel -t -v "name(/*)" "$nfo" 2>/dev/null || echo "")

    if [[ "$root" != "movie" ]]; then
        log_warn "Skipping: Invalid movie NFO (root='$root')."
        log_debug "Deleting invalid NFO: $nfo"
        rm -f "$nfo"
        log_audit "Deleted invalid NFO"
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

    # Title fallback: directory name
    if [[ -z "$title" ]]; then
        title=$(basename "$dir")
        log_debug "Fallback: using directory name as title: $title"
    fi

    # Build MKV title
    new_title="$title"
    [[ -n "$year" ]] && new_title="$title ($year)"

    # ------------------------------
    # Compare existing MKV tags
    # ------------------------------
    tags_tmp=$(mktemp /tmp/mkv_tags_XXXXXX.xml)
    mkvextract "$mkv" tags "$tags_tmp" 2>/dev/null || true

    if [[ -s "$tags_tmp" ]]; then
        ex_title=$(get_mkv_tag "$tags_tmp" "TITLE")
        ex_year=$(get_mkv_tag "$tags_tmp" "DATE_RELEASED")
        [[ -z "$ex_year" ]] && ex_year=$(get_mkv_tag "$tags_tmp" "YEAR")

        log_debug "Existing TITLE=$ex_title DATE_RELEASED=$ex_year"

        if [[ "$ex_title" == "$title" && "$ex_year" == "$year" ]]; then
            log_info "Skipping: Already processed."
            log_audit "Skipped: Already processed"
            rm -f "$tags_tmp"
            continue
        fi
    fi
    rm -f "$tags_tmp"

    # ------------------------------
    # Build tag map
    # ------------------------------
    TAGS[TITLE]="$title"
    TAGS[DATE_RELEASED]="$year"
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
        log_info "Dry-run: No changes applied"
        log_audit "Dry-run: No changes applied"
    fi

    rm -f "$temp_tags"

done < "$tmpfile"

rm -f "$tmpfile"

log_audit "=== Movie run complete ==="
log_info "Movie metadata run complete."
