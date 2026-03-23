#!/bin/bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

MAX_JOBS=2
MIN_SIZE_GB=1   # Convert if file is >= this size

echo "Starting up..."
echo "Scanning for files..."

mapfile -t files < <(find . -type f \( -name "*.mkv" -o -name "*.mp4" -o -name "*.ts" \))

echo "Found ${#files[@]} files."
echo "Beginning processing..."

for f in "${files[@]}"; do

    #####################################################
    # Size detection (floating point)
    #####################################################

    size_bytes=$(stat -c%s "$f")
    size_gb=$(echo "scale=2; $size_bytes / 1024 / 1024 / 1024" | bc)

    # Skip files smaller than threshold
    if [[ $(echo "$size_gb < $MIN_SIZE_GB" | bc) -eq 1 ]]; then
        continue
    fi

    basename=$(basename "$f")
    base_no_ext="${basename%.*}"
    dir=$(dirname "$f")

    file_skip_file="${dir}/.skip_${base_no_ext}"
    parent_skip_file="${dir}/../.skip"

    if [[ "$base_no_ext" == *"[Cleaned]"* || "$base_no_ext" == *"[Trans]"* ]]; then
        rm -f "$f"
        continue
    fi

    if [[ -f "$parent_skip_file" ]]; then
        echo "Skipping $f -- parent directory marked with .skip"
        continue
    fi
    if [[ -f "$file_skip_file" ]]; then
        echo "Skipping $f -- file marked with .skip_${base_no_ext}"
        continue
    fi

    echo "Checking $f"

    #####################################################
    # ffprobe metadata
    #####################################################

    probe=$(ffprobe -v quiet -print_format json -show_streams "$f")

    vcodec=$(jq -r '.streams[] | select(.codec_type=="video") | .codec_name' <<< "$probe")
    vbitrate=$(jq -r '.streams[] | select(.codec_type=="video") | .bit_rate' <<< "$probe")
    acodec=$(jq -r '.streams[] | select(.codec_type=="audio") | .codec_name' <<< "$probe")
    achannels=$(jq -r '.streams[] | select(.codec_type=="audio") | .channels' <<< "$probe")
    alayout=$(jq -r '.streams[] | select(.codec_type=="audio") | .channel_layout' <<< "$probe")
    field_order=$(jq -r '.streams[] | select(.codec_type=="video") | .field_order' <<< "$probe")

    #####################################################
    # Conversion decision
    #####################################################

    needs_convert=false

    [[ "$acodec" != "aac" ]] && needs_convert=true
    ! $needs_convert && [[ "$vcodec" != "hevc" ]] && needs_convert=true
    ! $needs_convert && (( vbitrate > 2500000 )) && needs_convert=true

    # Force convert if file >= MIN_SIZE_GB
    if [[ $(echo "$size_gb >= $MIN_SIZE_GB" | bc) -eq 1 ]]; then
        needs_convert=true
    fi

    #####################################################
    # Interlace / telecine detection
    #####################################################

    status="progressive"

    if [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    elif [[ "$field_order" != "progressive" ]]; then
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
        echo "Skipping $f -- already in desired format"
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
    # Audio handling (C3‑C)
    #####################################################

    # Default: stereo fallback
    audio_args="-c:a aac -ac 2 -b:a 160k"

    if [[ "$alayout" != "unknown" && -n "$alayout" ]]; then
        if (( achannels == 2 )); then
            audio_args="-c:a aac -ac 2 -b:a 160k"
        elif (( achannels == 6 )); then
            audio_args="-c:a aac -ac 6 -channel_layout 5.1 -b:a 384k"
        elif (( achannels == 8 )); then
            audio_args="-c:a aac -ac 6 -channel_layout 5.1 -b:a 384k"
        else
            audio_args="-c:a aac -ac $achannels -channel_layout $alayout -b:a 256k"
        fi
    fi

    #####################################################
    # Transcoding
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"
    echo "Using filter  : $vf_chain"
    echo "Audio args    : $audio_args"

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
            $audio_args \
            -c:s copy \
            -f matroska \
            "$tmpfile"

        if [[ $? -eq 0 ]]; then
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")

            if (( new_size < orig_size )); then
                touch -r "$f" "$tmpfile"
                rm -f "$f"
                mv "$tmpfile" "$f"
                chmod 666 "$f"
                echo "Replaced: $(( orig_size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB"
            else
                file_skip_file="${dir}/.skip_${base_no_ext}"
                echo "Skipped: new file not smaller ($(( orig_size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB) - creating .skip_${base_no_ext}"
                touch "$file_skip_file"
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

echo "Cleaning up leftover [Trans] files..."

find . \
  \( -type f -name '*[Trans].tmp' \
  -o -type f -name '*[Trans].nfo' \
  -o -type f -name '*[Trans].jpg' \
  -o -type d -name '*[Trans].trickplay' \) \
  -exec rm -rf {} +

