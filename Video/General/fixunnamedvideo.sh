#!/usr/bin/env bash
set -uo pipefail
# ============================================================
#  Rename extension-less download files to <dirname>.mkv
#
#  Scenario: a completed torrent folder holds a single video
#  file whose extension was stripped by the release platform
#  (e.g. the file is just a random token with no dot).  For
#  every folder under the download root whose name ends in
#  any of the release-group suffixes (default: AnoZu): if
#  the folder holds exactly one file with no extension and
#  no video files at all, that file is renamed to <dirname>.mkv.
#
#  A name with no dot cannot tell a stripped video apart from
#  a stray text file, a checksum, or a truncated download, so the
#  candidate is probed with ffprobe first and skipped unless it
#  has a video stream and a positive duration.
#
#  Flags:
#      -r|--root <dir>       folder root to scan
#                            (default /main/downloads/completed/Series)
#      --suffix <text>       folder-name suffix to match; repeatable
#                            (default: AnoZu)
#      --audit               print what would be renamed, change nothing
#      -d|--debug            verbose output
#
#  Run from an ssh session on the Proxmox host.
# ============================================================

# -------- Defaults --------
ROOT="/main/downloads/completed/Series"
SUFFIXES=("AnoZu")
AUDIT=0
DEBUG=false

debug() { $DEBUG && echo "[DEBUG] $*" >&2; }

# -------- Argument Parsing --------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--root)
            ROOT="$2"
            shift 2
            ;;
        --suffix)
            SUFFIXES+=("$2")
            shift 2
            ;;
        --audit)
            AUDIT=1
            shift
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# -------- Parameter Validation --------
if [[ ! -d "$ROOT" ]]; then
    echo "ERROR: root path does not exist or is not a directory: $ROOT"
    exit 1
fi

# Required rather than optional: without ffprobe the video check below cannot
# run, and silently renaming unprobed files would defeat the point of the gate.
if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ERROR: ffprobe not found on PATH; refusing to rename unprobed files"
    exit 1
fi

# -------- Helpers --------
video_files() {
    find "$1" -maxdepth 1 -type f \( \
        -iname "*.mkv"  -o -iname "*.mp4"  -o -iname "*.avi"  -o -iname "*.mov" \
        -o -iname "*.m4v"  -o -iname "*.wmv"  -o -iname "*.ts"   -o -iname "*.m2ts" \
        -o -iname "*.webm" -o -iname "*.flv"  -o -iname "*.mpg"  -o -iname "*.mpeg" \
        -o -iname "*.vob"  -o -iname "*.ogv"  -o -iname "*.3gp"  -o -iname "*.rmvb" \
        \) 2>/dev/null
}

noext_files() {
    find "$1" -maxdepth 1 -type f ! -name "*.*" ! -name ".*" 2>/dev/null
}

# A stripped extension leaves no clue in the name, so confirm the bytes are
# actually a video before the rename. Two conditions, both required:
#   - ffprobe reports at least one video stream, and
#   - the container reports a positive duration.
# The duration test is what separates a real file from a truncated or
# placeholder download that still parses as a stream header. Failures are
# treated as "not a video": the cost of a false negative is a skipped rename
# someone re-runs by hand, while a false positive is a .mkv that is not video.
probe_reason() {
    local path="$1" json duration
    json=$(ffprobe -v quiet -print_format json -show_format -show_streams "$path" 2>/dev/null)
    if [[ -z "$json" ]]; then
        printf 'ffprobe produced no output (not a media file?)'
        return 1
    fi
    if ! echo "$json" | jq -e '[.streams[]? | select(.codec_type=="video")] | length > 0' >/dev/null 2>&1; then
        printf 'no video stream (audio, subtitle or data only?)'
        return 1
    fi
    duration=$(echo "$json" | jq -r '.format.duration // "N/A"')
    if [[ "$duration" == "N/A" ]] || ! [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || (( $(printf '%s' "$duration" | cut -d. -f1) < 1 )); then
        printf 'duration is %s (empty or truncated download?)' "$duration"
        return 1
    fi
    return 0
}

# -------- Build suffix find args --------
suffix_args=()
for i in "${!SUFFIXES[@]}"; do
    [[ $i -gt 0 ]] && suffix_args+=("-o")
    suffix_args+=(-name "*${SUFFIXES[$i]}")
done

# Matroska is the fixed target container; the name is never taken from the input extension.
target_ext=".mkv"

# -------- Main scan --------
echo "Scanning $ROOT for folders ending in: ${SUFFIXES[*]}"

# Process substitution, not a pipe: a piped while discards the state it sets.
while IFS= read -r dir; do
    dname=$(basename "$dir")

    vids=$(video_files "$dir")
    if [[ -n "$vids" ]]; then
        debug "skip $dir -- video file(s) present"
        continue
    fi

    noexts=$(noext_files "$dir")
    [[ -z "$noexts" ]] && continue

    noext_n=$(printf '%s\n' "$noexts" | grep -c .)
    if [[ $noext_n -ne 1 ]]; then
        echo "SKIP: $dir -- $noext_n extension-less files, ambiguous"
        continue
    fi

    noext="$noexts"
    target="$dir/$dname$target_ext"

    if ! reason=$(probe_reason "$noext"); then
        echo "SKIP: $dir -- $noext is not a video: $reason"
        debug "probe rejected: $noext ($reason)"
        continue
    fi
    debug "probe passed: $noext"

    if [[ $AUDIT -eq 1 ]]; then
        echo "[AUDIT] would rename: $noext -> $target"
        continue
    fi

    if [[ -e "$target" ]]; then
        echo "SKIP: $dir -- target already exists: $target"
        continue
    fi

    mv -n "$noext" "$target"
    if [[ $? -eq 0 && -f "$target" ]]; then
        echo "Renamed: $noext -> $target"
    else
        echo "ERROR: rename failed: $noext -> $target"
    fi
done < <(find "$ROOT" -type d \( "${suffix_args[@]}" \) 2>/dev/null)
