#!/usr/bin/env bash

set -u -o pipefail

BASE_DIR="."
DELETE_MODE=0
DEBUG_MODE=0

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete)
            DELETE_MODE=1
            shift
            ;;
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        *)
            BASE_DIR="$1"
            shift
            ;;
    esac
done

debug() {
    [[ $DEBUG_MODE -eq 1 ]] && echo "[DEBUG] $*"
}

# Match every audio media file directly inside a folder.
AUDIO_MATCH=( -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.m4b' \
    -o -iname '*.m4a' -o -iname '*.flac' -o -iname '*.ogg' \
    -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aac' \
    -o -iname '*.wma' \) )

audio_files() {
    find "$1" "${AUDIO_MATCH[@]}"
}

zero_audio_files() {
    find "$1" "${AUDIO_MATCH[@]}" -size 0c
}

# Non-empty lines in a captured command's output.
count_nonempty() {
    printf '%s\n' "$1" | grep -c .
}

# Highest "of N" part number declared by the audio filenames; empty when none.
declared_parts() {
    find "$1" "${AUDIO_MATCH[@]}" -printf '%f\n' \
        | grep -oiE 'of[._ -]+[0-9]+' | grep -oE '[0-9]+' \
        | sed 's/^0*//' | sort -n | tail -1
}

debug "Starting scan in: $BASE_DIR"
debug "Delete mode: $DELETE_MODE"
debug "Debug mode: $DEBUG_MODE"

# Book folders sit at author/book under the library root; author folders are
# never inspected or removed.
while IFS= read -r DIR; do
    debug "Checking book folder: $DIR"

    audio=$(audio_files "$DIR")
    zero=$(zero_audio_files "$DIR")

    n_audio=$(count_nonempty "$audio")
    n_zero=$(count_nonempty "$zero")
    n_remaining=$((n_audio - n_zero))

    declared=$(declared_parts "$DIR")
    [[ -z "$declared" ]] && declared=0

    reasons=()
    [[ $n_zero -gt 0 ]] && reasons+=("$n_zero zero-byte file(s)")
    [[ $n_remaining -eq 0 ]] && reasons+=("no audio files")
    [[ $declared -gt $n_audio ]] && reasons+=("missing files (declared $declared, present $n_audio)")

    [[ ${#reasons[@]} -eq 0 ]] && continue

    printf 'Corrupt book folder: %s\n' "$DIR"
    printf '  - %s\n' "${reasons[@]}"

    [[ $DELETE_MODE -eq 1 ]] || continue

    if [[ $n_remaining -eq 0 || $declared -gt $n_audio ]]; then
        debug "Removing folder: $DIR"
        rm -rf "$DIR"
    elif [[ $n_zero -gt 0 ]]; then
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            debug "Deleting zero-byte file: $f"
            rm -f "$f"
        done <<< "$zero"
    fi
done < <(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type d)
