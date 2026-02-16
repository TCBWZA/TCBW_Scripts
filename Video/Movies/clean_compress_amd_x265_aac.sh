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
    if (( size_gb < 5 )); then
        continue
    fi

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
    vbitrate=$(jq -r '.streams[] | select(.codec_type=="video") | (.tags.BPS // .bit_rate // "0")' <<< "$probe")
    acodec=$(jq -r '.streams[] | select(.codec_type=="audio") | .codec_name' <<< "$probe")
    field_order=$(jq -r '.streams[] | select(.codec_type=="video") | .field_order' <<< "$probe")

    needs_convert=false

    if [[ "$vcodec" != "hevc" ]]; then
        needs_convert=true
    fi
    if [[ "$vbitrate" =~ ^[0-9]+$ ]] && (( vbitrate > 2500000 )); then
        needs_convert=true
    fi
    if [[ "$acodec" != "aac" ]]; then
        needs_convert=true
    fi

    #####################################################
    # TELECINE + INTERLACE DETECTION (check first!)
    #####################################################

    status="progressive"

    # Quick check: if field_order explicitly indicates interlaced, mark it immediately
    if [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    # Otherwise, run deep scan unless explicitly progressive
    elif [[ "$field_order" != "progressive" ]]; then
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

    # Interlaced or telecine ALWAYS requires conversion
    if [[ "$status" != "progressive" ]]; then
        needs_convert=true
    fi

    #####################################################
    # VIDEO CODEC DECISION
    #####################################################

    # If interlaced/telecine, must encode; otherwise check if we can copy
    if [[ "$status" != "progressive" ]]; then
        video_encode="-c:v hevc_vaapi -qp 24 -rc_mode VBR -b:v 1800k -maxrate 2000k -bufsize 4000k -quality 2"
        echo "Interlaced/telecine detected: will encode video"
        vf_chain=""
        # Filter chain will be set below based on status
    elif [[ "$vcodec" == "hevc" ]] && [[ "$vbitrate" =~ ^[0-9]+$ ]] && (( vbitrate <= 2500000 )); then
        video_encode="-c:v copy"
        echo "Video codec is x265 and within bitrate limits: copying"
        vf_chain=""
    else
        video_encode="-c:v hevc_vaapi -qp 24 -rc_mode VBR -b:v 1800k -maxrate 2000k -bufsize 4000k -quality 2"
        echo "Video codec is not x265 or exceeds bitrate limits: encoding"
        vf_chain=""
    fi

    #####################################################
    # FILTER CHAIN SELECTION (only if not copying video)
    #####################################################

    if [[ "$video_encode" != "-c:v copy" ]]; then
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
    fi

    #####################################################
    # AUDIO AND SUBTITLE TRACK ANALYSIS
    #####################################################

    # Get audio stream count
    audio_count=$(jq '[.streams[] | select(.codec_type=="audio")] | length' <<< "$probe")
    
    # Get subtitle stream count
    subtitle_count=$(jq '[.streams[] | select(.codec_type=="subtitle")] | length' <<< "$probe")

    echo "Found $audio_count audio track(s) and $subtitle_count subtitle track(s)"

    # Build audio stream mapping
    audio_map=""
    if (( audio_count == 1 )); then
        # Single audio track: copy it
        audio_map="-c:a copy"
        echo "  → Single audio track: copying as-is"
    elif (( audio_count > 1 )); then
        # Multiple audio tracks: look for English first
        english_audio=$(jq -r '.streams[] | select(.codec_type=="audio") | select(.tags.language == "eng" or .tags.language == "en" or (.tags.title and (.tags.title | contains("English")))) | .index' <<< "$probe")
        
        # Also get unknown/null language streams
        unknown_audio=$(jq -r '.streams[] | select(.codec_type=="audio") | select(.tags.language == null or .tags.language == "und") | .index' <<< "$probe")
        
        # Combine: English + unknown/null
        all_audio="$english_audio $unknown_audio"
        all_audio=$(echo "$all_audio" | xargs)  # Remove extra whitespace
        
        echo "  DEBUG: Found English audio indices: '$english_audio'"
        echo "  DEBUG: Found unknown/null audio indices: '$unknown_audio'"
        
        if [[ -n "$all_audio" ]]; then
            # Build -map commands for all matched audio tracks using STREAM indices
            audio_map="-map 0:v:0 -c:a copy"
            for idx in $all_audio; do
                # idx is a stream index, use it directly
                audio_map="$audio_map -map 0:$idx"
            done
            echo "  → Multiple audio tracks: keeping English/unknown tracks"
        else
            # No English or unknown found, map first audio explicitly
            first_audio_idx=$(jq -r '.streams[] | select(.codec_type=="audio") | .index' <<< "$probe" | head -n1)
            first_audio_lang=$(jq -r ".streams[] | select(.codec_type==\"audio\" and .index==$first_audio_idx) | .tags.language // \"unknown\"" <<< "$probe")
            audio_map="-map 0:v:0 -map 0:$first_audio_idx -c:a copy"
            echo "  → No English/unknown audio found, keeping first audio stream $first_audio_idx ($first_audio_lang)"
        fi
    else
        # No audio tracks
        audio_map=""
        echo "  → No audio tracks"
    fi

    # Build subtitle stream mapping
    subtitle_map=""
    if (( subtitle_count == 1 )); then
        # Single subtitle: copy it
        subtitle_idx=$(jq -r '.streams[] | select(.codec_type=="subtitle") | .index' <<< "$probe")
        if [[ ! "$audio_map" =~ "-map 0:v:0" ]]; then
            subtitle_map="-map 0:v:0 -map 0:$subtitle_idx -c:s copy"
        else
            subtitle_map="-map 0:$subtitle_idx -c:s copy"
        fi
        echo "  → Single subtitle track: copying as-is"
    elif (( subtitle_count > 1 )); then
        # Multiple subtitles: look for English first
        english_subs=$(jq -r '.streams[] | select(.codec_type=="subtitle") | select(.tags.language == "eng" or .tags.language == "en" or (.tags.title and (.tags.title | contains("English")))) | .index' <<< "$probe")
        
        # Also get unknown/null language streams
        unknown_subs=$(jq -r '.streams[] | select(.codec_type=="subtitle") | select(.tags.language == null or .tags.language == "und") | .index' <<< "$probe")
        
        # Combine: English + unknown/null
        all_subs="$english_subs $unknown_subs"
        all_subs=$(echo "$all_subs" | xargs)  # Remove extra whitespace
        
        # echo "  DEBUG: Found English subtitle indices: '$english_subs'"
        # echo "  DEBUG: Found unknown/null subtitle indices: '$unknown_subs'"
        
        if [[ -n "$all_subs" ]]; then
            # MUST include -map 0:v:0 when using explicit -map for subtitles (v:0 skips attached pics)
            # Only add it if audio_map doesn't already have it
            if [[ ! "$audio_map" =~ "-map 0:v:0" ]]; then
                subtitle_map="-map 0:v:0 -c:s copy"
            else
                subtitle_map="-c:s copy"
            fi
            for idx in $all_subs; do
                # idx is a stream index, use it directly
                subtitle_map="$subtitle_map -map 0:$idx"
            done
            echo "  → Multiple subtitle tracks: keeping English/unknown tracks"
        else
            echo "  → No English/unknown subtitles found"
            subtitle_map=""
        fi
    else
        # No subtitles
        subtitle_map=""
        echo "  → No subtitle tracks"
    fi

    # Check if any conversion is actually needed
    if ! $needs_convert && [[ -z "$audio_map" || "$audio_map" == "-c:a copy" ]] && [[ -z "$subtitle_map" || "$subtitle_map" == "-c:s copy" ]]; then
        echo "Skipping $f -- already in desired format"
        continue
    fi

    #####################################################
    # Transcoding section
    #####################################################

    tmpfile="$dir/${base_no_ext}[Cleaned].tmp"

    echo "Input         : $f"
    echo "Temp Out      : $tmpfile"

    [ -f "$tmpfile" ] && rm -f "$tmpfile"

    (
        if [[ -z "$vf_chain" ]]; then
            # No video filter (video is being copied)
            # shellcheck disable=SC2086
            ffmpeg -nostdin -hide_banner \
                -i "$f" \
                -copyts \
                $video_encode \
                $audio_map \
                $subtitle_map \
                -f matroska \
                "$tmpfile"
        else
            # Video filter chain needed
			# shellcheck disable=SC2086
            ffmpeg -nostdin -hide_banner \
                -vaapi_device /dev/dri/renderD128 \
                -hwaccel vaapi \
                -hwaccel_output_format vaapi \
                -i "$f" \
                -copyts \
                -fflags +genpts \
                -fps_mode passthrough \
                -vf "$vf_chain" \
                $video_encode \
                $audio_map \
                $subtitle_map \
                -f matroska \
                "$tmpfile"
        fi

        # shellcheck disable=SC2181
        if [[ $? -eq 0 ]]; then
            touch -r "$f" "$tmpfile"
            rm -f "$f"
            mv "$tmpfile" "$f"
            # chown <USER>:<GROUP> "$f"  # Uncomment and set to desired owner if needed
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
# Cleanup section
#####################################################

echo "Cleaning up leftover [Cleaned] files..."

find . \
  \( -type f -name '*[Cleaned].tmp' \
  -o -type f -name '*[Cleaned].nfo' \
  -o -type f -name '*[Cleaned].jpg' \
  -o -type d -name '*[Cleaned].trickplay' \) \
  -exec rm -rf {} +

echo "All tasks complete."
