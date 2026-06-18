#!/usr/bin/env bash

start_dir="."

find "$start_dir" -type f -iname '*.mkv' | while IFS= read -r file; do
    # Extract coded height (may be 1080, 1088, 2160, etc.)
    height=$(ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=height \
        -of csv=p=0 "$file" | tr -dc '0-9')

    # Skip if height is empty or zero
    [ -n "$height" ] || continue

    # Treat anything above 1100 as >1080p
    if (( height > 1100 )); then
        echo "$file"
    fi
done
