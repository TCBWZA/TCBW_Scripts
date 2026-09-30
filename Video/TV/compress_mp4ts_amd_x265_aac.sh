#!/bin/bash

# Convert MP4/TS video files to Matroska for TV/episode content.
# Focus is the container and the video codec only: audio and subtitles are
# stream-copied as-is, with no language filtering. Files are processed
# regardless of size, and the MKV result replaces the source even when it is
# larger than the original.

# Only nounset and pipefail are enabled here. Do not add a preceding
# option-reset line: these scripts run as fresh bash processes that
# never inherit errexit, and the historical combined reset spelling is
# read by bash as a bare +o, which prints every shell option instead
# of clearing one -- that dump breaks the Proxmox console.
set -u -o pipefail

###############################################################
# PRE-FLIGHT CHECKS
###############################################################
for tool in ffprobe ffmpeg jq; do
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
        for file in "${temp_files[@]}"; do
            rm -f "$file" 2>/dev/null
        done
    fi
}
trap 'interrupted=1; cleanup; exit 1' INT TERM
trap 'if [[ ${interrupted:-0} -eq 1 ]]; then echo "Interrupted -- exiting safely"; fi; cleanup' EXIT

#####################################################
# DEBUG MODE
#####################################################

DEBUG=false
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=true ;;
    esac
done

# if rather than && on the last statement: a false short-circuit makes the
# function return 1, and callers chain this as
# "cmd && debug '...' || echo Warning", so a 1 here turned every successful
# metadata apply into a false "metadata apply failed" warning.
debug() { if [[ "$DEBUG" == true ]]; then echo "[DEBUG] $*"; fi; }

#####################################################
# Allow nice to be used without breaking exit code
#####################################################

run_ffmpeg() {
    nice -n 10 ionice -c3 ffmpeg "$@"
    return $?
}

#####################################################
# COMMIT: move the result into place, drop the source last
#####################################################

commit_as_mkv() {
    local tmp_file="$1" src_file="$2" dest_file
    if [[ "$src_file" == *.mkv ]]; then
        dest_file="$src_file"
    else
        dest_file="${src_file%.*}.mkv"
        if [[ -e "$dest_file" ]]; then
            echo "ERROR: target exists, refusing to overwrite: $dest_file" >&2
            return 1
        fi
    fi
    touch -r "$src_file" "$tmp_file"
    mv -- "$tmp_file" "$dest_file" || return 1
    [[ "$dest_file" == "$src_file" ]] || rm -f -- "$src_file"
    chown 1000:1000 "$dest_file" 2>/dev/null
    chmod 666 "$dest_file" 2>/dev/null
    # The committed path is the caller's only route to the file just written,
    # and the metadata pass is given exactly that file. Diagnostics stay on
    # stderr so they cannot be captured as the path by the caller.
    printf '%s\n' "$dest_file"
    return 0
}

#####################################################
# Verify the produced MKV before it replaces the source
#
# There is no size gate on this script, so nothing about the
# output is allowed to be assumed: it must exist, hold exactly
# one real video stream, and have a positive duration.
#####################################################

verify_output() {
    local path="$1"

    if [[ ! -s "$path" ]]; then
        debug "Verify failed: output missing or empty"
        return 1
    fi

    local probe_json
    probe_json=$(ffprobe -v quiet -print_format json -show_streams "$path" 2>/dev/null)
    if ! jq -e . >/dev/null 2>&1 <<< "$probe_json"; then
        debug "Verify failed: ffprobe returned invalid JSON for output"
        return 1
    fi

    local vcount
    vcount=$(jq '[.streams[] | select(.codec_type=="video" and (.disposition.attached_pic != 1))] | length' <<< "$probe_json")
    if [[ "$vcount" != "1" ]]; then
        debug "Verify failed: expected 1 video stream, found ${vcount:-0}"
        return 1
    fi

    local duration
    duration=$(ffprobe -v quiet -show_entries format=duration -of default=nw=1:nk=1 "$path" 2>/dev/null)
    if [[ -z "$duration" ]]; then
        debug "Verify failed: no duration reported for output"
        return 1
    fi
    if ! awk -v d="$duration" 'BEGIN { exit !(d + 0 > 0) }'; then
        debug "Verify failed: non-positive duration ($duration)"
        return 1
    fi

    debug "Verify OK: 1 video stream, duration=$duration"
    return 0
}

#####################################################
# Report the size change, flagging growth explicitly
#
# This script replaces unconditionally, so a larger result is
# a normal outcome rather than a reason to hold on to the source.
# Sizes are formatted by magnitude: plain integer MB always
# printed 0MB for sub-megabyte inputs, which hid a change that
# had actually been made.
#####################################################

