#!/bin/bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

#####################################################
# CONTAINER HEALTH CHECK
#####################################################

check_container_problem() {
    local path="$1"
    local probe_json
    probe_json=$(ffprobe -v quiet -print_format json -show_format -show_streams "$path" 2>/dev/null)

    if ! jq -e . >/dev/null 2>&1 <<< "$probe_json"; then
        return 0
    fi

    local start_time
    start_time=$(jq -r '.format.start_time // "N/A"' <<< "$probe_json")
    [[ "$start_time" == "N/A" ]] && return 0

    local duration
    duration=$(jq -r '.format.duration // "N/A"' <<< "$probe_json")
    [[ "$duration" == "N/A" ]] && return 0
    if [[ "$duration" =~ ^-?[0-9]+([.][0-9]+)?$ ]] && (( $(echo "$duration <= 0" | bc -l) )); then
        return 0
    fi

    # Deeper check: demux pass catches non-monotonic timestamps, truncation, missing moov
    local ffmpeg_errors
    ffmpeg_errors=$(ffmpeg -nostdin -hide_banner -v error -i "$path" -f null - 2>&1)
    [[ -n "$ffmpeg_errors" ]] && return 0

    return 1
}

MAX_JOBS=2

echo "Starting up..."
echo "Scanning for files..."

