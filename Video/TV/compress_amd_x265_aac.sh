#!/bin/bash

trap 'echo "Interrupted -- exiting safely"; exit 1' INT

#####################################################
# DEBUG MODE
#####################################################

DEBUG=false
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=true ;;
    esac
done

debug() { $DEBUG && echo "[DEBUG] $*"; }

MAX_JOBS=2

echo "Starting up..."
echo "Scanning for files..."

# Find all video files >= 1GB
mapfile -t files < <(
    find . -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.ts" \) -size +1G
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
    # Extract video/audio metadata
    #####################################################

    { IFS=$'\t' read -r vcodec vbitrate field_order r_frame_rate; read -r acodec; } < <(
        jq -r '
          (.streams[] | select(.codec_type=="video") |
            [.codec_name, (.bit_rate // 0), (.field_order // "unknown"), (.r_frame_rate // "0/1")] | @tsv),
          (.streams[] | select(.codec_type=="audio") |
            .codec_name)
        ' <<< "$probe"
    )

    vcodec_lc=$(echo "$vcodec" | tr '[:upper:]' '[:lower:]')

    debug "vcodec=$vcodec_lc vbitrate=$vbitrate field_order=$field_order r_frame_rate=$r_frame_rate acodec=$acodec"

    #####################################################
    # HARD SKIP AV1 (matches PowerShell)
    #####################################################

    if [[ "$vcodec_lc" =~ ^(av1|av01|libaom-av1|unknown)$ ]]; then
        echo "Skipping $f -- AV1 or unsupported codec detected ($vcodec_lc)"
        continue
    fi

    #####################################################
    # Fast remux path (HEVC + AAC + low bitrate)
    #####################################################

    can_remux=true
    [[ "$vcodec_lc" != "hevc" ]] && can_remux=false
    (( vbitrate > 2500000 )) && can_remux=false
    [[ "$acodec" != "aac" ]] && can_remux=false

    if $can_remux; then
        echo "Remuxing $f → HEVC/AAC under threshold"
        tmpfile="$dir/${base_no_ext}[Trans].tmp"

        rm -f -- "$tmpfile"

        ffmpeg -nostdin -hide_banner -y \
            -i "$f" \
            -map 0:v -map 0:a \
            -map "0:s:m:language:eng?" -map "0:s:m:language:und?" \
            -c copy \
            -f matroska \
            "$tmpfile"

        if [[ $? -eq 0 ]]; then
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")

            if (( new_size < orig_size )); then
                touch -r "$f" "$tmpfile"
                rm -f -- "$f"
                mv -- "$tmpfile" "$f"
                chown 1000:1000 "$f"
                chmod 666 "$f"
                echo "Replaced (remux): $((orig_size/1024/1024))MB → $((new_size/1024/1024))MB"
            else
                echo "Skipped (remux): new file not smaller"
                touch "$file_skip_file"
                rm -f -- "$tmpfile"
            fi
        else
            rm -f -- "$tmpfile"
        fi

        continue
    fi

    #####################################################
    # Interlace / telecine detection (mirrors PS1 Get-VideoInterlaceStatus)
    #####################################################

    status="progressive"

    # Fast pass: trust hard field_order flags (mirrors PS1 fast pass)
    if [[ "$field_order" =~ ^(tt|bb|tb|bt)$ ]]; then
        debug "Fast pass: hard interlace flag ($field_order)"
        status="interlaced"
    elif [[ "$field_order" == "progressive" ]]; then
        debug "Fast pass: flagged progressive"
        status="progressive"
    else
        # Slow pass: inspect frames (mirrors PS1 ffprobe -show_frames slow pass)
        echo "Running deep interlace/telecine scan..."

        # Parse r_frame_rate fraction (used for both NTSC and PAL range checks)
        fps_num="${r_frame_rate%%/*}"
        fps_den="${r_frame_rate##*/}"
        fps_scaled=0
        if [[ -n "$fps_num" && -n "$fps_den" && "$fps_den" -gt 0 ]]; then
            fps_scaled=$(( fps_num * 1000 / fps_den ))
        fi

        is_ntsc_rate=false
        (( fps_scaled >= 29000 && fps_scaled <= 31000 )) && is_ntsc_rate=true

        debug "r_frame_rate=$r_frame_rate fps_scaled=$fps_scaled is_ntsc_rate=$is_ntsc_rate"

        # Mirror PS1: ffprobe -show_frames at 300s window, fallback to start of file
        frames_json=$(ffprobe -v quiet -print_format json -show_frames \
            -select_streams v -read_intervals "300%+200" "$f" 2>/dev/null)

        if [[ -z "$frames_json" ]] || ! jq -e '.frames | length > 0' >/dev/null 2>&1 <<< "$frames_json"; then
            debug "Slow pass: 300s window empty, retrying from start of file"
            frames_json=$(ffprobe -v quiet -print_format json -show_frames \
                -select_streams v -read_intervals "%+200" "$f" 2>/dev/null)
        fi

        # Determine if this is PAL range (~25fps) - BBC/European broadcast content
        # often lacks interlaced_frame bitstream flags so needs idet pixel-level fallback
        is_pal_rate=false
        if [[ -n "$fps_num" && -n "$fps_den" && "$fps_den" -gt 0 ]]; then
            if (( fps_scaled >= 24500 && fps_scaled <= 25500 )); then
                is_pal_rate=true
            fi
        fi
        debug "is_pal_rate=$is_pal_rate"

        if [[ -n "$frames_json" ]] && jq -e '.' >/dev/null 2>&1 <<< "$frames_json"; then
            total_frames=$(jq '[.frames[]] | length' <<< "$frames_json")
            interlaced_frames=$(jq '[.frames[] | select(.interlaced_frame==1)] | length' <<< "$frames_json")
            debug "Slow pass: total=$total_frames interlaced=$interlaced_frames"

            if (( total_frames > 0 && interlaced_frames > 0 )); then
                ratio=$(( interlaced_frames * 100 / total_frames ))
                debug "Interlaced frame ratio: ${ratio}%"
                # Telecine: ~29.97fps source with mixed interlaced/progressive frames
                # (3:2 pulldown produces ~40-60% interlaced frames; true interlace >= ~80%)
                if $is_ntsc_rate && (( ratio < 80 )); then
                    status="telecine"
                else
                    status="interlaced"
                fi
            else
                # No interlaced_frame flags found. BBC/PAL broadcast content commonly omits
                # these flags even when the content is true 50i. Fall through to idet below.
                status="progressive"
            fi
        else
            # ffprobe frames scan failed - mirror PS1 "unknown" fallback
            debug "Slow pass: ffprobe frames scan failed"
            status="unknown"
        fi

        # idet fallback for PAL-range content that reported no interlaced_frame flags:
        # BBC 50i is often encoded without bitstream interlace markers so ffprobe misses it.
        # idet analyzes actual pixel field patterns and reliably catches it.
        if [[ "$status" == "progressive" ]] && $is_pal_rate; then
            debug "PAL-range content reported progressive - running idet pixel analysis..."
            echo "Running idet pixel analysis for PAL content..."

            idet_out=$(ffmpeg -nostdin -hide_banner \
                -i "$f" \
                -vf idet \
                -frames:v 200 \
                -an -f null /dev/null 2>&1)

            # Parse Multi frame detection counts (more reliable than Single frame)
            idet_tff=$(echo "$idet_out" | grep -oP 'Multi frame detection: TFF:\s*\K[0-9]+' | tail -n1)
            idet_bff=$(echo "$idet_out" | grep -oP 'BFF:\s*\K[0-9]+'                       | tail -n1)
            idet_prog=$(echo "$idet_out" | grep -oP 'Progressive:\s*\K[0-9]+'              | tail -n1)

            [[ -z "$idet_tff"  ]] && idet_tff=0
            [[ -z "$idet_bff"  ]] && idet_bff=0
            [[ -z "$idet_prog" ]] && idet_prog=0

            idet_interlaced=$(( idet_tff + idet_bff ))
            idet_total=$(( idet_interlaced + idet_prog ))

            debug "idet multi: TFF=$idet_tff BFF=$idet_bff Progressive=$idet_prog"

            if (( idet_total > 0 && idet_interlaced * 100 / idet_total >= 30 )); then
                debug "idet detected interlace in PAL content"
                status="interlaced"
            else
                debug "idet confirmed progressive"
            fi
        fi
    fi

    echo "Detected: $status"

    #####################################################
    # Needs convert?
    #####################################################

    needs_convert=false
    [[ "$acodec" != "aac" ]] && needs_convert=true
    [[ "$vcodec_lc" != "hevc" ]] && needs_convert=true
    (( vbitrate > 2500000 )) && needs_convert=true
    [[ "$status" != "progressive" ]] && needs_convert=true

    if ! $needs_convert; then
        echo "Skipping $f -- already in desired format"
        continue
    fi

    #####################################################
    # Filter chain (PS1 parity)
    #####################################################

    case "$status" in
        interlaced)
            # True interlace: bwdif deinterlace to progressive (mirrors PS1 deinterlace=slower)
            vf_chain="hwdownload,format=yuv420p,bwdif=mode=send_frame,format=nv12,hwupload"
            ;;
        telecine)
            # 3:2 pulldown (NTSC telecine): IVTC back to original ~23.976fps progressive
            # fieldmatch reconstructs fields, yadif cleans residual combing, decimate removes duplicates
            # (mirrors PS1 --detelecine --deinterlace=slower)
            vf_chain="hwdownload,format=yuv420p,fieldmatch=order=tff:combmatch=full,yadif=deint=interlaced,decimate,format=nv12,hwupload"
            ;;
        unknown)
            # ffprobe scan failed - conservative fallback: bwdif handles both interlaced and
            # most telecine content safely without risking wrong frame drops
            vf_chain="hwdownload,format=yuv420p,bwdif=mode=send_frame,format=nv12,hwupload"
            ;;
        progressive)
            vf_chain="hwdownload,format=yuv420p,format=nv12,hwupload"
            ;;
    esac

    #####################################################
    # Transcode
    #####################################################

    tmpfile="$dir/${base_no_ext}[Trans].tmp"

    rm -f -- "$tmpfile"

    (
        ffmpeg -nostdin -hide_banner \
            -vaapi_device /dev/dri/renderD128 \
            -hwaccel vaapi \
            -hwaccel_output_format vaapi \
            -i "$f" \
            -map 0:v:0 -map 0:a \
            -map "0:s:m:language:eng?" -map "0:s:m:language:und?" \
            -vf "$vf_chain" \
            -c:v hevc_vaapi \
            -qp 24 \
            -c:a aac -b:a 160k \
            -c:s copy \
            -f matroska \
            "$tmpfile"

        if [[ $? -eq 0 ]]; then
            orig_size=$(stat -c%s "$f")
            new_size=$(stat -c%s "$tmpfile")

            if (( new_size < orig_size )); then
                touch -r "$f" "$tmpfile"
                rm -f -- "$f"
                mv -- "$tmpfile" "$f"
                chown 1000:1000 "$f"
                chmod 666 "$f"
                echo "Replaced: $((orig_size/1024/1024))MB → $((new_size/1024/1024))MB"
            else
                echo "Skipped: new file not smaller"
                touch "$file_skip_file"
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
# Cleanup (PowerShell‑parity: only remove true leftovers)
#####################################################

echo "Cleaning up leftover [Trans] files..."

find . -type f -regex '.*\[Trans\]\.tmp$' -delete
find . -type f -regex '.*\[Trans\]\.nfo$' -delete
find . -type f -regex '.*\[Trans\]\.jpg$' -delete
find . -type d -regex '.*\[Trans\]\.trickplay$' -exec rm -rf {} +

echo "All tasks complete."

