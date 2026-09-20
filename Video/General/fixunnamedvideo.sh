#!/usr/bin/env bash
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

# -------- Helpers --------
vid_ext='\( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.m4v" -o -iname "*.wmv" -o -iname "*.ts" -o -iname "*.m2ts" -o -iname "*.webm" -o -iname "*.flv" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.vob" -o -iname "*.ogv" -o -iname "*.3gp" -o -iname "*.rmvb" \)'

noext_files() {
    find "$1" -maxdepth 1 -type f ! -name "*.*" ! -name ".*" 2>/dev/null
}

video_files() {
    eval "find \"$1\" -maxdepth 1 -type f $vid_ext 2>/dev/null"
}

# -------- Build suffix find args --------
suffix_args=()
for i in "${!SUFFIXES[@]}"; do
    [[ $i -gt 0 ]] && suffix_args+=("-o")
    suffix_args+=(-name "*${SUFFIXES[$i]}")
done

# -------- Main scan --------
echo "Scanning $ROOT for folders ending in: ${SUFFIXES[*]}"

find "$ROOT" -type d \( "${suffix_args[@]}" \) 2>/dev/null | while IFS= read -r dir; do
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
    target="$dir/$dname.mkv"

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
done
