#!/bin/bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

MAX_JOBS=2

echo "Getting Filenames"

while read -r f; do
    size_bytes=$(stat -c%s "$f")
    size_gb=$((size_bytes / 1024 / 1024 / 1024))

    # Skip files smaller than 1GB
    (( size_gb < 1 )) && continue

    basename=$(basename "$f" .mkv)
    dir=$(dirname "$f")

    # Skip and delete cleaned/transcoded files
    if [[ "$basename" == *"[Cleaned]"* || "$basename" == *"[Trans]"* ]]; then
        rm -f "$f"
	continue
    fi

    #####################################################
    # ffprobe checks -- determine if conversion required
    #####################################################

    echo "Checking if conversion is required..."

    vcodec=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$f")

    vbitrate=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=bit_rate \
        -of default=nw=1:nk=1 "$f")

    acodec=$(ffprobe -v error -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$f")

    field_order=$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=field_order \
        -of default=nw=1:nk=1 "$f")

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

    tmpfile="$dir/${basename}[Trans].tmp"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"

    [ -f "$tmpfile" ] && rm -f "$tmpfile"

    echo "Detecting interlacing..."

    interlaced_count=$(ffmpeg -nostdin -hide_banner \
        -filter:v idet -frames:v 500 -an -f null - "$f" 2>&1 \
        | grep -oP 'Interlaced:\s*\K[0-9]+')

    if (( interlaced_count > 0 )); then
        echo "Detected interlaced video -- enabling bwdif"
        vf_chain="hwdownload,format=yuv420p,bwdif=mode=send_frame,format=nv12,hwupload"
    else
        echo "Detected progressive video -- skipping deinterlace"
        vf_chain="hwdownload,format=yuv420p,format=nv12,hwupload"
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

    # Allow only 2 concurrent encodes
    while (( $(jobs -r | wc -l) >= MAX_JOBS )); do
        sleep 1
    done

done < <(find . -type f \( -name "*.mkv" -o -name "*.ts" \))

wait

echo "Cleaning Up"
find . -type f -name '*[Trans].tmp' -delete
find . -type f -name '*[Trans].nfo' -delete
find . -type f -name '*[Trans].jpg' -delete
find . -type d -name '*[Trans].trickplay' -exec rm -rf {} +
