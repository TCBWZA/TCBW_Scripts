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
    # ffprobe JSON (requires jq)
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
    # Transcoding section (HandBrakeCLI)
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp.mkv"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"

    [ -f "$tmpfile" ] && rm -f "$tmpfile"

    #####################################################
    # Interlace detection → HandBrake filter selection
    #####################################################

    if [[ "$field_order" == "progressive" ]]; then
        echo "Progressive (from ffprobe) -- no deinterlace"
        hb_filter=""
    else
        echo "Detecting interlacing..."

        interlaced_count=$(ffmpeg -nostdin -hide_banner \
            -skip_frame nokey \
            -filter:v idet \
            -frames:v 200 \
            -an -f null - "$f" 2>&1 \
            | grep -oP 'Interlaced:\s*\K[0-9]+')

        if (( interlaced_count > 0 )); then
            echo "Detected interlaced video -- enabling decomb"
            hb_filter="--decomb"
        else
            echo "Detected progressive video -- no deinterlace"
            hb_filter=""
        fi
    fi

    echo "Using HandBrake filter: $hb_filter"

    (
        HandBrakeCLI \
            --input "$f" \
            --output "$tmpfile" \
            --format mkv \
            --encoder vaapi_h265 \
            --encoder-preset medium \
            --quality 22 \
            --vb 1800 \
            --maxHeight 2160 \
            --aencoder av_aac \
            --ab 160 \
            --mixdown stereo \
            --subtitle copy \
            $hb_filter

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
    # Parallel job control
    #####################################################

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
  \( -type f -name '*[Trans].tmp*' \
  -o -type f -name '*[Trans].nfo' \
  -o -type f -name '*[Trans].jpg' \
  -o -type d -name '*[Trans].trickplay' \) \
  -exec rm -rf {} +

echo "All tasks complete."