human_size() {
    local b="$1"
    if (( b >= 1073741824 )); then
        awk -v v="$b" 'BEGIN { printf "%.1fGB", v / 1073741824 }'
    elif (( b >= 1048576 )); then
        awk -v v="$b" 'BEGIN { printf "%.1fMB", v / 1048576 }'
    else
        awk -v v="$b" 'BEGIN { printf "%.1fKB", v / 1024 }'
    fi
}

report_size_change() {
    local orig_size="$1" new_size="$2" mode="$3"
    local before after
    before=$(human_size "$orig_size")
    after=$(human_size "$new_size")
    if (( new_size > orig_size )); then
        echo "Replaced ($mode): $before -> $after (larger, replaced as required)"
    else
        echo "Replaced ($mode): $before -> $after"
    fi
}

#####################################################
# Apply episode metadata to the committed MKV
#####################################################

apply_episode_metadata() {
    local target_file="$1"
    local script_dir
    script_dir="$(dirname -- "$(realpath -- "$0")")"
    # Same-directory reference: deploy ships apply-metadata.sh alongside this
    # script, so the call is independent of the repo vs live folder layout.
    # The committed file is passed explicitly and no cd is needed: it is the
    # only file this run produced, and a directory scan would re-inspect every
    # sibling episode, which is O(n^2) across a season and races a parallel
    # worker onto the same file.
    local metadata_script="$script_dir/apply-metadata.sh"

    if [[ -x "$metadata_script" ]]; then
        bash "$metadata_script" "$target_file" \
            && debug "Metadata applied OK" \
            || echo "Warning: metadata apply failed on $target_file"
    else
        debug "apply-metadata.sh not found or not executable at $metadata_script -- skipping"
    fi
}

#####################################################
# Subtitle handling
#
# Matroska cannot carry MP4 text subtitles (mov_text), so they
# are transcoded to SubRip. Subtitle codecs Matroska also
# cannot represent (DVB/teletext, for example) are dropped with
# a message rather than failing the whole remux.
#####################################################

# Codecs that stream-copy cleanly into Matroska.
is_mkv_copyable_sub() {
    case "$1" in
        subrip|srt|ass|ssa|webvtt|hdmv_pgs_subtitle|dvd_subtitle|text) return 0 ;;
        *) return 1 ;;
    esac
}

MAX_JOBS=2

echo "Starting up..."
echo "Scanning for MP4 and TS files..."

