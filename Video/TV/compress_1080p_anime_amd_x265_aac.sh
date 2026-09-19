#!/bin/bash

###############################################################
# PRE-FLIGHT CHECKS
###############################################################
for tool in ffprobe ffmpeg jq bc mkvmerge; do
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
WANT_REMUX_CHECK=false
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=true ;;
        -r|--remux-check) WANT_REMUX_CHECK=true ;;
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

    local ffmpeg_errors
    ffmpeg_errors=$(ffmpeg -nostdin -hide_banner -v error -i "$path" -f null - 2>&1)
    if [[ -n "$ffmpeg_errors" ]]; then
        debug "Container issue: ffmpeg demux errors detected"
        return 0
    fi

    return 1
}

#####################################################
# Allow nice to be used without breaking exit code
#####################################################
run_ffmpeg() {
    nice -n 10 ionice -c3 ffmpeg "$@"
    return $?
}

MAX_JOBS=2

echo "Starting up..."
echo "Scanning for files..."

# Find all video files >= 1GB
mapfile -t files < <(
    find . -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.ts" \) ! -iname "*-trailer.*" -size +950M
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
    # Extract audio streams (eng/jpn/chi/und/unk preferred; keep all if no such audio)
    #####################################################

    audio_streams=()
    while IFS=$'\t' read -r idx lang; do
        audio_streams+=("$idx" "$lang")
    done < <(
        jq -r '
          .streams[]
          | select(.codec_type=="audio")
          | [.index, ((.tags.language // .tags.LANGUAGE // "unk") | ascii_downcase)] | @tsv
        ' <<< "$probe"
    )

    if [[ ${#audio_streams[@]} -eq 0 ]]; then
        echo "Skipping $f -- no audio stream found"
        touch "$file_skip_file"
        continue
    fi

    # Keep only anime-relevant audio (eng/jpn/chi/und/unk) when present.
    # If no such audio exists, keep ALL audio so foreign-only content is
    # not silenced.
    has_eng_audio=false
    for ((i = 1; i < ${#audio_streams[@]}; i += 2)); do
        if [[ "${audio_streams[$i]}" =~ ^(eng|en|jpn|ja|chi|zho|zh|und|unk)$ ]]; then
            has_eng_audio=true
            break
        fi
    done

    audio_indices=()
    for ((i = 0; i < ${#audio_streams[@]}; i += 2)); do
        idx="${audio_streams[$i]}"
        lang="${audio_streams[$((i + 1))]}"
        if $has_eng_audio && [[ ! "$lang" =~ ^(eng|en|jpn|ja|chi|zho|zh|und|unk)$ ]]; then
            continue
        fi
        audio_indices+=("$idx")
    done

    debug "Audio indices (selected): ${audio_indices[*]}"

    # Track change detection: when eng/jpn/chi/und/unk audio exists,
    # non-matching audio tracks get dropped -- that is a format change, not a skip.
    audio_modified=false
    if $has_eng_audio; then
        for ((i = 1; i < ${#audio_streams[@]}; i += 2)); do
            if [[ ! "${audio_streams[$i]}" =~ ^(eng|en|jpn|ja|chi|zho|zh|und|unk)$ ]]; then
                audio_modified=true
                break
            fi
        done
    fi
    debug "audio_modified=$audio_modified"

    # Any kept audio track that is not AAC forces a transcode -- the pipeline
    # re-encodes kept audio to AAC (160k) to keep files small.
    audio_needs_aac=false
    for ai in "${audio_indices[@]}"; do
        ac_this=$(jq -r --argjson idx "$ai" '.streams[] | select(.codec_type=="audio" and .index==$idx) | .codec_name' <<< "$probe")
        if [[ "$ac_this" != "aac" ]]; then
            audio_needs_aac=true
            break
        fi
    done
    debug "audio_needs_aac=$audio_needs_aac"

    #####################################################
    # Extract subtitle streams (eng/und/unk; strip all if none match)
    #####################################################

    subtitle_streams=()
    while IFS=$'\t' read -r idx lang; do
        subtitle_streams+=("$idx" "$lang")
    done < <(
        jq -r '
          .streams[]
          | select(.codec_type=="subtitle")
          | [.index, ((.tags.language // .tags.LANGUAGE // "unk") | ascii_downcase)] | @tsv
        ' <<< "$probe"
    )

    subtitle_indices=()
    for ((i = 0; i < ${#subtitle_streams[@]}; i += 2)); do
        idx="${subtitle_streams[$i]}"
        lang="${subtitle_streams[$((i + 1))]}"
        if [[ "$lang" =~ ^(eng|en|und|unk)$ ]]; then
            subtitle_indices+=("$idx")
        fi
    done

    debug "Subtitle indices (selected): ${subtitle_indices[*]}"

    # Track change detection: subtitles not matching eng/und/unk get
    # stripped -- that is a format change, not a skip.
    subtitle_modified=false
    for ((i = 1; i < ${#subtitle_streams[@]}; i += 2)); do
        if [[ ! "${subtitle_streams[$i]}" =~ ^(eng|en|und|unk)$ ]]; then
            subtitle_modified=true
            break
        fi
    done
    debug "subtitle_modified=$subtitle_modified"


    #####################################################
    # Extract video/audio metadata
    #####################################################

    { IFS=$'\t' read -r vcodec vbitrate field_order color_transfer; read -r acodec; } < <(
        jq -r '
          (.streams[]
            | select(.codec_type=="video" and (.disposition.attached_pic != 1))
            | [.codec_name,
               (.bit_rate // .tags.BPS // 0 | tonumber),
               (.field_order // "unknown"),
               (.color_transfer // "unknown")]
            | @tsv),
          (.streams[]
            | select(.codec_type=="audio")
            | .codec_name)
        ' <<< "$probe"
    )

    if [[ -z "$vcodec" || -z "$acodec" ]]; then
        echo "Skipping $f -- missing required video or audio stream"
        touch "$file_skip_file"
        continue
    fi

    vcodec_lc=$(echo "$vcodec" | tr '[:upper:]' '[:lower:]')

    debug "vcodec=$vcodec_lc vbitrate=$vbitrate field_order=$field_order color_transfer=$color_transfer acodec=$acodec"

    #####################################################
    # HARD SKIP AV1 (matches PowerShell)
    #####################################################

    if [[ "$vcodec_lc" =~ ^(av1|av01|libaom-av1|unknown)$ ]]; then
        echo "Skipping $f -- AV1 or unsupported codec detected ($vcodec_lc)"
        continue
    fi

    # Detect height -- flag for downscale if > 1080
    height=$(jq -r '
      [.streams[]
        | select(.codec_type=="video" and (.disposition.attached_pic != 1))
        | .height
      ] | max
    ' <<< "$probe")

    needs_downscale=false
    (( height > 1080 )) && needs_downscale=true

    # HDR detection: smpte2084 (HDR10) / arib-std-b67 (HLG) -> tone map to SDR
    needs_tonemap=false
    if [[ "$color_transfer" =~ ^(smpte2084|arib-std-b67)$ ]]; then
        needs_tonemap=true
    fi

    debug "height=$height needs_downscale=$needs_downscale needs_tonemap=$needs_tonemap"

    # Real video track id (first non-attached-pic video stream); mkvmerge
    # track ids match ffprobe .index, so this is safe for both ffmpeg and mkvmerge.
    video_track_id=$(jq -r '
      [.streams[]
        | select(.codec_type=="video" and (.disposition.attached_pic != 1))
        | .index] | first
    ' <<< "$probe")
    debug "video_track_id=$video_track_id"

    #####################################################
    # Interlace / telecine detection (PowerShell parity)
    #####################################################

    status="progressive"

    if [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    elif [[ "$field_order" != "progressive" ]]; then
        echo "Running deep interlace/telecine scan..."

        idet_output=$(
            run_ffmpeg -nostdin -hide_banner -threads 2 \
                -ss 300 \
                -noaccurate_seek \
                -skip_frame nokey \
                -i "$f" \
                -skip_frame default \
                -filter:v idet \
                -frames:v 1000 \
                -an -f null - 2>&1
        )

        interlaced_count=$(echo "$idet_output" | grep -oP 'Interlaced:\s*\K[0-9]+' | head -n1)
        progressive_count=$(echo "$idet_output" | grep -oP 'Progressive:\s*\K[0-9]+' | head -n1)
        tff_count=$(echo "$idet_output" | grep -oP 'TFF:\s*\K[0-9]+' | head -n1)
        bff_count=$(echo "$idet_output" | grep -oP 'BFF:\s*\K[0-9]+' | head -n1)

        [[ -z "$interlaced_count" ]] && interlaced_count=0
        [[ -z "$tff_count" ]] && tff_count=0
        [[ -z "$bff_count" ]] && bff_count=0

        if (( tff_count > 50 || bff_count > 50 )) && (( interlaced_count < 20 )); then
            status="telecine"
        elif (( interlaced_count > 50 )); then
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
    $needs_downscale && needs_convert=true
    $needs_tonemap && needs_convert=true
    $audio_modified && needs_convert=true
    $audio_needs_aac && needs_convert=true
    $subtitle_modified && needs_convert=true
    debug "Needs convert: $needs_convert"
    if ! $needs_convert; then
        #####################################################
        # No transcode needed -- check for container problems
        #####################################################
        if [[ "$WANT_REMUX_CHECK" == "true" ]] && [[ "$acodec" == "aac" ]] && check_container_problem "$f"; then
            echo "Remuxing $f -> container repair"
            tmpfile="$dir/${base_no_ext}[Trans].tmp"

            rm -f -- "$tmpfile"

            remux_map_args=(-map 0:v:0 -map 0:a? -map -0:v:m:attached_pic)
            remux_sub_args=()
            if [[ ${#subtitle_indices[@]} -gt 0 ]]; then
                for si in "${subtitle_indices[@]}"; do
                    remux_map_args+=( -map "0:${si}" )
                done
                remux_sub_args=(-c:s copy)
            fi
            run_ffmpeg -nostdin -hide_banner -threads 2 -y \
                -i "$f" \
                "${remux_map_args[@]}" \
                -c:v copy -c:a copy \
                "${remux_sub_args[@]}" \
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
                echo "Replaced (remux): $((orig_size/1024/1024))MB -> $((new_size/1024/1024))MB"
            else
                rm -f -- "$tmpfile"
            fi
        else
            echo "Skipping $f -- already in desired format"
        fi

        continue
    fi

    #####################################################
    # Transcode
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"
    temp_files+=("$tmpfile")
    rm -f -- "$tmpfile"

    #####################################################
    # Build map arguments (audio and filtered subtitles)
    #####################################################

    map_args=(
        -map "0:${video_track_id}"
    )

    for ai in "${audio_indices[@]}"; do
        map_args+=( -map "0:${ai}" )
    done

    sub_codec_args=()
    if [[ ${#subtitle_indices[@]} -gt 0 ]]; then
        for si in "${subtitle_indices[@]}"; do
            map_args+=( -map "0:${si}" )
        done
        # mov_text -> SRT: MP4 text subtitles cannot be stream-copied into MKV
        sub_codec_args=(-c:s copy)
        if [[ "$f" == *.mp4 ]]; then
            if jq -e '[.streams[] | select(.codec_type=="subtitle" and .codec_name=="mov_text")] | length > 0' <<< "$probe" >/dev/null 2>&1; then
                debug "Subtitle: mov_text detected in MP4 -- converting to SRT for MKV output"
                sub_codec_args=(-c:s srt)
            fi
        fi
    fi

    #####################################################
    # Build video filter chain (base + tonemap + downscale)
    #####################################################

    case "$status" in

        progressive)
            pre_vf=""
            debug "Transcode path: PROGRESSIVE -> CPU decode + VAAPI encode (fast path)"
            ;;

        interlaced)
            pre_vf="bwdif=mode=send_frame"
            debug "Transcode path: INTERLACED -> CPU bwdif + VAAPI encode"
            ;;

        telecine)
            pre_vf="pullup,dejudder"
            debug "Transcode path: TELECINE -> CPU pullup/dejudder + VAAPI encode"
            ;;
    esac

    vf_chain=()
    [[ -n "$pre_vf" ]] && vf_chain+=("$pre_vf")

    # HDR->SDR tone mapping: VAAPI driver lacks HDR VPP, so use CPU
    # zscale/tonemap (bt2020 -> bt709, hable) before hwupload.
    if $needs_tonemap; then
        debug "Tone mapping: CPU zscale/tonemap (driver lacks HDR VPP)"
        vf_chain+=(zscale=transfer=linear tonemap=hable zscale=primaries=bt709:transfer=bt709:matrix=bt709)
    fi

    # Downscale >1080p on CPU and pad to a full 1920x1080 black frame.
    # scale_vaapi leaves garbage pixels (green edge) in the encoder alignment
    # padding for non-aligned widths, so pad with black instead.
    if $needs_downscale; then
        vf_chain+=(scale=w=1920:h=1080:force_original_aspect_ratio=decrease:flags=bicubic)
        vf_chain+=('pad=w=1920:h=1080:x=(ow-iw)/2:y=(oh-ih)/2:color=black')
    fi

    vf_chain+=(format=nv12 hwupload)
    vf="$(IFS=,; echo "${vf_chain[*]}")"

    debug "vf=$vf"

    transcode_cmd=(
        run_ffmpeg
        -nostdin
        -hide_banner
        -threads 2
        -vaapi_device /dev/dri/renderD128
        -i "$f"
        -vf "$vf"
        "${map_args[@]}"
        -c:v:0 hevc_vaapi
        -qp 28
        -metadata:s:v:0 language=zxx
        -c:a aac
        -b:a 160k
        "${sub_codec_args[@]}"
        -f matroska
        "$tmpfile"
    )

    (
        "${transcode_cmd[@]}"

        if [[ $? -eq 0 ]]; then
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")

            if (( new_size * 10 < orig_size * 9 )); then
                touch -r "$f" "$tmpfile"
                rm -f -- "$f"
                mv -- "$tmpfile" "$f"
                chown 1000:1000 "$f"
                chmod 666 "$f"
                echo "Replaced: $((orig_size/1024/1024))MB -> $((new_size/1024/1024))MB"
            else
                echo "Skipped: new file not smaller"
                touch "$file_skip_file"
                if $audio_modified || $subtitle_modified; then
                    echo "Track fix via mkvmerge (stream-copy remux, strips unwanted audio/subs, video lang -> zxx)"
                    strip_tmpfile="$dir/${base_no_ext}[Strip].tmp"
                    rm -f -- "$strip_tmpfile"
                    mkv_args=(mkvmerge -q -o "$strip_tmpfile" --language "${video_track_id}:zxx" --video-tracks "${video_track_id}")
                    if [[ ${#audio_indices[@]} -gt 0 ]]; then
                        mkv_args+=(--audio-tracks "$(IFS=,; echo "${audio_indices[*]}")")
                    else
                        mkv_args+=(--no-audio)
                    fi
                    if [[ ${#subtitle_indices[@]} -gt 0 ]]; then
                        mkv_args+=(--subtitle-tracks "$(IFS=,; echo "${subtitle_indices[*]}")")
                    else
                        mkv_args+=(--no-subtitles)
                    fi
                    mkv_args+=("$f")
                    "${mkv_args[@]}"
                    if [[ $? -eq 0 && -s "$strip_tmpfile" ]]; then
                        touch -r "$f" "$strip_tmpfile"
                        rm -f -- "$f"
                        mv -- "$strip_tmpfile" "$f"
                        chown 1000:1000 "$f"
                        chmod 666 "$f"
                        echo "Replaced (mkvmerge strip): tracks fixed, video bitstream unchanged"
                    else
                        echo "mkvmerge strip failed for $f"
                        rm -f -- "$strip_tmpfile"
                    fi
                fi
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
# Cleanup (PowerShell parity: only remove true leftovers)
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . -type f -regex '.*\[Trans\]\.tmp$' -delete
find . -type f -regex '.*\[Strip\]\.tmp$' -delete
find . -type f -regex '.*\[Trans\]\.nfo$' -delete
find . -type f -regex '.*\[Trans\]\.jpg$' -delete
find . -type d -regex '.*\[Trans\]\.trickplay$' -exec rm -rf {} +

echo "All tasks complete."
