#!/bin/bash

###############################################################
# PRE-FLIGHT CHECKS
###############################################################
for tool in ffprobe ffmpeg; do
    if ! command -v "$tool" &> /dev/null; then
        echo "ERROR: $tool not found in PATH"
        echo "Please install or add to PATH before running this script."
        exit 1
    fi
done

###############################################################
# CLEANUP TRAP FOR INTERRUPTION
###############################################################
temp_files=()
cleanup() {
    if [[ ${#temp_files[@]} -gt 0 ]]; then
        debug "\nCleaning up temp files due to interruption..."
        for file in "${temp_files[@]}"; do
            rm -f "$file" 2>/dev/null
        done
    fi
}
trap 'echo "Interrupted -- exiting safely"; cleanup; exit 1' INT TERM EXIT

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
# CONTAINER HEALTH CHECK
#####################################################

check_container_problem() {
    local path="$1"
    local probe_json
    probe_json=$(ffprobe -v quiet -print_format json -show_format -show_streams "$path" 2>/dev/null)

    if ! jq -e . >/dev/null 2>&1 <<< "$probe_json"; then
        debug "Container check: ffprobe failed for $path -- treating as problematic"
        return 0
    fi

    local start_time
    start_time=$(jq -r '.format.start_time // "N/A"' <<< "$probe_json")
    if [[ "$start_time" == "N/A" ]]; then
        debug "Container issue: start_time is N/A"
        return 0
    fi

    local duration
    duration=$(jq -r '.format.duration // "N/A"' <<< "$probe_json")
    if [[ "$duration" == "N/A" ]]; then
        debug "Container issue: duration is N/A"
        return 0
    fi
    if [[ "$duration" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && (( $(echo "$duration <= 0" | bc -l) )); then
        debug "Container issue: duration is non-positive ($duration)"
        return 0
    fi

    # Deeper check: demux pass catches non-monotonic timestamps, truncation, missing moov
    local ffmpeg_errors
    ffmpeg_errors=$(ffmpeg -nostdin -hide_banner -v error -i "$path" -f null - 2>&1)
    if [[ -n "$ffmpeg_errors" ]]; then
        debug "Container issue: ffmpeg demux errors detected"
        return 0
    fi

    return 1
}

MAX_JOBS=2

echo "Starting up..."
echo "Scanning for files..."

# Find all video files >= 1GB
mapfile -t files < <(
    find . -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.ts" \) -size +950M
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
        [[ "$new_scan_dir" == "$scan_dir" ]] && break   # safety: stop if dirname stalls
        scan_dir="$new_scan_dir"
    done

    if (( skip_file )); then
        debug "Skipping due to .skip file"
        continue
    fi

    #####################################################
    # PER-FILE .skip_<basename> CHECK
    #####################################################

    file_skip_file="$dir/.skip_${base_no_ext}"

    if [[ -f "$file_skip_file" ]]; then
        echo "Skipping $f -- file marked with $(basename "$file_skip_file")"
        continue
    fi

    #####################################################
    # Skip and delete cleaned/transcoded files
    #####################################################

    if [[ "$base_no_ext" =~ (\[Cleaned\]|\[Trans\]) ]]; then
        debug "Deleting leftover cleaned/transcoded file"
        rm -f -- "$f"
        continue
    fi

    echo "Checking $f"

    #####################################################
    # ffprobe JSON (single call)
    #####################################################

    debug "Running ffprobe JSON"

    probe=$(ffprobe -v quiet -print_format json -show_streams "$f")
    if ! jq -e . >/dev/null 2>&1 <<< "$probe"; then
        echo "Skipping $f -- ffprobe returned invalid JSON"
        continue
    fi

    debug "ffprobe JSON OK"

    #####################################################
    # Extract video/audio metadata
    #####################################################

    { IFS=$'\t' read -r vcodec vbitrate field_order; read -r acodec; } < <(
        jq -r '
          (.streams[] | select(.codec_type=="video") |
            [.codec_name, (.bit_rate // .tags.BPS // 0), (.field_order // "unknown")] | @tsv),
          (.streams[] | select(.codec_type=="audio") |
            .codec_name)
        ' <<< "$probe"
    )

    vcodec_lc=$(echo "$vcodec" | tr '[:upper:]' '[:lower:]')

    debug "vcodec=$vcodec_lc vbitrate=$vbitrate field_order=$field_order acodec=$acodec"

    #####################################################
    # HARD SKIP AV1 (matches PowerShell)
    #####################################################

    if [[ "$vcodec_lc" =~ ^(av1|av01|libaom-av1|unknown)$ ]]; then
        echo "Skipping $f -- AV1 or unsupported codec detected ($vcodec_lc)"
        continue
    fi

    # SKIP: high resolution (> 1100p) -- ffprobe secondary check
    height=$(jq -r '.streams[] | select(.codec_type=="video") | .height' <<< "$probe")
    if (( height > 1100 )); then
        echo "Skipping $f -- high-resolution video detected (height=$height)"
        continue
    fi

    # mov_text → SRT: MP4 text subtitles cannot be stream-copied into MKV
    sub_codec_args=(-c:s copy)
    if [[ "$f" == *.mp4 ]]; then
        if jq -e '[.streams[] | select(.codec_type=="subtitle" and .codec_name=="mov_text")] | length > 0' <<< "$probe" >/dev/null 2>&1; then
            debug "Subtitle: mov_text detected in MP4 -- converting to SRT for MKV output"
            sub_codec_args=(-c:s srt)
        fi
    fi

    #####################################################
    # Interlace / telecine detection (PowerShell parity)
    #####################################################

    status="progressive"

    if [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    elif [[ "$field_order" != "progressive" ]]; then
        echo "Running deep interlace scan..."

        interlaced_count=$(ffmpeg -nostdin -hide_banner \
            -ss 300 \
            -skip_frame nokey \
            -filter:v idet \
            -frames:v 200 \
            -an -f null - "$f" 2>&1 \
            | grep -oP 'Interlaced:\s*\K[0-9]+' | head -n1)

        [[ -z "$interlaced_count" ]] && interlaced_count=0

        if (( interlaced_count > 0 )); then
            status="interlaced"
        else
            status="progressive"
        fi
    fi

    echo "Detected: $status"

    #####################################################
    # Needs convert?
    #####################################################

    needs_convert=false
    [[ "$vcodec_lc" != "hevc" ]] && needs_convert=true
    (( vbitrate > 2500000 )) && needs_convert=true
    [[ "$status" != "progressive" ]] && needs_convert=true

    if ! $needs_convert; then
        #####################################################
        # No transcode needed -- check for container problems
        #####################################################
        if [[ "$acodec" == "aac" ]] && check_container_problem "$f"; then
            echo "Remuxing $f → container repair"
            tmpfile="$dir/${base_no_ext}[Trans].tmp"

            rm -f -- "$tmpfile"

            ffmpeg -nostdin -hide_banner -y \
                -i "$f" \
                -map 0 \
                -c:v copy -c:a copy \
                "${sub_codec_args[@]}" \
                -f matroska \
                "$tmpfile"

            if [[ $? -eq 0 ]]; then
                orig_size=$(stat -c%s "$f")
                new_size=$(stat -c%s "$tmpfile")
                touch -r "$f" "$tmpfile"
                rm -f -- "$f"
                mv -- "$tmpfile" "$f"
                chown 1000:1000 "$f"
                chmod 666 "$f"
                echo "Replaced (remux): $((orig_size/1024/1024))MB → $((new_size/1024/1024))MB"
            else
                rm -f -- "$tmpfile"
            fi
        else
            echo "Skipping $f -- already in desired format"
        fi

        continue
    fi

    #####################################################
    # Filter chain (PowerShell parity)
    #####################################################

    case "$status" in
        interlaced)
            vf_chain="bwdif=mode=send_frame,format=nv12,hwupload"
            ;;
        progressive)
            vf_chain="format=nv12,hwupload"
            ;;
    esac

    #####################################################
    # Transcode
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"
    temp_files+=("$tmpfile")

    rm -f -- "$tmpfile"

    (
        ffmpeg -nostdin -hide_banner \
            -vaapi_device /dev/dri/renderD128 \
            -i "$f" \
            -vf "$vf_chain" \
            -map 0 \
            -c:v hevc_vaapi \
            -qp 22 \
            -c:a copy \
            "${sub_codec_args[@]}" \
            -f matroska \
            "$tmpfile"

        if [[ $? -eq 0 ]]; then
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")

            if (( new_size < orig_size )); then
                touch -r "$f" "$tmpfile"
                rm -f -- "$f"
                mv -- "$tmpfile" "$f"
                chown 1000:1000 "$f"
                chmod 666 "$f"
                echo "Replaced: $((orig_size/1024/1024))MB → $((new_size/1024/1024))MB"
            else
                echo "Skipped: new file not smaller"
                touch "$file_skip_file"
                rm -f -- "$tmpfile"
            fi
        else
            rm -f -- "$tmpfile"
        fi
    ) &

    while (( $(jobs -r | wc -l) >= MAX_JOBS )); do
        wait -n
    done

done

wait

#####################################################
# Cleanup (PowerShell‑parity: only remove true leftovers)
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . -type f -regex '.*\[Trans\]\.tmp$' -delete
find . -type f -regex '.*\[Trans\]\.nfo$' -delete
find . -type f -regex '.*\[Trans\]\.jpg$' -delete
find . -type d -regex '.*\[Trans\]\.trickplay$' -exec rm -rf {} +

echo "All tasks complete."