# Find all video files
mapfile -t files < <(find . -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.ts" \))

echo "Found ${#files[@]} files."
echo "Beginning processing..."

for f in "${files[@]}"; do
    size_bytes=$(stat -c%s "$f")
    size_gb=$((size_bytes / 1024 / 1024 / 1024))

    # Skip files smaller than 5GB
    (( size_gb < 5 )) && continue

    basename=$(basename "$f")
    base_no_ext="${basename%.*}"
    dir=$(dirname "$f")

    # Skip and delete cleaned/transcoded files
    if [[ "$base_no_ext" == *"[Cleaned]"* || "$base_no_ext" == *"[Trans]"* ]]; then
        rm -f "$f"
        continue
    fi

    # Skip if directory .skip marker exists
    if [[ -f "${dir}/.skip" ]]; then
        echo "Skipping $f -- .skip directory marker found"
        continue
    fi

    # Skip if per-file .skip_<basename> marker exists
    if [[ -f "${dir}/.skip_${base_no_ext}" ]]; then
        echo "Skipping $f -- .skip_${base_no_ext} per-file marker found"
        continue
    fi

    # Skip 2160p or higher resolution videos (filename match)
    if [[ "$base_no_ext" =~ 2160[pP]\] ]]; then
        echo "Skipping $f -- 4K (or higher) video match (filename)"
        continue
    fi

    echo "Checking $f"

    #####################################################
    # Unified ffprobe JSON (requires jq)
    #####################################################

    probe=$(ffprobe -v quiet -print_format json -show_streams "$f")

    vcodec=$(jq -r '.streams[] | select(.codec_type=="video") | .codec_name' <<< "$probe")
    vbitrate=$(jq -r '.streams[] | select(.codec_type=="video") | .bit_rate' <<< "$probe")
    acodec=$(jq -r '.streams[] | select(.codec_type=="audio") | .codec_name' <<< "$probe")
    field_order=$(jq -r '.streams[] | select(.codec_type=="video") | .field_order' <<< "$probe")

    # Skip AV1 files entirely
    if [[ "$vcodec" == "av1" ]]; then
        echo "Skipping $f -- AV1 detected"
        continue
    fi

    # SKIP: high resolution (> 1100p) -- ffprobe secondary check, supplements filename check
    height=$(jq -r '.streams[] | select(.codec_type=="video") | .height' <<< "$probe")
    if (( height > 1100 )); then
        echo "Skipping $f -- high-resolution video detected (height=$height)"
        continue
    fi

    # Fast checks first, skip expensive detection if already need to convert
    needs_convert=false
    [[ "$acodec" != "aac" ]] && needs_convert=true
    ! $needs_convert && [[ "$vcodec" != "hevc" ]] && needs_convert=true
    ! $needs_convert && (( vbitrate > 2500000 )) && needs_convert=true

    #####################################################
    # TELECINE + INTERLACE DETECTION (only if still needed!)
    #####################################################

    status="progressive"

    if ! $needs_convert && [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    elif ! $needs_convert && [[ "$field_order" != "progressive" ]]; then
        echo "Running deep scan for interlace/telecine..."

        interlaced_count=$(ffmpeg -nostdin -hide_banner \
            -ss 300 \
            -skip_frame nokey \
            -filter:v idet \
            -frames:v 200 \
            -an -f null - "$f" 2>&1 \
            | grep -oP 'Interlaced:\s*\K[0-9]+')

        telecine_flag=$(ffprobe -v error -select_streams v:0 -show_frames \
            -read_intervals "%+#300" \
            -show_entries frame=repeat_pict \
            -of csv=p=0 "$f" | grep -m1 1)

        if (( interlaced_count > 0 )); then
            status="interlaced"
        elif [[ -n "$telecine_flag" ]]; then
            status="telecine"
        else
            status="progressive"
        fi
    fi

    echo "Detected: $status"

    [[ "$status" != "progressive" ]] && needs_convert=true

    if ! $needs_convert; then
        if check_container_problem "$f"; then
            echo "Remuxing $f → container repair"
            tmpfile="$dir/${base_no_ext}[Trans].tmp"
            rm -f -- "$tmpfile"

            # mov_text → SRT: MP4 text subtitles cannot be stream-copied into MKV
            remux_sub_args=(-c:s copy)
            if [[ "$f" == *.mp4 ]]; then
                if jq -e '[.streams[] | select(.codec_type=="subtitle" and .codec_name=="mov_text")] | length > 0' <<< "$probe" >/dev/null 2>&1; then
                    echo "Subtitle: mov_text detected in MP4 -- converting to SRT for MKV output"
                    remux_sub_args=(-c:s srt)
                fi
            fi

            ffmpeg -nostdin -hide_banner -y \
                -i "$f" \
                -map 0 \
                -c:v copy -c:a copy \
                "${remux_sub_args[@]}" \
                -f matroska \
                "$tmpfile"

            if [[ $? -eq 0 && -f "$tmpfile" ]]; then
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
    # Filter chain selection
    #####################################################

    case "$status" in
        interlaced)
            echo "Using bwdif (interlaced)"
            vf_chain="hwdownload,format=yuv420p,bwdif=mode=send_frame,format=nv12,hwupload"
            ;;
        telecine)
            echo "Using fieldmatch+decimate+bwdif (telecine)"
            vf_chain="hwdownload,format=yuv420p,fieldmatch,decimate,bwdif=mode=send_frame,format=nv12,hwupload"
            ;;
        progressive)
            echo "Progressive -- no deinterlace"
            vf_chain="hwdownload,format=yuv420p,format=nv12,hwupload"
            ;;
    esac

    #####################################################
    # SUBTITLE HANDLING (mov_text → srt ONLY for MP4)
    #####################################################

    map_args="-map 0"
    subtitle_args="-c:s copy"

    if [[ "$f" == *.mp4 ]]; then
        if jq -e '.streams[] | select(.codec_type=="subtitle" and .codec_name=="mov_text")' <<< "$probe" >/dev/null; then
            echo "Subtitle: mov_text detected in MP4 → converting to SRT"
            subtitle_args="-c:s srt"
        else
            echo "Subtitle: MP4 but no mov_text → copying all"
        fi
    else
        echo "Subtitle: Non‑MP4 file → copying all"
    fi

    #####################################################
    # Transcoding section
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"
    echo "Using filter  : $vf_chain"

    [ -f "$tmpfile" ] && rm -f "$tmpfile"

    (
        ffmpeg -nostdin -hide_banner \
            -vaapi_device /dev/dri/renderD128 \
            -hwaccel vaapi \
            -hwaccel_output_format vaapi \
            -i "$f" \
            -copyts \
            -fflags +genpts \
            -fps_mode passthrough \
            -vf "$vf_chain" \
            -c:v hevc_vaapi \
            -qp 22 \
            -rc_mode VBR \
            -b:v 1800k \
            -maxrate 2000k \
            -bufsize 4000k \
            -quality 2 \
            -c:a aac -b:a 160k \
            $map_args \
            $subtitle_args \
            -f matroska \
            "$tmpfile"

        if [[ $? -eq 0 ]]; then
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")

            if (( new_size < orig_size )); then
                touch -r "$f" "$tmpfile"
                rm -f "$f"
                mv "$tmpfile" "$f"
                chown 1000:1000 "$f"
                chmod 666 "$f"
                echo "Replaced: $(( orig_size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB"
            else
                echo "Skipped: new file not smaller ($(( orig_size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB) - creating .skip_<basename> marker"
                touch "${dir}/.skip_${base_no_ext}"
                rm -f "$tmpfile"
            fi
        else
            rm -f "$tmpfile"
        fi
    ) &

    while (( $(jobs -r | wc -l) >= MAX_JOBS )); do
        wait -n
    done

done

wait

#####################################################
# Cleanup section
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . \
  \( -type f -name '*\[Trans\].tmp' \
  -o -type f -name '*\[Trans\].nfo' \
  -o -type f -name '*\[Trans\].jpg' \
  -o -type d -name '*\[Trans\].trickplay' \) \
  -exec rm -rf {} +

echo "All tasks complete."

