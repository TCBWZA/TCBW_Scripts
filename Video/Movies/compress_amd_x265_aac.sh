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

    # Deeper check: demux pass catches non-monotonic timestamps, truncation, missing moov
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

# Find all video files >= 5GB
mapfile -t files < <(
    find . -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.ts" \) ! -iname "*-trailer.*" -size +5G
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
    # Extract audio streams (eng/und/unk preferred; keep all if no such audio)
     #####################################################

    # Primary video stream (first non-attached video)
    v_index=$(jq -r '
      [.streams[]
        | select(.codec_type=="video" and (.disposition.attached_pic != 1))
        | .index] | .[0]
    ' <<< "$probe")

    if [[ "$v_index" == "null" || -z "$v_index" ]]; then
        echo "Skipping $f -- no primary video stream found"
        continue
    fi

    debug "Primary video stream index: $v_index"

    # All audio streams (index + language pairs, flattened)
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

    # All subtitle streams (index + language pairs, flattened)
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

    if [[ ${#audio_streams[@]} -eq 0 ]]; then
        echo "Skipping $f -- no audio stream found"
        touch "$file_skip_file"
        continue
    fi

    # Prefer English/unknown audio. If present, strip non-English audio+subs.
    # If absent, keep all tracks so foreign-only content is not gutted.
    has_eng_audio=false
    for ((i = 1; i < ${#audio_streams[@]}; i += 2)); do
        if [[ "${audio_streams[$i]}" =~ ^(eng|en|und|unk)$ ]]; then
            has_eng_audio=true
            break
        fi
    done

    audio_indices=()
    for ((i = 0; i < ${#audio_streams[@]}; i += 2)); do
        idx="${audio_streams[$i]}"
        lang="${audio_streams[$((i + 1))]}"
        if $has_eng_audio && [[ ! "$lang" =~ ^(eng|en|und|unk)$ ]]; then
            continue
        fi
        audio_indices+=("$idx")
    done

    subtitle_indices=()
    for ((i = 0; i < ${#subtitle_streams[@]}; i += 2)); do
        idx="${subtitle_streams[$i]}"
        lang="${subtitle_streams[$((i + 1))]}"
        if $has_eng_audio && [[ ! "$lang" =~ ^(eng|en|und|unk)$ ]]; then
            continue
        fi
        subtitle_indices+=("$idx")
    done

    audio_modified=false
    if [[ ${#audio_indices[@]} -ne $(( ${#audio_streams[@]} / 2 )) ]]; then
        audio_modified=true
    fi

    subtitle_modified=false
    if [[ ${#subtitle_indices[@]} -ne $(( ${#subtitle_streams[@]} / 2 )) ]]; then
        subtitle_modified=true
    fi

    debug "Audio indices (selected): ${audio_indices[*]}"
    debug "Subtitle indices (selected): ${subtitle_indices[*]}"
    debug "audio_modified=$audio_modified subtitle_modified=$subtitle_modified"

    #####################################################
    # Extract video/audio metadata
    #####################################################

    { IFS=$'\t' read -r vcodec vbitrate height color_transfer; read -r acodec; } < <(
        jq -r '
          (.streams[]
            | select(.codec_type=="video" and (.disposition.attached_pic != 1))
            | [.codec_name,
               (.bit_rate // .tags.BPS // 0 | tonumber),
               (.height // 0 | tonumber),
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

    debug "vcodec=$vcodec_lc vbitrate=$vbitrate acodec=$acodec"

    #####################################################
    # HARD SKIP AV1 (matches PowerShell)
    #####################################################

    if [[ "$vcodec_lc" =~ ^(av1|av01|libaom-av1|unknown)$ ]]; then
        echo "Skipping $f -- AV1 or unsupported codec detected ($vcodec_lc)"
        continue
    fi

    # UHD routing: >1100p stays at 2160p (encode in place, HDR passthrough);
    # 1080p and below encodes as-is. Movies is always progressive.
    is_uhd=false
    if (( height > 1100 )); then
        is_uhd=true
    fi

    # HDR detection: smpte2084 (HDR10) / arib-std-b67 (HLG)
    is_hdr=false
    if [[ "$color_transfer" =~ ^(smpte2084|arib-std-b67)$ ]]; then
        is_hdr=true
    fi

    debug "height=$height is_uhd=$is_uhd is_hdr=$is_hdr"

    # mov_text -> SRT: MP4 text subtitles cannot be stream-copied into MKV
    sub_codec_args=(-c:s copy)
    if [[ "$f" == *.mp4 ]]; then
        if jq -e '[.streams[] | select(.codec_type=="subtitle" and .codec_name=="mov_text")] | length > 0' <<< "$probe" >/dev/null 2>&1; then
            debug "Subtitle: mov_text detected in MP4 -- converting to SRT for MKV output"
            sub_codec_args=(-c:s srt)
        fi
    fi

    #####################################################
    # Scan type: Movies content is always progressive --
    # no telecine/interlace detection or filters needed.
    #####################################################

    status="progressive"

    #####################################################
    # Needs convert?
    #####################################################

    needs_convert=false
    [[ "$vcodec_lc" != "hevc" ]] && needs_convert=true
    (( vbitrate > 2500000 )) && needs_convert=true
    [[ "$acodec" != "aac" ]] && needs_convert=true
    debug "Needs convert: $needs_convert"
    if ! $needs_convert; then
        #####################################################
        # No transcode needed -- check for container problems
        #####################################################
        if [[ "$WANT_REMUX_CHECK" == "true" ]] && [[ "$acodec" == "aac" ]] && check_container_problem "$f"; then
            echo "Remuxing $f -> container repair"
            tmpfile="$dir/${base_no_ext}[Trans].tmp"

            rm -f -- "$tmpfile"

            run_ffmpeg -nostdin -hide_banner -threads 2 -y \
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
    # Build language-filtered map arguments
    #####################################################

    map_args=(
        -map "0:${v_index}"
    )

    for ai in "${audio_indices[@]}"; do
        map_args+=( -map "0:${ai}" )
    done

    if [[ ${#subtitle_indices[@]} -gt 0 ]]; then
        for si in "${subtitle_indices[@]}"; do
            map_args+=( -map "0:${si}" )
        done
    fi

    # Drop attached pictures (safe for VAAPI)
    map_args+=( -map -0:v:m:attached_pic )

    debug "Transcode path: PROGRESSIVE -> CPU decode + VAAPI encode"
    vf_args="format=nv12,hwupload"
    enc_profile_args=()
    enc_quality_args=(-rc_mode icq -qp 24)
    if $is_uhd && $is_hdr; then
        debug "UHD HDR -> 10-bit HEVC (main10, ICQ 24), HDR passthrough"
        vf_args="format=p010,hwupload"
        enc_profile_args=(-profile:v:0 main10)
    elif $is_uhd; then
        debug "UHD SDR -> 8-bit HEVC (ICQ 24)"
    else
        debug "1080p -> 8-bit HEVC (CQP 28)"
        enc_quality_args=(-qp 28)
    fi
    transcode_cmd=(
        run_ffmpeg -nostdin -hide_banner
        -vaapi_device /dev/dri/renderD128
        -i "$f"
        -vf "$vf_args"
        "${map_args[@]}"
        -c:v:0 hevc_vaapi
        "${enc_profile_args[@]}"
        "${enc_quality_args[@]}"
        -c:a aac
        -b:a 160k
        "${sub_codec_args[@]}"
        -f matroska
        "$tmpfile"
    )

    (
        # Run the chosen command
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
                    mkv_args=(mkvmerge -q -o "$strip_tmpfile" --language "${v_index}:zxx" --video-tracks "${v_index}")
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