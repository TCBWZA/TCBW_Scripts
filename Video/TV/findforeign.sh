#!/usr/bin/env bash

# ============================================================
#  Foreign-Only Audio Scanner (Bash Version)
#
#  Requirements (Debian/Ubuntu/WSL):
#
#      sudo apt update
#      sudo apt install ffmpeg jq curl -y
#
#  Dependencies checked automatically at runtime:
#      • ffprobe  – required for audio language detection
#      • jq       – required for Sonarr JSON parsing
#      • curl     – required for Sonarr API calls
#
#  Usage Examples:
#
#  1) Scan current directory, NO logging (default)
#       ./find_foreign.sh
#
#  2) Scan a specific root directory, NO logging
#       ./find_foreign.sh --root /mnt/media/TV
#
#  3) Enable CSV logging (CSV file created only when specified)
#       ./find_foreign.sh --csv foreign.csv
#
#  4) Enable Sonarr replacement + Sonarr log
#       ./find_foreign.sh --sonarr
#
#  5) CSV logging + Sonarr replacement
#       ./find_foreign.sh --csv foreign.csv --sonarr
#
#  6) Full explicit example
#       ./find_foreign.sh --root /mnt/media/TV \
#                          --csv /tmp/foreign.csv \
#                          --sonarr
#
#  .skip Behaviour:
#
#    • If a ShowName directory contains a file named `.skip`,
#      the scanner will completely ignore that show.
#
#    • Example:
#          /series/Breaking Bad/.skip
#          /series/Breaking Bad/Season01/E01.mkv
#
#      Result:
#          The entire "Breaking Bad" directory is skipped.
#          No MKVs inside it are scanned.
#          No CSV entries are created.
#          No Sonarr actions are triggered.
#
#    • The `.skip` file must be placed directly inside the show directory:
#          /series/ShowName/.skip
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

# -------- Defaults --------
ROOT="."
CSV_FILE=""
ENABLE_SONARR=0
SONARR_URL="http://docker:8989"
SONARR_API_KEY="YOUR_API_KEY_HERE"
SONARR_LOG=""
ALLOWED_LANGS=("eng" "und")

# -------- Argument Parsing --------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--root)   ROOT="$2"; shift 2 ;;
        -c|--csv)    CSV_FILE="$2"; shift 2 ;;
        -s|--sonarr) ENABLE_SONARR=1; SONARR_LOG="sonarr_log.csv"; shift ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# -------- CSV init (only if user asked) --------
if [[ -n "$CSV_FILE" ]]; then
    echo "FilePath,Languages" > "$CSV_FILE"
fi

# -------- Sonarr log init (only if enabled) --------
if [[ "$ENABLE_SONARR" -eq 1 && -n "$SONARR_LOG" ]]; then
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

# -------- Sonarr logging (only if enabled) --------
log_sonarr() {
    local file="$1" status="$2"
    [[ "$ENABLE_SONARR" -ne 1 ]] && return
    [[ -z "$SONARR_LOG" ]] && return
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "$ts,\"$file\",$status" >> "$SONARR_LOG"
}

# -------- Sonarr replacement --------
sonarr_replace() {
    [[ "$ENABLE_SONARR" -ne 1 ]] && return
    local file="$1"

    local series_name season episode
    series_name=$(basename "$(dirname "$(dirname "$file")")")

    if [[ "$file" =~ S([0-9]{2})E([0-9]{2}) ]]; then
        season="${BASH_REMATCH[1]}"
        episode="${BASH_REMATCH[2]}"
    else
        log_sonarr "$file" "ERROR: Could not parse SxxEyy"
        return
    fi

    local series_json series_id
    series_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/series?term=$series_name")
    series_id=$(echo "$series_json" | jq '.[0].id // empty')

    [[ -z "$series_id" ]] && { log_sonarr "$file" "404 (series not found)"; return; }

    local episodes_json episode_json episode_id episode_file_id
    episodes_json=$(curl -s -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episode?seriesId=$series_id")
    episode_json=$(echo "$episodes_json" | jq \
        ".[] | select(.seasonNumber==$season and .episodeNumber==$episode)")
    episode_id=$(echo "$episode_json" | jq '.id // empty')
    episode_file_id=$(echo "$episode_json" | jq '.episodeFileId // empty')

    [[ -z "$episode_id" ]] && { log_sonarr "$file" "404 (episode not found)"; return; }
    [[ -z "$episode_file_id" ]] && { log_sonarr "$file" "404 (episodeFileId missing)"; return; }

    local delete_status
    delete_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE -H "X-Api-Key: $SONARR_API_KEY" \
        "$SONARR_URL/api/v3/episodefile/$episode_file_id")
    log_sonarr "$file" "$delete_status"

    local updated_json monitor_status
    updated_json=$(echo "$episode_json" | jq '.monitored=true')
    monitor_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$updated_json" \
        "$SONARR_URL/api/v3/episode/$episode_id")
    log_sonarr "$file" "$monitor_status"

    local search_body search_status
    search_body="{\"name\":\"EpisodeSearch\",\"episodeIds\":[$episode_id]}"
    search_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST -H "X-Api-Key: $SONARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$search_body" \
        "$SONARR_URL/api/v3/command")
    log_sonarr "$file" "$search_status"
}

# -------- Main scan with .skip support --------
echo "Scanning for MKVs with foreign-only audio..."

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
        echo "Foreign-only: $file"

        if [[ -n "$CSV_FILE" ]]; then
            lang_string=$(echo "$langs" | paste -sd ";" -)
            echo "\"$file\",\"$lang_string\"" >> "$CSV_FILE"
        fi

        sonarr_replace "$file"
    fi
done
