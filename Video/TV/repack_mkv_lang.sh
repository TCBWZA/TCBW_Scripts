#!/bin/bash

###############################################################
# PRE-FLIGHT CHECKS
###############################################################
for tool in mkvmerge ffprobe jq; do
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
        debug "Cleaning up temp files..."
        for file in "${temp_files[@]}"; do
            rm -f "$file" 2>/dev/null
        done
    fi
}
trap 'echo "Interrupted -- exiting safely"; cleanup; exit 1' INT TERM
trap 'cleanup' EXIT

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

echo "Starting up..."
echo "Scanning for files..."

mapfile -t files < <(
    find . -type f -iname "*.mkv"
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

    #####################################################
    # Track selection (mirrors compress_lang language rules)
    #####################################################

    # Primary video stream (first non-attached-picture video)
    v_index=$(jq -r '
      first((.streams[]
        | select(.codec_type=="video" and (.disposition.attached_pic != 1))
        | .index))
    ' <<< "$probe")

    if [[ "$v_index" == "null" || -z "$v_index" ]]; then
        echo "Skipping $f -- no primary video stream found"
        touch "$file_skip_file"
        continue
    fi

    video_count=$(jq '[.streams[] | select(.codec_type=="video")] | length' <<< "$probe")
    attached_count=$(jq '[.streams[] | select(.codec_type=="video" and .disposition.attached_pic==1)] | length' <<< "$probe")

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

    # When an English/undefined/unknown audio track exists, keep only those
    # languages; otherwise (foreign-only content) keep every track.
    has_eng_audio=false
    for ((i = 1; i < ${#audio_streams[@]}; i += 2)); do
        if [[ "${audio_streams[$i]}" =~ ^(eng|en|und|unk)$ ]]; then
            has_eng_audio=true
            break
        fi
    done

    audio_sel=()
    audio_all=()
    for ((i = 0; i < ${#audio_streams[@]}; i += 2)); do
        idx="${audio_streams[$i]}"
        lang="${audio_streams[$((i + 1))]}"
        audio_all+=("$idx")
        if $has_eng_audio && [[ ! "$lang" =~ ^(eng|en|und|unk)$ ]]; then
            continue
        fi
        audio_sel+=("$idx")
    done

    sub_sel=()
    sub_all=()
    for ((i = 0; i < ${#subtitle_streams[@]}; i += 2)); do
        idx="${subtitle_streams[$i]}"
        lang="${subtitle_streams[$((i + 1))]}"
        sub_all+=("$idx")
        if $has_eng_audio && [[ ! "$lang" =~ ^(eng|en|und|unk)$ ]]; then
            continue
        fi
        sub_sel+=("$idx")
    done

    debug "has_eng_audio=$has_eng_audio video=$v_index audio_sel=${audio_sel[*]} sub_sel=${sub_sel[*]}"

    # Fast path: no filtering, no attached pictures, single video -> nothing to do
    if (( attached_count == 0 )) && (( video_count == 1 )) \
        && [[ "${#audio_sel[@]}" -eq "${#audio_all[@]}" ]] \
        && [[ "${#sub_sel[@]}" -eq "${#sub_all[@]}" ]]; then
        echo "Skipping $f -- all tracks already kept"
        continue
    fi

    audio_ids=$(IFS=,; echo "${audio_sel[*]}")
    sub_ids=$(IFS=,; echo "${sub_sel[*]}")

    #####################################################
    # REPACK WITH MKVMERGE
    #####################################################

    tmp="$dir/${base_no_ext}[Repack].tmp"
    temp_files+=("$tmp")
    rm -f "$tmp"

    # ponytail: assumes ffprobe stream index == mkvmerge track id (Matroska track
    # order); revisit if mkvmerge ever reports a differing id for a file.
    mkvmerge_args=(-o "$tmp" --video-tracks "$v_index")
    if [[ -n "$audio_ids" ]]; then
        mkvmerge_args+=(--audio-tracks "$audio_ids")
    fi
    if [[ -n "$sub_ids" ]]; then
        mkvmerge_args+=(--subtitle-tracks "$sub_ids")
    fi
    mkvmerge_args+=("$f")

    debug "mkvmerge ${mkvmerge_args[*]}"
    mkvmerge "${mkvmerge_args[@]}"
    status=$?

    if (( status > 1 )) || [[ ! -s "$tmp" ]]; then
        echo "Skipping $f -- mkvmerge failed (exit $status)"
        rm -f "$tmp"
        continue
    fi

    #####################################################
    # ATOMIC REPLACEMENT
    #####################################################

    orig_size=$(stat -c %s "$f")
    new_size=$(stat -c %s "$tmp")

    touch -r "$f" "$tmp"
    chown 1000:1000 "$tmp" 2>/dev/null
    chmod 666 "$tmp"
    mv -f "$tmp" "$f"

    orig_mb=$(awk "BEGIN{printf \"%.2f\", $orig_size/1048576}")
    new_mb=$(awk "BEGIN{printf \"%.2f\", $new_size/1048576}")
    echo "Repacked: ${orig_mb}MB -> ${new_mb}MB"
done

echo "All tasks complete."