#!/usr/bin/env bash

set +e +u +o pipefail
set -u -o pipefail

# ============================================================
#  Foreign-Only Audio Scanner (Bash Version)
#
#  Behaviour:
#      - Sonarr enabled by default
#      - --no-sonarr disables Sonarr
#      - CSV logging only when --csv is provided
#      - --append requires --csv
#      - Full audit-safe parameter validation
#      - .skip file support to ignore entire shows
#      - Colourised terminal output
#
#  Requirements (Debian/Ubuntu/WSL):
#      sudo apt update
#      sudo apt install ffmpeg jq curl -y
#
# ============================================================

# -------- Dependency Check --------
missing=0

check_dep() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing dependency: $1"
        missing=1
    fi
}

check_dep ffprobe
check_dep jq
check_dep curl

if [[ $missing -eq 1 ]]; then
    echo
    echo "Install missing dependencies with:"
    echo "  sudo apt update && sudo apt install ffmpeg jq curl -y"
    echo
    exit 1
fi

# -------- Colour Definitions --------
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"

print_info()  { echo -e "${CYAN}$1${RESET}"; }
print_warn()  { echo -e "${YELLOW}$1${RESET}"; }
print_error() { echo -e "${RED}$1${RESET}"; }
print_ok()    { echo -e "${GREEN}$1${RESET}"; }

# -------- Defaults --------
ROOT="."
CSV_FILE=""
APPEND=0
ENABLE_SONARR=1        # Sonarr enabled by default
DEBUG=false
SONARR_URL="http://docker:8989"
SONARR_API_KEY="YOUR_API_KEY_HERE"
SONARR_LOG=""
ALLOWED_LANGS=("eng" "und")

# -------- Utility --------
debug() { $DEBUG && echo "[DEBUG] $*" >&2; }

# -------- Argument Parsing --------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--root)
            ROOT="$2"
            shift 2
            ;;
        -c|--csv)
            CSV_FILE="$2"
            shift 2
            ;;
        -a|--append)
            APPEND=1
            shift
            ;;
        --no-sonarr)
            ENABLE_SONARR=0
            shift
            ;;
        -s|--sonarr)
            ENABLE_SONARR=1
            shift
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        *)
            print_error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# -------- Audit-Safe Parameter Validation --------

# Validate: Root must exist and be a directory
if [[ ! -d "$ROOT" ]]; then
    print_error "ERROR: Root path does not exist or is not a directory: $ROOT"
    exit 1
fi

# Validate: Append requires CSV
if [[ $APPEND -eq 1 && -z "$CSV_FILE" ]]; then
    print_error "ERROR: --append requires --csv <file>"
    exit 1
fi

# Validate: CSV parent directory must exist
if [[ -n "$CSV_FILE" ]]; then
    CSV_DIR=$(dirname "$CSV_FILE")
    if [[ ! -d "$CSV_DIR" ]]; then
        print_error "ERROR: CSV directory does not exist: $CSV_DIR"
        exit 1
    fi
fi

# Validate: Sonarr log directory must exist (if enabled)
if [[ $ENABLE_SONARR -eq 1 ]]; then
    SONARR_LOG="sonarr_log.csv"
    SONARR_LOG_DIR=$(dirname "$SONARR_LOG")

    if [[ ! -d "$SONARR_LOG_DIR" ]]; then
        print_error "ERROR: Sonarr log directory does not exist: $SONARR_LOG_DIR"
        exit 1
    fi

    if [[ -z "$SONARR_API_KEY" ]]; then
        print_error "ERROR: Sonarr enabled but API key missing"
        exit 1
    fi
fi

# -------- CSV init (only if user asked) --------
if [[ -n "$CSV_FILE" ]]; then
    if [[ $APPEND -eq 0 ]]; then
        echo "FilePath,Languages" > "$CSV_FILE"
    fi
fi

# -------- Sonarr log init (only if enabled) --------
if [[ $ENABLE_SONARR -eq 1 ]]; then
    echo "DateTime,FilePath,Status" > "$SONARR_LOG"
fi

# -------- Extract audio languages --------
get_audio_languages() {
    local file="$1"
    local langs

    langs=$(ffprobe -v error \
        -select_streams a \
        -show_entries stream_tags=language \
        -of default=noprint_wrappers=1:nokey=1 \
        "$file" 2>/dev/null)

    [[ -z "$langs" ]] && { echo "und"; return; }

    echo "$langs" | tr '[:upper:]' '[:lower:]'
}

# -------- Sonarr logging --------
log_sonarr() {
    local file="$1" status="$2"
    [[ $ENABLE_SONARR -ne 1 ]] && return
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$ts,\"$file\",$status" >> "$SONARR_LOG"
}

# -------- Sonarr resolution --------
# Fetches the whole series list once per run and caches it. Returns non-zero if the
# list cannot be read, so a fetch failure refuses the delete.
SONARR_SERIES_JSON=""
SONARR_SERIES_LOADED=0
sonarr_series_list() {
    if [[ "$SONARR_SERIES_LOADED" -eq 1 ]]; then
        [[ -n "$SONARR_SERIES_JSON" ]]
        return
    fi
    SONARR_SERIES_LOADED=1
    SONARR_SERIES_JSON=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/series") || SONARR_SERIES_JSON=""
    # An empty or non-array body is a failed fetch, not an empty library.
    if ! echo "$SONARR_SERIES_JSON" | jq -e 'type == "array" and length > 0' \
        > /dev/null 2>&1; then
        SONARR_SERIES_JSON=""
        return 1
    fi
    return 0
}

