#!/bin/bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

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

    # Skip files smaller than 1GB
    (( size_gb < 1 )) && continue

    basename=$(basename "$f")
    base_no_ext="${basename%.*}"
    dir=$(dirname "$f")

    # Skip and delete cleaned/transcoded files
    if [[ "$base_no_ext" == *"[Cleaned]"* || "$base_no_ext" == *"[Trans]"* ]]; then
        rm -f "$f"
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

    needs_convert=false

    [[ "$vcodec" != "hevc" ]] && needs_convert=true
    (( vbitrate > 2500000 )) && needs_convert=true
    [[ "$acodec" != "aac" ]] && needs_convert=true
    [[ "$field_order" != "progressive" ]] && needs_convert=true

    if ! $needs_convert; then
        echo "Skipping $f -- already in desired format"
        continue
    fi

    #####################################################
    # Transcoding section
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"

    [ -f "$tmpfile" ] && rm -f "$tmpfile"

    #####################################################
    # Optimised interlace detection
    #####################################################

    if [[ "$field_order" == "progressive" ]]; then
        echo "Progressive (from ffprobe) -- skipping idet"
        vf_chain="hwdownload,format=yuv420p,format=nv12,hwupload"
    else
        echo "Detecting interlacing..."

        interlaced_count=$(ffmpeg -nostdin -hide_banner \
            -skip_frame nokey \
            -filter:v idet \
            -frames:v 200 \
            -an -f null - "$f" 2>&1 \
            | grep -oP 'Interlaced:\s*\K[0-9]+')

        if (( interlaced_count > 0 )); then
            echo "Detected interlaced video -- enabling bwdif"
            vf_chain="hwdownload,format=yuv420p,bwdif=mode=send_frame,format=nv12,hwupload"
        else
            echo "Detected progressive video -- skipping deinterlace"
            vf_chain="hwdownload,format=yuv420p,format=nv12,hwupload"
        fi
    fi

    echo "Using filter chain: $vf_chain"

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
            -c:s copy \
            -f matroska \
            "$tmpfile"

        if [[ $? -eq 0 ]]; then
            touch -r "$f" "$tmpfile"
            rm -f "$f"
            mv "$tmpfile" "$f"
            chown duncan:duncan "$f"
            chmod 666 "$f"
        else
            rm -f "$tmpfile"
        fi
    ) &

    #####################################################
    # Improved parallelism using wait -n (Bash 5+)
    #####################################################

    while (( $(jobs -r | wc -l) >= MAX_JOBS )); do
        wait -n
    done

done

wait

#####################################################
# Cleanup section (combined and efficient)
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . \
  \( -type f -name '*[Trans].tmp' \
  -o -type f -name '*[Trans].nfo' \
  -o -type f -name '*[Trans].jpg' \
  -o -type d -name '*[Trans].trickplay' \) \
  -exec rm -rf {} +

echo "All tasks complete."
