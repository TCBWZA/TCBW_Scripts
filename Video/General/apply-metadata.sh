#!/usr/bin/env bash
#
# =============================================================================
# COMBINED MOVIE + TV EPISODE METADATA APPLIER (Proxmox‑safe, colourised)
#
# DESCRIPTION
#   Applies metadata from NFO files to MKV files for BOTH Movies and TV Episodes.
#
#   - Recurses from the current directory downward.
#   - Determines type from NFO root element:
#         <movie>          => Movie
#         <episodedetails> => TV Episode
#         <tvshow>         => Ignored (series-level)
#
#   - If episode <showtitle> is empty, load <title> from parent tvshow.nfo.
#   - tvshow.nfo lookups are cached per show directory.
#   - xmlstarlet is used via stdin to avoid filename/quoting issues.
# =============================================================================

set -ou pipefail
IFS=$'\n\t'

# ------------------------------
# Colours
# ------------------------------
CLR_RESET="\033[0m"
CLR_DEBUG="\033[1;35m"
CLR_INFO="\033[1;36m"
CLR_WARN="\033[1;33m"
CLR_ERROR="\033[1;31m"

# ------------------------------
# Logging
# ------------------------------
log_audit() {
    [[ $LOGGING_ENABLED -eq 1 ]] && printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$AUDIT_LOG"
}