# Resolves the series and episode, publishing RESOLVED_SERIES_ID / RESOLVED_EPISODE_ID.
# Runs BEFORE the file is removed, so a failed lookup cannot leave an episode deleted
# with nothing queued to replace it.
REASON=""
RESOLVED_SERIES_ID=""
RESOLVED_EPISODE_ID=""

sonarr_resolve() {
    local file="$1"
    REASON="unknown"
    RESOLVED_SERIES_ID=""
    RESOLVED_EPISODE_ID=""

    local series_name season episode
    series_name=$(basename "$(dirname "$(dirname "$file")")")

    if [[ "$file" =~ S([0-9]{2})E([0-9]{2}) ]]; then
        season="${BASH_REMATCH[1]}"
        episode="${BASH_REMATCH[2]}"
    else
        REASON="ERROR: Could not parse SxxEyy"
        return 1
    fi

    local series_json matches match
    sonarr_series_list || { REASON="ERROR: could not read the series list"; return 1; }
    series_json="$SONARR_SERIES_JSON"

    # Matched locally, not searched: /series?term= returns the whole library for
    # every term, so taking [0] deleted the wrong episode in testing.
    matches=$(echo "$series_json" | jq -c --arg want "$series_name" '
        [ .[]
          | select(
              (.title | ascii_downcase) == ($want | ascii_downcase)
              or ((.path | split("/"))[-1] | ascii_downcase) == ($want | ascii_downcase)
            )
        ]')
    match=$(echo "$matches" | jq -r 'if length == 0 then empty
                                     elif length == 1 then (.[0].id | tostring)
                                     else "AMBIGUOUS" end')

    if [[ "$match" == "AMBIGUOUS" ]]; then
        print_error "Sonarr: '$series_name' matches several series -- not guessing:"
        # Only the candidates, not the whole library.
        echo "$matches" | jq -r '.[].title' | sed 's/^/Sonarr:     /'
        REASON="ERROR: ambiguous series match"
        return 1
    fi

    if [[ -z "$match" ]]; then
        REASON="404 (series not found)"
        return 1
    fi

    RESOLVED_SERIES_ID="$match"

    local episodes_json episode_id
    episodes_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episode?seriesId=$RESOLVED_SERIES_ID")
    episode_id=$(echo "$episodes_json" | jq \
        --argjson s "$season" --argjson e "$episode" \
        -r '[ .[] | select(.seasonNumber==$s and .episodeNumber==$e) ]
           | if length == 1 then (.[0].id | tostring) else empty end')

    if [[ -z "$episode_id" ]]; then
        REASON="404 (episode not found)"
        return 1
    fi

    RESOLVED_EPISODE_ID="$episode_id"
    return 0
}

# -------- Sonarr replacement --------
# Refresh marks it missing, monitoring re-enables it as wanted, the search re-grabs it.
sonarr_request() {
    local file="$1"
    local series_id="$RESOLVED_SERIES_ID" episode_id="$RESOLVED_EPISODE_ID"

    # File was already removed from the filesystem by the caller.
    # Refresh so Sonarr rescans and marks the episode missing (wanted),
    # re-enable monitoring, then trigger a grab/search.
    local refresh_body refresh_status
    refresh_body="{\"name\":\"RefreshSeries\",\"seriesId\":$series_id}"
    refresh_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$refresh_body" \
        "$SONARR_URL/api/v3/command")
    print_ok "Sonarr: Refreshed series for $file (HTTP $refresh_status)"
    log_sonarr "$file" "$refresh_status"

    local monitor_body monitor_status
    monitor_body="{\"episodeIds\":[$episode_id],\"monitored\":true}"
    monitor_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$monitor_body" \
        "$SONARR_URL/api/v3/episode/monitor")
    print_ok "Sonarr: Enabled wanted on episode for $file (HTTP $monitor_status)"
    log_sonarr "$file" "$monitor_status"

    local search_body search_status
    search_body="{\"name\":\"EpisodeSearch\",\"episodeIds\":[$episode_id]}"
    search_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$search_body" \
        "$SONARR_URL/api/v3/command")
    print_ok "Sonarr: Triggered search for $file (HTTP $search_status)"
    log_sonarr "$file" "$search_status"
}

# -------- Main scan with .skip support --------
print_info "Scanning for MKVs with foreign-only audio..."

# Process substitution, not a pipe: a piped while discards the state it sets.
# Trailers are excluded, so one is never judged as a foreign episode.
while read -r file; do

    langs=$(get_audio_languages "$file")

    has_allowed=0
    for lang in $langs; do
        for allowed in "${ALLOWED_LANGS[@]}"; do
            [[ "$lang" == "$allowed" ]] && has_allowed=1
        done
    done

    if [[ "$has_allowed" -eq 0 ]]; then
        print_warn "Foreign-only: $file"

        # Confirm the replacement BEFORE removing anything.
        if [[ $ENABLE_SONARR -eq 1 ]] && ! sonarr_resolve "$file"; then
            print_error "Sonarr: $REASON -- leaving file in place: $file"
            log_sonarr "$file" "$REASON (file kept)"
            continue
        fi

        if [[ -n "$CSV_FILE" ]]; then
            lang_string=$(echo "$langs" | paste -sd ";" -)
            echo "\"$file\",\"$lang_string\"" >> "$CSV_FILE"
        fi

        rm -f "$file"
        print_ok "Deleted: $file"

        [[ $ENABLE_SONARR -eq 1 ]] && sonarr_request "$file"
    fi
done < <(find "$ROOT" \
    -type d -exec test -e "{}/.skip" \; -prune -o \
    -type f -name "*.mkv" ! -iname "*-trailer.*" -print)

