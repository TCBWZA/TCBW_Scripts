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

    echo "Checking $f"

    #####################################################
    # Unified ffprobe JSON (requires jq)
    #####################################################

    probe=$(ffprobe -v quiet -print_format json -show_streams "$f")

    vcodec=$(jq -r '.streams[] | select(.codec_type=="video") | .codec_name' <<< "$probe")
    vbitrate=$(jq -r '.streams[] | select(.codec_type=="video") | .bit_rate' <<< "$probe")
    acodec=$(jq -r '.streams[] | select(.codec_type=="audio") | .codec_name' <<< "$probe")
    field_order=$(jq -r '.streams[] | select(.codec_type=="video") | .field_order' <<< "$probe")

    # Fast checks first, skip expensive detection if already need to convert
    needs_convert=false
    [[ "$acodec" != "aac" ]] && needs_convert=true
    ! $needs_convert && [[ "$vcodec" != "hevc" ]] && needs_convert=true
    ! $needs_convert && (( vbitrate > 2500000 )) && needs_convert=true

    #####################################################
    # TELECINE + INTERLACE DETECTION (only if still needed!)
    #####################################################

    status="progressive"

    # Quick check: if field_order explicitly indicates interlaced, mark it immediately
    if ! $needs_convert && [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    # Otherwise, run deep scan unless explicitly progressive or already need to convert
    elif ! $needs_convert && [[ "$field_order" != "progressive" ]]; then
        echo "Running deep scan for interlace/telecine..."

        # Detect interlaced frames using idet filter
        interlaced_count=$(ffmpeg -nostdin -hide_banner \
            -skip_frame nokey \
            -filter:v idet \
            -frames:v 200 \
            -an -f null - "$f" 2>&1 \
            | grep -oP 'Interlaced:\s*\K[0-9]+')

        # Detect telecine via repeat_pict
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

    # Telecine or interlaced ALWAYS requires conversion
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
            -c:s copy \
            -f matroska \
            "$tmpfile"

        # shellcheck disable=SC2181
        if [[ $? -eq 0 ]]; then
            # Only replace original if new file is smaller
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")
            
            if (( new_size < orig_size )); then
                touch -r "$f" "$tmpfile"
                rm -f "$f"
                mv "$tmpfile" "$f"
                # chown <USER>:<GROUP> "$f"  # Uncomment and set to desired owner if needed
                chmod 666 "$f"
                echo "Replaced: $(( orig_size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB"
            else
                echo "Skipped: new file not smaller ($(( orig_size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB) - creating .skip file"
                touch "${dir}/.skip"
                rm -f "$tmpfile"
            fi
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
# Cleanup section
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . \
  \( -type f -name '*[Trans].tmp' \
  -o -type f -name '*[Trans].nfo' \
  -o -type f -name '*[Trans].jpg' \
  -o -type d -name '*[Trans].trickplay' \) \
  -exec rm -rf {} +

echo "All tasks complete."
