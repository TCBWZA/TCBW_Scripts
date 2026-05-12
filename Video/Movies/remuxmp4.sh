#!/usr/bin/env bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

#####################################################
# DEBUG MODE
#####################################################

DEBUG=false
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=true ;;
    esac
done

debug() { $DEBUG && echo "[DEBUG] $*"; }

#####################################################
# RADARR CONFIG
#####################################################

RADARR_URL="http://docker:7878"
RADARR_API_KEY="YOUR_API_KEY_HERE"
RADARR_LOG="/tmp/remux_radarr.log"
MISSING_LOG="/tmp/remux_missing.log"

#####################################################
# RADARR: delete file, re-monitor, trigger search
#####################################################

radarr_replace_corrupt() {
    local filepath="$1"
    local filename
    filename=$(basename "$filepath")

    # Parse title and year from filename e.g. "Movie Title (2009) [...].mp4"
    local year title
    year=$(echo "$filename" | grep -oP '\(\K\d{4}(?=\))')
    title=$(echo "$filename" | sed -E 's/ \([0-9]{4}\).*//' | xargs)

    if [[ -z "$title" || -z "$year" ]]; then
        echo "Corrupt (no audio): $filepath -- could not parse title/year, skipping Radarr"
        printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "PARSE_FAIL: $filepath" >> "$RADARR_LOG"
        return
    fi

    echo "Corrupt (no audio): $filepath -- title='$title' year=$year"

    local search_term
    search_term=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$title $year" 2>/dev/null \
        || echo "$title $year" | sed 's/ /%20/g')

    local movie_json
    movie_json=$(curl -sf -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/movie/lookup?term=$search_term") || {
        echo "Radarr lookup failed for '$title ($year)'"
        printf '%s  LOOKUP_FAIL: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$filepath" >> "$RADARR_LOG"
        return
    }

    local movie_id
    movie_id=$(echo "$movie_json" | jq -r '.[0].id // empty')

    if [[ -z "$movie_id" ]]; then
        echo "Movie not found in Radarr: '$title ($year)'"
        printf '%s  %s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$title" "$filepath" >> "$MISSING_LOG"
        printf '%s  NOT_FOUND: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$filepath" >> "$RADARR_LOG"
        return
    fi

    debug "Radarr movie_id=$movie_id"

    local movie_file_id
    movie_file_id=$(echo "$movie_json" | jq -r '.[0].movieFile.id // empty')

    # Delete the corrupt file
    rm -f -- "$filepath"
    echo "Deleted corrupt file: $filepath"

    # Remove movie file record from Radarr
    if [[ -n "$movie_file_id" ]]; then
        local del_status
        del_status=$(curl -sf -o /dev/null -w '%{http_code}' -X DELETE \
            -H "X-Api-Key: $RADARR_API_KEY" \
            "$RADARR_URL/api/v3/moviefile/$movie_file_id")
        printf '%s  DELETE_FILE %s: HTTP %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$filepath" "$del_status" >> "$RADARR_LOG"
        debug "Radarr delete moviefile HTTP $del_status"
    fi

    # Re-monitor the movie
    local movie_full
    movie_full=$(curl -sf -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/movie/$movie_id")
    local monitored_json
    monitored_json=$(echo "$movie_full" | jq '.monitored = true')

    local put_status
    put_status=$(curl -sf -o /dev/null -w '%{http_code}' -X PUT \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$monitored_json" \
        "$RADARR_URL/api/v3/movie/$movie_id")
    printf '%s  MONITOR %s: HTTP %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$filepath" "$put_status" >> "$RADARR_LOG"
    debug "Radarr monitor HTTP $put_status"

    # Trigger MovieSearch
    local search_body
    search_body=$(jq -n --argjson id "$movie_id" '{name:"MoviesSearch",movieIds:[$id]}')
    local search_status
    search_status=$(curl -sf -o /dev/null -w '%{http_code}' -X POST \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$search_body" \
        "$RADARR_URL/api/v3/command")
    printf '%s  SEARCH %s: HTTP %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$filepath" "$search_status" >> "$RADARR_LOG"
    debug "Radarr search HTTP $search_status"

    echo "Radarr replacement requested for '$title ($year)'"
}

echo "Starting up..."
echo "Scanning for MP4 files..."

mapfile -t files < <(
    find . -type f -iname "*.mp4" ! -iname "*-trailer.mp4"
)

echo "Found ${#files[@]} files."
echo "Beginning processing..."

#####################################################
# MAIN LOOP
#####################################################

for f in "${files[@]}"; do
    debug "---------------------------------------------"
    debug "Processing file: $f"

    basename=$(basename "$f")
    base_no_ext="${basename%.*}"
    dir=$(dirname "$f")

    #####################################################
    # DIRECTORY .skip CHECK
    #####################################################

    file_abs="$(realpath -- "$f")"
    scan_dir="$(dirname -- "$file_abs")"
    project_root="$(realpath -- "$PWD")"
    skip_file=0

    while [[ "$scan_dir" == "$project_root"* ]]; do
        if [[ -f "$scan_dir/.skip" ]]; then
            debug "Found .skip at: $scan_dir"
            skip_file=1
            break
        fi
        new_scan_dir="$(dirname -- "$scan_dir")"
        [[ "$new_scan_dir" == "$scan_dir" ]] && break
        scan_dir="$new_scan_dir"
    done

    if (( skip_file )); then
        debug "Skipping due to .skip file"
        continue
    fi

    # Per-file .skip_<basename> check
    if [[ -f "$dir/.skip_${base_no_ext}" ]]; then
        echo "Skipping $f -- .skip_${base_no_ext} per-file marker found"
        continue
    fi

    #####################################################
    # Skip and delete leftover transcoded files
    #####################################################

    if [[ "$base_no_ext" =~ (\[Cleaned\]|\[Trans\]) ]]; then
        debug "Deleting leftover cleaned/transcoded file"
        rm -f -- "$f"
        continue
    fi

    #####################################################
    # Skip if MKV output already exists
    #####################################################

    output_mkv="$dir/${base_no_ext}.mkv"

    if [[ -f "$output_mkv" ]]; then
        echo "Skipping $f -- MKV already exists: $output_mkv"
        continue
    fi

    #####################################################
    # Size check (>500MB)
    #####################################################

    file_size=$(stat -c%s "$f")
    if (( file_size <= 524288000 )); then
        debug "Skipping $f -- smaller than 500MB ($(( file_size / 1024 / 1024 ))MB)"
        continue
    fi

    if (( file_size > 5368709120 )); then
        echo "Skipping $f -- larger than 5GB ($(( file_size / 1024 / 1024 / 1024 ))GB), transcode required"
        continue
    fi

    echo "Checking $f"

    #####################################################
    # ffprobe JSON
    #####################################################

    probe=$(ffprobe -v quiet -print_format json -show_streams "$f" 2>/dev/null)

    if ! jq -e . >/dev/null 2>&1 <<< "$probe"; then
        echo "Skipping $f -- ffprobe returned invalid JSON"
        continue
    fi

    #####################################################
    # Subtitle codec -- mov_text is MP4-only, not valid in MKV
    #####################################################

    mov_text_count=$(jq '[.streams[] | select(.codec_type=="subtitle" and .codec_name=="mov_text")] | length' <<< "$probe")

    if (( mov_text_count > 0 )); then
        subtitle_codec="srt"
        debug "mov_text subtitles detected -- will transcode to srt"
    else
        subtitle_codec="copy"
    fi

    debug "subtitle_codec=$subtitle_codec"

    #####################################################
    # Build stream maps via index (avoids m:language:? compat issues)
    #####################################################

    audio_maps=()
    while IFS= read -r idx; do
        audio_maps+=(-map "0:$idx")
    done < <(jq -r '.streams[] | select(.codec_type=="audio") | select((.tags.language // "und") | test("^(eng|und)$"; "i")) | .index' <<< "$probe")

    # Fall back to all audio if nothing matched but audio streams exist
    if [[ ${#audio_maps[@]} -eq 0 ]]; then
        audio_stream_count=$(jq '[.streams[] | select(.codec_type=="audio")] | length' <<< "$probe")
        if (( audio_stream_count > 0 )); then
            while IFS= read -r idx; do
                audio_maps+=(-map "0:$idx")
            done < <(jq -r '.streams[] | select(.codec_type=="audio") | .index' <<< "$probe")
            debug "No eng/und audio streams found -- mapping all $audio_stream_count audio stream(s)"
        else
            echo "Corrupt (no audio): $f"
            radarr_replace_corrupt "$f"
            continue
        fi
    fi

    sub_maps=()
    while IFS= read -r idx; do
        sub_maps+=(-map "0:$idx")
    done < <(jq -r '.streams[] | select(.codec_type=="subtitle") | select((.tags.language // "und") | test("^(eng|und)$"; "i")) | .index' <<< "$probe")

    debug "audio_maps: ${audio_maps[*]:-none}"
    debug "sub_maps: ${sub_maps[*]:-none}"

    #####################################################
    # Remux MP4 -> MKV
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"

    rm -f -- "$tmpfile"

    echo "Remuxing $f → MKV"
    debug "Temp file: $tmpfile"

    ffmpeg -nostdin -hide_banner -y \
        -i "$f" \
        -map 0:v \
        "${audio_maps[@]}" \
        "${sub_maps[@]}" \
        -map 0:t? \
        -c:v copy \
        -c:a copy \
        -c:s "$subtitle_codec" \
        -c:t copy \
        -f matroska \
        "$tmpfile"

    if [[ $? -eq 0 && -f "$tmpfile" ]]; then
        orig_size=$(stat -c%s "$f")
        new_size=$(stat -c%s "$tmpfile")

        # Remember original mtime before removing source
        orig_mtime=$(stat -c%y "$f")

        touch -r "$f" "$tmpfile"
        rm -f -- "$f"
        mv -- "$tmpfile" "$output_mkv"
        chown 1000:1000 "$output_mkv"
        chmod 666 "$output_mkv"

        echo "Done: $((orig_size/1024/1024))MB → $((new_size/1024/1024))MB"

        #####################################################
        # Apply movie metadata from NFO
        #####################################################

        script_dir="$(dirname -- "$(realpath -- "$0")")"
        metadata_script="$script_dir/apply-movie-metadata.sh"

        if [[ -x "$metadata_script" ]]; then
            echo "Applying metadata to $output_mkv"
            (cd "$dir" && bash "$metadata_script") && debug "Metadata applied OK" || echo "Warning: metadata apply failed for $output_mkv"
        else
            debug "apply-movie-metadata.sh not found or not executable at $metadata_script -- skipping"
        fi

        # Restore original mtime
        touch -d "$orig_mtime" "$output_mkv"
        debug "Restored mtime: $orig_mtime"
    else
        echo "Failed: $f"
        rm -f -- "$tmpfile"
    fi

done

#####################################################
# Cleanup leftover temp files
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . -type f -regex '.*\[Trans\]\.tmp$' -delete

echo "All tasks complete."
