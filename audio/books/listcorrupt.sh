#!/usr/bin/env bash

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

debug "Starting scan in: $BASE_DIR"
debug "Delete mode: $DELETE_MODE"
debug "Debug mode: $DEBUG_MODE"

# Scan all directories recursively
find "$BASE_DIR" -type d | while read -r DIR; do
    debug "Checking directory: $DIR"

    # Look for the first zero-byte audio file in this directory
    FILE=$(find "$DIR" -maxdepth 1 -type f \( -iname "*.mp3" -o -iname "*.m4b" \) -size 0c -print -quit)

    if [[ -n "$FILE" ]]; then
        echo "Zero-byte file found in: $DIR"
        debug "Matched file: $FILE"

        if [[ $DELETE_MODE -eq 1 ]]; then
            debug "Deleting directory: $DIR"
            rm -rf "$DIR"
        fi

        continue
    fi
done