# MP4 and TS only, any size, trailers excluded.
mapfile -t files < <(
    find . -type f \( -iname "*.mp4" -o -iname "*.ts" \) ! -iname "*-trailer.*" ! -iname "*-behindthescenes.*" ! -iname "*-featurette.*" ! -iname "*-interview.*" ! -iname "*-scene.*" ! -iname "*-short.*" ! -iname "*-deleted.*" ! -iname "*-sample.*" ! -ipath '*/behind the scenes/*' ! -ipath '*/deleted scenes/*' ! -ipath '*/interviews/*' ! -ipath '*/scenes/*' ! -ipath '*/samples/*' ! -ipath '*/shorts/*' ! -ipath '*/featurettes/*' ! -ipath '*/clips/*' ! -ipath '*/other/*' ! -ipath '*/extras/*' ! -ipath '*/trailers/*' ! -ipath '*/theme-music/*' ! -ipath '*/backdrops/*'
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
    # Skip and delete leftover transcoded files
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

    probe=$(ffprobe -v quiet -print_format json -show_format -show_streams "$f" 2>/dev/null)

    if ! jq -e . >/dev/null 2>&1 <<< "$probe"; then
        echo "Skipping $f -- ffprobe returned invalid JSON"
        continue
    fi

    debug "ffprobe JSON OK"

    #####################################################
    # CONTAINER HEALTH (light)
    #
    # The full demux pass the compress scripts use is skipped
    # here: every output is produced by reading the source, so a
    # broken source fails the ffmpeg run and the source is kept.
    #####################################################

    start_time=$(jq -r '.format.start_time // "N/A"' <<< "$probe")
    if [[ "$start_time" == "N/A" ]]; then
        echo "Skipping $f -- container has no start_time"
        touch "$file_skip_file"
        continue
    fi

    source_duration=$(jq -r '.format.duration // "N/A"' <<< "$probe")
    if [[ "$source_duration" == "N/A" ]]; then
        echo "Skipping $f -- container has no duration"
        touch "$file_skip_file"
        continue
    fi
    if ! awk -v d="$source_duration" 'BEGIN { exit !(d + 0 > 0) }'; then
        echo "Skipping $f -- container duration is not positive ($source_duration)"
        touch "$file_skip_file"
        continue
    fi

    #####################################################
    # Primary video stream (first non-attached video)
    #####################################################

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

    #####################################################
    # ALL audio streams, no language filtering
    #####################################################

    audio_indices=()
    while IFS= read -r idx; do
        audio_indices+=("$idx")
    done < <(jq -r '.streams[] | select(.codec_type=="audio") | .index' <<< "$probe")

    if [[ ${#audio_indices[@]} -eq 0 ]]; then
        echo "Skipping $f -- no audio stream found (left in place for findcorrupt to handle)"
        touch "$file_skip_file"
        continue
    fi

    debug "Audio indices (all kept): ${audio_indices[*]}"

    #####################################################
    # ALL subtitle streams, codec decided per stream
    #####################################################

    subtitle_indices=()
    subtitle_codecs=()
    dropped_subs=()

    while IFS=$'\t' read -r idx codec; do
        if is_mkv_copyable_sub "$codec"; then
            subtitle_indices+=("$idx")
            subtitle_codecs+=("copy")
        elif [[ "$codec" == "mov_text" ]]; then
            debug "Subtitle stream $idx: mov_text -> srt for Matroska"
            subtitle_indices+=("$idx")
            subtitle_codecs+=("srt")
        else
            debug "Subtitle stream $idx: $codec cannot go into Matroska -- dropping"
            dropped_subs+=("$idx:$codec")
        fi
    done < <(jq -r '.streams[] | select(.codec_type=="subtitle") | [.index, .codec_name] | @tsv' <<< "$probe")

    if [[ ${#dropped_subs[@]} -gt 0 ]]; then
        echo "  Note: dropped ${#dropped_subs[@]} subtitle track(s) Matroska cannot hold: ${dropped_subs[*]}"
    fi

    debug "Subtitle indices (kept): ${subtitle_indices[*]:-none}"
    debug "Subtitle codecs: ${subtitle_codecs[*]:-none}"

    #####################################################
    # Per-output-stream subtitle codec arguments
    #####################################################

    sub_codec_args=()
    if [[ ${#subtitle_indices[@]} -gt 0 ]]; then
        for ((s = 0; s < ${#subtitle_indices[@]}; s++)); do
            sub_codec_args+=( -c:s:"$s" "${subtitle_codecs[$s]}" )
        done
    fi

    #####################################################
    # Extract video metadata
    #
    # Scalar values are read as [<stream>] | .[0] rather than a
    # bare stream: jq 1.7 rejects first/last on a scalar stream,
    # and a bare stream would join multiple matches with newlines.
    #####################################################

    vcodec=$(jq -r '
        [ .streams[]
          | select(.codec_type=="video" and (.disposition.attached_pic != 1))
          | .codec_name ] | .[0] // "unknown"
    ' <<< "$probe")
    vbitrate=$(jq -r '
        [ .streams[]
          | select(.codec_type=="video" and (.disposition.attached_pic != 1))
          | (.bit_rate // .tags.BPS // 0 | tonumber) ] | .[0] // 0
    ' <<< "$probe")
    field_order=$(jq -r '
        [ .streams[]
          | select(.codec_type=="video" and (.disposition.attached_pic != 1))
          | (.field_order // "unknown") ] | .[0] // "unknown"
    ' <<< "$probe")
    height=$(jq -r '
        [ .streams[]
          | select(.codec_type=="video" and (.disposition.attached_pic != 1))
          | (.height // 0) ] | .[0] // 0
    ' <<< "$probe")

    if [[ -z "$vcodec" || "$vcodec" == "null" ]]; then
        echo "Skipping $f -- could not read video codec"
        touch "$file_skip_file"
        continue
    fi

    vcodec_lc=$(echo "$vcodec" | tr '[:upper:]' '[:lower:]')

    debug "vcodec=$vcodec_lc vbitrate=$vbitrate height=$height field_order=$field_order"

    #####################################################
    # HARD SKIP AV1 (matches the compress family)
    #####################################################

    if [[ "$vcodec_lc" =~ ^(av1|av01|libaom-av1|unknown)$ ]]; then
        echo "Skipping $f -- AV1 or unsupported codec detected ($vcodec_lc)"
        continue
    fi

    #####################################################
    # NEEDS CONVERT?
    #
    # Required format is HEVC, progressive, at or below 2.5Mbps.
    # The audio codec is deliberately NOT part of this test:
    # audio is stream-copied, so re-encoding to satisfy a codec
    # check would change nothing that the remux does not.
    #####################################################

    needs_convert=false
    [[ "$vcodec_lc" != "hevc" ]] && needs_convert=true
    (( vbitrate > 2500000 )) && needs_convert=true

    #####################################################
    # INTERLACE / TELECINE DETECTION (TV parity)
    #####################################################

    status="progressive"

    if [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        status="interlaced"
    elif [[ "$field_order" != "progressive" ]] && $needs_convert; then
        echo "Running deep interlace/telecine scan..."

        idet_output=$(
            ffmpeg -nostdin -hide_banner \
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

    [[ "$status" != "progressive" ]] && needs_convert=true

    debug "Needs convert: $needs_convert (status=$status)"

    #####################################################
    # Build stream maps (shared by both paths)
    #####################################################

    map_args=( -map "0:${v_index}" )
    for ai in "${audio_indices[@]}"; do
        map_args+=( -map "0:${ai}" )
    done
    for si in "${subtitle_indices[@]}"; do
        map_args+=( -map "0:${si}" )
    done

    # Drop attached pictures (safe for VAAPI)
    map_args+=( -map -0:v:m:attached_pic )

    # Video carries no linguistic content
    map_args+=( -metadata:s:v:0 language=zxx )

    tmpfile="$dir/${base_no_ext}[Trans].tmp"
    temp_files+=("$tmpfile")
    rm -f -- "$tmpfile"

    #####################################################
    # Already compliant: remux, never re-encode
    #####################################################

    if ! $needs_convert; then
        echo "Remuxing $f -> MKV (stream copy, already HEVC)"

        run_ffmpeg -nostdin -hide_banner -threads 2 -y \
            -i "$f" \
            "${map_args[@]}" \
            -c:v copy \
            -c:a copy \
            "${sub_codec_args[@]}" \
            -f matroska \
            "$tmpfile"

        if [[ $? -ne 0 || ! -f "$tmpfile" ]]; then
            echo "Failed: $f"
            rm -f -- "$tmpfile"
            continue
        fi

        if ! verify_output "$tmpfile"; then
            echo "Failed: $f -- remux output did not verify, source kept"
            rm -f -- "$tmpfile"
            continue
        fi

        orig_size=$(stat -c%s "$f")
        new_size=$(stat -c%s "$tmpfile")

        if dest=$(commit_as_mkv "$tmpfile" "$f"); then
            report_size_change "$orig_size" "$new_size" "remux"
            apply_episode_metadata "$dest"
        else
            rm -f -- "$tmpfile"
        fi

        continue
    fi

    echo "Detected: $status"

    #####################################################
    # Transcode: CPU filter chain + VAAPI HEVC encode
    #####################################################

    case "$status" in

        progressive)
            debug "Transcode path: PROGRESSIVE -> CPU decode + VAAPI encode (fast path)"
            vf_args="format=nv12,hwupload"
            ;;

        interlaced)
            debug "Transcode path: INTERLACED -> CPU bwdif + VAAPI encode"
            vf_args="bwdif=mode=send_frame,format=nv12,hwupload"
            ;;

        telecine)
            debug "Transcode path: TELECINE -> CPU pullup/dejudder + VAAPI encode"
            vf_args="pullup,dejudder,format=nv12,hwupload"
            ;;
    esac

    debug "Transcode: QP 28, all ${#audio_indices[@]} audio and ${#subtitle_indices[@]} subtitle stream(s) copied"

    transcode_cmd=(
        run_ffmpeg -nostdin -hide_banner
        -vaapi_device /dev/dri/renderD128
        -i "$f"
        -vf "$vf_args"
        "${map_args[@]}"
        -c:v:0 hevc_vaapi
        -qp 28
        -c:a copy
        "${sub_codec_args[@]}"
        -f matroska
        "$tmpfile"
    )

    (
        "${transcode_cmd[@]}"
        rc=$?

        if [[ $rc -ne 0 || ! -f "$tmpfile" ]]; then
            echo "Failed: $f"
            rm -f -- "$tmpfile"
        elif ! verify_output "$tmpfile"; then
            echo "Failed: $f -- transcode output did not verify, source kept"
            rm -f -- "$tmpfile"
        else
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")
            if dest=$(commit_as_mkv "$tmpfile" "$f"); then
                report_size_change "$orig_size" "$new_size" "transcode"
                apply_episode_metadata "$dest"
            else
                rm -f -- "$tmpfile"
            fi
        fi
    ) &

    while (( $(jobs -r | wc -l) >= MAX_JOBS )); do
        wait -n
    done

done

wait

#####################################################
# CLEANUP
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . -type f -regex '.*\[Trans\]\.tmp$' -delete

echo "All tasks complete."
