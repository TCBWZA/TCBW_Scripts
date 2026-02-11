#!/bin/bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

MAX_JOBS=2

echo "Getting Filenames"

while read -r f; do
    size_bytes=$(stat -c%s "$f")
    size_gb=$((size_bytes / 1024 / 1024 / 1024))

    # Skip files smaller than 1GB
    (( size_gb < 1 )) && continue

    basename=$(basename "$f" .mp4)
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

    needs_convert=false

    # Video rules
    (( vbitrate > 2500000 )) && needs_convert=true
    [[ "$vcodec" != "hevc" ]] && needs_convert=true

    # Audio rules
    [[ "$acodec" != "aac" ]] && needs_convert=true

    if ! $needs_convert; then
        echo "Skipping $f -- already in desired format"
        continue
    fi

    #####################################################
    # Detect English audio track
    #####################################################

    english_aidx=$(ffprobe -v error -select_streams a \
        -show_entries stream=index:stream_tags=language \
        -of csv=p=0 "$f" | awk -F',' '$2=="eng"{print $1; exit}')

    # Fallback to first audio track
    if [[ -z "$english_aidx" ]]; then
        english_aidx=0
    fi

    echo "Default audio track will be: $english_aidx"

    #####################################################
    # Build disposition flags for all audio tracks
    #####################################################

    disposition_args=()

    audio_count=$(ffprobe -v error -select_streams a \
        -show_entries stream=index \
        -of csv=p=0 "$f" | wc -l)

    for ((i=0; i<audio_count; i++)); do
        if [[ $i -eq $english_aidx ]]; then
            disposition_args+=("-disposition:a:$i" "default")
        else
            disposition_args+=("-disposition:a:$i" "none")
        fi
    done

    #####################################################
    # mov_text subtitle fix
    #####################################################

    subtitle_fix_args=()

    sub_codecs=$(ffprobe -v error -select_streams s \
        -show_entries stream=codec_name \
        -of csv=p=0 "$f")

    if echo "$sub_codecs" | grep -q "mov_text"; then
        subtitle_fix_args+=("-c:s" "srt")
    else
        subtitle_fix_args+=("-c:s" "copy")
    fi

    #####################################################
    # Decide video codec: copy if HEVC, encode if not
    #####################################################

    if [[ "$vcodec" == "hevc" ]]; then
        echo "Video is already HEVC — copying video track"
        pre_input_args=()  # no hwaccel
        video_codec_args=("-c:v" "copy")
    else
        echo "Video is NOT HEVC — transcoding with VAAPI"

        # These MUST come BEFORE -i
        pre_input_args=(
            "-vaapi_device" "/dev/dri/renderD128"
            "-hwaccel" "vaapi"
            "-hwaccel_output_format" "vaapi"
        )

        # These come AFTER mapping
        video_codec_args=(
            "-c:v" "hevc_vaapi"
            "-qp" "22"
            "-rc_mode" "VBR"
            "-b:v" "1800k"
            "-maxrate" "2000k"
            "-bufsize" "4000k"
            "-quality" "2"
        )
    fi

    #####################################################
    # Transcoding section
    #####################################################

    tmpfile="$dir/${basename}[Trans].tmp"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"

    [ -f "$tmpfile" ] && rm -f "$tmpfile"

    (
        ffmpeg -nostdin -hide_banner \
            "${pre_input_args[@]}" \
            -i "$f" \
            -copyts \
            -fflags +genpts \
            -fps_mode passthrough \
            -map 0:v:0 -map 0:a -map 0:s? \
            "${disposition_args[@]}" \
            "${video_codec_args[@]}" \
            -c:a aac -b:a 160k \
            "${subtitle_fix_args[@]}" \
            -f mp4 \
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

done < <(find . -type f -name "*.mp4")

wait

echo "Cleaning Up"
find . -type f -name '*[Trans].tmp' -delete
find . -type f -name '*[Trans].nfo' -delete
find . -type f -name '*[Trans].jpg' -delete
find . -type d -name '*[Trans].trickplay' -exec rm -rf {} +
