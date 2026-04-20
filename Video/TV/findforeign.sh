#!/usr/bin/env bash

# ============================================================
#  Foreign-Only Audio Scanner (Bash Version)
#
#  Behaviour:
#      • Sonarr enabled by default
#      • --no-sonarr disables Sonarr
#      • CSV logging only when --csv is provided
#      • --append requires --csv
#      • Full audit-safe parameter validation
#      • .skip file support to ignore entire shows
#      • Colourised terminal output
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

# -------- Sonarr replacement --------
sonarr_replace() {
    [[ $ENABLE_SONARR -ne 1 ]] && return
    local file="$1"

    local series_name season episode
    series_name=$(basename "$(dirname "$(dirname "$file")")")

    if [[ "$file" =~ S([0-9]{2})E([0-9]{2}) ]]; then
        season="${BASH_REMATCH[1]}"
        episode="${BASH_REMATCH[2]}"
    else
        print_error "Sonarr: Could not parse SxxEyy for $file"
        log_sonarr "$file" "ERROR: Could not parse SxxEyy"
        return
    fi

    local series_json series_id
    series_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/series?term=$series_name")
    series_id=$(echo "$series_json" | jq '.[0].id // empty')

    [[ -z "$series_id" ]] && {
        print_error "Sonarr: Series not found for $file"
        log_sonarr "$file" "404 (series not found)"
        return
    }

    local episodes_json episode_json episode_id episode_file_id
    episodes_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episode?seriesId=$series_id")
    episode_json=$(echo "$episodes_json" | jq \
        ".[] | select(.seasonNumber==$season and .episodeNumber==$episode)")
    episode_id=$(echo "$episode_json" | jq '.id // empty')
    episode_file_id=$(echo "$episode_json" | jq '.episodeFileId // empty')

    [[ -z "$episode_id" ]] && {
        print_error "Sonarr: Episode not found for $file"
        log_sonarr "$file" "404 (episode not found)"
        return
    }

    [[ -z "$episode_file_id" ]] && {
        print_error "Sonarr: EpisodeFileId missing for $file"
        log_sonarr "$file" "404 (episodeFileId missing)"
        return
    }

    local delete_status
    delete_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episodefile/$episode_file_id")
    print_ok "Sonarr: Deleted episode file for $file (HTTP $delete_status)"
    log_sonarr "$file" "$delete_status"

    local updated_json monitor_status
    updated_json=$(echo "$episode_json" | jq '.monitored=true')
    monitor_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$updated_json" \
        "$SONARR_URL/api/v3/episode/$episode_id")
    print_ok "Sonarr: Re-monitored episode for $file (HTTP $monitor_status)"
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

find "$ROOT" \
    -type d -exec test -e "{}/.skip" \; -prune -o \
    -type f -name "*.mkv" -print | while read -r file; do

    langs=$(get_audio_languages "$file")

    has_allowed=0
    for lang in $langs; do
        for allowed in "${ALLOWED_LANGS[@]}"; do
            [[ "$lang" == "$allowed" ]] && has_allowed=1
        done
    done

    if [[ "$has_allowed" -eq 0 ]]; then
        print_warn "Foreign-only: $file"

        if [[ -n "$CSV_FILE" ]]; then
            lang_string=$(echo "$langs" | paste -sd ";" -)
            echo "\"$file\",\"$lang_string\"" >> "$CSV_FILE"
        fi

        sonarr_replace "$file"
    fi
done

