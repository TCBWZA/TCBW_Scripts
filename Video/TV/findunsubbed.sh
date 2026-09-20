#!/usr/bin/env bash

# ============================================================
#  Japanese-Only, Unsubbed Anime Scanner
#
#  Flags MKV files whose audio is entirely Japanese and that
#  have no eng/und/unk subtitle stream (unsubbed raws), deletes
#  them, and triggers a Sonarr episode replacement so a
#  subtitled copy is grabbed.
#
#  Behaviour:
#      - Sonarr enabled by default
#      - --no-sonarr disables Sonarr (file still removed)
#      - --audit prints what would happen, changes nothing
#      - CSV logging only when --csv is provided
#      - --append requires --csv
#      - .skip dir and .skip_<basename> markers are honoured
#
#  Requirements (Debian/Ubuntu):
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
AUDIT=0
ENABLE_SONARR=1
DEBUG=false
SONARR_URL="http://docker:8989"
SONARR_API_KEY="YOUR_API_KEY_HERE"
SONARR_LOG=""

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
        --audit)
            AUDIT=1
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

# -------- Parameter Validation --------

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

    if [[ -z "$SONARR_API_KEY" || "$SONARR_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
        print_error "ERROR: Sonarr enabled but API key missing"
        print_error "Create $HOME/.config/tcbw/sonarr.conf or set TCBW_SONARR_API_KEY."
        exit 1
    fi
fi

# -------- CSV init (only if user asked) --------
if [[ -n "$CSV_FILE" ]]; then
    if [[ $APPEND -eq 0 ]]; then
        echo "FilePath" > "$CSV_FILE"
    fi
fi

# -------- Sonarr log init (only if enabled) --------
if [[ $ENABLE_SONARR -eq 1 ]]; then
    echo "DateTime,FilePath,Status" > "$SONARR_LOG"
fi

# -------- Sonarr connectivity check --------
if [[ $ENABLE_SONARR -eq 1 ]]; then
    print_info "Checking Sonarr connectivity..."
    if curl -sf -o /dev/null -m 5 -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/system/status"; then
        print_ok "Sonarr is reachable."
    else
        print_error "ERROR: Unable to reach Sonarr at $SONARR_URL"
        print_error "Use --no-sonarr to skip Sonarr integration."
        exit 3
    fi
fi

# -------- Detection: all audio Japanese AND no eng/und/unk subs --------
# Subtitle check: a file counts as subbed only when at least one subtitle
# stream is eng/und/unk; jpn-only (signs) or other-language subs do not
# count, so those are still flagged. Conservative audio rule: untagged/und
# audio is not treated as Japanese, so such files are left for manual
# review. Unreadable files are left for findcorrupt.
is_japanese_no_subs() {
    local file="$1" json audio_n eng_subs non_jp

    json=$(ffprobe -v error -print_format json -show_streams "$file" 2>/dev/null)
    [[ -z "$json" ]] && return 1

    audio_n=$(echo "$json" | jq -r '[.streams[] | select(.codec_type=="audio")] | length')
    [[ "$audio_n" -eq 0 ]] && return 1

    eng_subs=$(echo "$json" | jq -r '[.streams[] | select(.codec_type=="subtitle") |
        ((.tags.language // "") | ascii_downcase) |
        select(. == "eng" or . == "und" or . == "unk")] | length')
    [[ "$eng_subs" -gt 0 ]] && return 1

    non_jp=$(echo "$json" | jq -r '[.streams[] | select(.codec_type=="audio") |
        ((.tags.language // "") | ascii_downcase) |
        select(. != "jpn" and . != "ja" and . != "jp")] | length')
    [[ "$non_jp" -eq 0 ]]
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
    series_json=$(curl -s -G -H "X-Api-Key: $SONARR_API_KEY" \
        --data-urlencode "term=$series_name" \
        "$SONARR_URL/api/v3/series")
    series_id=$(echo "$series_json" | jq '.[0].id // empty')

    [[ -z "$series_id" ]] && {
        print_error "Sonarr: Series not found for $file"
        log_sonarr "$file" "404 (series not found)"
        return
    }

    local episodes_json episode_json episode_id
    episodes_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episode?seriesId=$series_id")
    episode_json=$(echo "$episodes_json" | jq \
        ".[] | select(.seasonNumber==$season and .episodeNumber==$episode)")
    episode_id=$(echo "$episode_json" | jq '.id // empty')

    [[ -z "$episode_id" ]] && {
        print_error "Sonarr: Episode not found for $file"
        log_sonarr "$file" "404 (episode not found)"
        return
    }

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
print_info "Scanning for Japanese-only, unsubbed MKVs..."

find "$ROOT" \
    -type d -exec test -e "{}/.skip" \; -prune -o \
    -type f -name "*.mkv" -print | while read -r file; do

    dir=$(dirname "$file")
    base=$(basename "$file")

    if [[ -f "$dir/.skip_${base%.*}" ]]; then
        print_info "Skipping $file -- .skip_${base%.*} marker found"
        continue
    fi

    if is_japanese_no_subs "$file"; then
        print_warn "Japanese-only, no subs: $file"

        if [[ $AUDIT -eq 1 ]]; then
            print_info "[AUDIT] Would delete: $file"
            [[ $ENABLE_SONARR -eq 1 ]] && print_info "[AUDIT] Would request Sonarr replacement for: $file"
            continue
        fi

        if [[ -n "$CSV_FILE" ]]; then
            echo "\"$file\"" >> "$CSV_FILE"
        fi

        rm -f "$file"
        print_ok "Deleted: $file"

        sonarr_replace "$file"
    fi
done