log_info()  { >&2 printf "${CLR_INFO}[INFO]${CLR_RESET} %s\n" "$1";  [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[INFO] $1"; }
log_warn()  { >&2 printf "${CLR_WARN}[WARN]${CLR_RESET} %s\n" "$1";  [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[WARN] $1"; }
log_error() { >&2 printf "${CLR_ERROR}[ERROR]${CLR_RESET} %s\n" "$1"; [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[ERROR] $1"; }

log_debug() {
    if [[ $DEBUG -eq 1 ]]; then
        >&2 printf "${CLR_DEBUG}[DEBUG]${CLR_RESET} %s\n" "$1"
        [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[DEBUG] $1"
    fi
}

# ------------------------------
# xml helpers (stdin‑safe)
# ------------------------------
xml_get() {
    local file="$1"
    local path="$2"
    local value

    value=$(xmlstarlet sel -t -v "$path" < "$file" 2>/dev/null || true)

    # Trim whitespace (handles empty <showtitle> correctly)
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    log_debug "xml_get $path => '$value'"
    printf '%s' "$value"
}

xml_root() {
    local file="$1"
    xmlstarlet sel -t -v "name(/*)" < "$file" 2>/dev/null
}

# ------------------------------
# Build tags XML
# ------------------------------
build_tags_xml() {
    local outfile="$1"
    {
        echo "<Tags>"
        echo "  <Tag>"
        for key in "${!TAGS[@]}"; do
            local esc
            esc=$(printf '%s' "${TAGS[$key]}" | xmlstarlet esc)
            printf '    <Simple><Name>%s</Name><String>%s</String></Simple>\n' "$key" "$esc"
        done
        echo "  </Tag>"
        echo "</Tags>"
    } > "$outfile"
}

# ------------------------------
# Dependency checks
# ------------------------------
for cmd in xmlstarlet mkvmerge mkvpropedit mkvextract jq; do
    command -v "$cmd" >/dev/null 2>&1 || { log_error "Missing: $cmd"; exit 1; }
done

# ------------------------------
# Args
# ------------------------------
DRYRUN=0
DEBUG=0
AUDIT_LOG=""
LOGGING_ENABLED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log) AUDIT_LOG="$2"; shift ;;
        *) log_error "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

[[ -n "$AUDIT_LOG" ]] && LOGGING_ENABLED=1

declare -A TAGS

# ------------------------------
# Cache for tvshow.nfo lookups
# ------------------------------
declare -A TVSHOW_CACHE_TITLE
declare -A TVSHOW_CACHE_ROOT

# ------------------------------
# Begin
# ------------------------------
log_info "Scanning recursively for MKV files..."
log_audit "=== Combined Movie/TV run started ==="

tmpfile=$(mktemp)
find . -type f -iname '*.mkv' -print0 > "$tmpfile"

while IFS= read -r -d '' mkv; do

    # FIX: resolve absolute path so parent_dir is always correct
    mkv=$(realpath "$mkv")
    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)

    log_info "Processing MKV: $mkv"
    log_audit "Processing MKV: $mkv"

    # ------------------------------
    # Jellyfin-aware NFO detection
    # ------------------------------
    primary_nfo="$dir/$base.nfo"

    alt1_nfo="$dir/${base%% - *}.nfo"
    alt2_nfo="$dir/${base% - Episode*}.nfo"
    alt3_nfo="$dir/$(echo "$base" | sed -E 's/( - Episode.*)//').nfo"

    sxxeyy=$(echo "$base" | grep -oE 'S[0-9]{2}E[0-9]{2}')
    kodi_nfo="$dir/$sxxeyy.nfo"

    episode_nfo="$dir/episode.nfo"

    episode_num=$(echo "$base" | grep -oE 'E[0-9]{2}' | sed 's/E//')
    season_pattern_nfo="$dir/episode${episode_num}.nfo"

    movie_nfo="$dir/movie.nfo"
    tvshow_nfo="$dir/tvshow.nfo"

    nfo=""

    if [[ -f "$primary_nfo" ]]; then
        nfo="$primary_nfo"; log_debug "Using basename NFO: $primary_nfo"

    elif [[ -f "$alt1_nfo" ]]; then
        nfo="$alt1_nfo"; log_debug "Using Jellyfin alt1 NFO: $alt1_nfo"

    elif [[ -f "$alt2_nfo" ]]; then
        nfo="$alt2_nfo"; log_debug "Using Jellyfin alt2 NFO: $alt2_nfo"

    elif [[ -f "$alt3_nfo" ]]; then
        nfo="$alt3_nfo"; log_debug "Using Jellyfin alt3 NFO: $alt3_nfo"

    elif [[ -f "$kodi_nfo" ]]; then
        nfo="$kodi_nfo"; log_debug "Using SxxEyy NFO: $kodi_nfo"

    elif [[ -f "$episode_nfo" ]]; then
        nfo="$episode_nfo"; log_debug "Using episode.nfo"

    elif [[ -f "$season_pattern_nfo" ]]; then
        nfo="$season_pattern_nfo"; log_debug "Using season pattern NFO: $season_pattern_nfo"

    elif [[ -f "$movie_nfo" ]]; then
        nfo="$movie_nfo"; log_debug "Using movie.nfo fallback"

    elif [[ -f "$tvshow_nfo" ]]; then
        log_warn "Skipping tvshow.nfo (series-level metadata)"
        continue

    else
        log_warn "Skipping: No NFO found for $mkv"
        log_audit "Skipped: No NFO"
        continue
    fi

    # ------------------------------
    # Determine type
    # ------------------------------
    root=$(xml_root "$nfo")
    log_debug "NFO root='$root'"

    case "$root" in
        movie)          TYPE="MOVIE" ;;
        episodedetails) TYPE="EPISODE" ;;
        tvshow)         log_warn "Skipping series-level tvshow.nfo"; continue ;;
        *)              log_warn "Skipping unknown NFO type: $root"; continue ;;
    esac

    TAGS=()

    # ------------------------------
    # Extract metadata
    # ------------------------------
    if [[ "$TYPE" == "MOVIE" ]]; then
        title=$(xml_get "$nfo" "/movie/title")
        plot=$(xml_get "$nfo" "/movie/plot")
        tagline=$(xml_get "$nfo" "/movie/tagline")
        premiered=$(xml_get "$nfo" "/movie/premiered")
        year="${premiered:0:4}"

        [[ -z "$title" ]] && title=$(basename "$dir")

        new_title="$title"
        [[ -n "$year" ]] && new_title="$title ($year)"

        TAGS[TITLE]="$title"
        TAGS[DATE_RELEASED]="$year"
        TAGS[TAGLINE]="$tagline"
        TAGS[PLOT]="$plot"
        TAGS[PREMIERED]="$premiered"

    else
        showtitle=$(xml_get "$nfo" "/episodedetails/showtitle")
        log_debug "Episode NFO showtitle (raw)='$showtitle'"

        etitle=$(xml_get "$nfo" "/episodedetails/title")
        season=$(xml_get "$nfo" "/episodedetails/season")
        episode=$(xml_get "$nfo" "/episodedetails/episode")
        plot=$(xml_get "$nfo" "/episodedetails/plot")
        aired=$(xml_get "$nfo" "/episodedetails/aired")

        # Trim whitespace
        showtitle="$(printf '%s' "$showtitle" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        log_debug "Episode NFO showtitle (trimmed)='$showtitle'"

        # ------------------------------
        # If episode showtitle is empty → load from parent tvshow.nfo
        # ------------------------------
        if [[ -z "$showtitle" ]]; then
            parent_dir=$(dirname "$dir")
            parent_tvshow="$parent_dir/tvshow.nfo"

            if [[ -f "$parent_tvshow" ]]; then

                # Cache lookup
                if [[ -z "${TVSHOW_CACHE_ROOT[$parent_dir]+x}" ]]; then
                    log_debug "Caching tvshow.nfo for: $parent_dir"

                    root_val=$(xml_root "$parent_tvshow")
                    TVSHOW_CACHE_ROOT[$parent_dir]="$root_val"

                    if [[ "$root_val" == "tvshow" ]]; then
                        title_val=$(xml_get "$parent_tvshow" "/tvshow/title")
                        title_val="$(printf '%s' "$title_val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
                        TVSHOW_CACHE_TITLE[$parent_dir]="$title_val"
                        log_debug "Cached show title='$title_val'"
                    else
                        log_warn "Parent tvshow.nfo exists but is not <tvshow>; ignoring"
                        TVSHOW_CACHE_TITLE[$parent_dir]=""
                    fi
                fi

                showtitle="${TVSHOW_CACHE_TITLE[$parent_dir]}"
                log_debug "Parent tvshow.nfo showtitle='$showtitle'"
            else
                log_warn "No showtitle in episode NFO and no parent tvshow.nfo found"
            fi
        fi

        # Final fallback
        if [[ -z "$showtitle" ]]; then
            showtitle=$(basename "$dir")
        fi

        log_debug "Final resolved showtitle='$showtitle'"

        [[ -z "$etitle" ]] && etitle="Episode $episode"

        s_padded=$(printf '%02d' "$season")
        e_padded=$(printf '%02d' "$episode")

        new_title="$showtitle – S${s_padded}E${e_padded} – $etitle"

        TAGS[SHOW_TITLE]="$showtitle"
        TAGS[SEASON]="$season"
        TAGS[EPISODE]="$episode"
        TAGS[EPISODE_TITLE]="$etitle"
        TAGS[PLOT]="$plot"
        TAGS[AIRED]="$aired"
    fi

    # ------------------------------
    # Preserve timestamps
    # ------------------------------
    orig_mtime=$(stat -c %y "$mkv")

    # ------------------------------
    # Apply metadata
    # ------------------------------
    temp_tags=$(mktemp)
    build_tags_xml "$temp_tags"

    if [[ $DRYRUN -eq 0 ]]; then
        mkvpropedit "$mkv" --edit info --set "title=$new_title"
        mkvpropedit "$mkv" --tags all:"$temp_tags"
        touch -d "$orig_mtime" "$mkv"
        log_audit "Metadata applied ($TYPE)"
    else
        log_info "Dry-run: No changes applied ($TYPE)"
    fi

    rm -f "$temp_tags"

done < "$tmpfile"

rm -f "$tmpfile"

log_audit "=== Combined Movie/TV run complete ==="
log_info "Combined Movie/TV metadata run complete."
