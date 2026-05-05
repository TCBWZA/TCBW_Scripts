#!/usr/bin/env bash
IFS=''
set -euo pipefail

# Ensure Unicode filenames and metadata work correctly on Proxmox
export LANG=en_GB.UTF-8
export LC_ALL=en_GB.UTF-8

file="$1"

if [[ ! -f "$file" ]]; then
  echo "File not found: $file"
  exit 1
fi

# Save timestamps
orig_mtime=$(stat -c %y "$file")
orig_atime=$(stat -c %x "$file")

# Load JSON metadata
json=$(mkvmerge --identify --identification-format json "$file")

##############################################
# VIDEO TRACK NAME CLEANUP
##############################################

video_id=$(echo "$json" | jq -r '.tracks[] | select(.type=="video") | .id')
video_name=$(echo "$json" | jq -r '.tracks[] | select(.type=="video") | .properties.track_name // ""')

video_patterns=(
  "ToonsHub"
  "CR WEB-DL"
  "\\[Erai-raws\\]_AVC_CR"
)

remove_video_name=false
for p in "${video_patterns[@]}"; do
  if [[ "$video_name" =~ $p ]]; then
    remove_video_name=true
    break
  fi
done

if [[ "$remove_video_name" == true ]]; then
  echo "Removing video track name '$video_name' from: $file"
  mkvpropedit "$file" --edit track:v$video_id --delete name
fi

##############################################
# AUDIO TRACK NAME CLEANUP
##############################################

audio_tracks=$(echo "$json" | jq -c '.tracks[] | select(.type=="audio")')

while IFS= read -r track; do
  id=$(echo "$track" | jq -r '.id')
  name=$(echo "$track" | jq -r '.properties.track_name // ""')

  [[ -z "$name" ]] && continue

  # Case 1: Remove if exactly "[Erai-raws]_AAC_CR"
  if [[ "$name" == "[Erai-raws]_AAC_CR" ]]; then
    echo "Removing audio track name '$name' (Erai-raws AAC rule) on track $id"
    mkvpropedit "$file" --edit track:a$id --delete name
    continue
  fi

  # Case 2: Strip "CR " prefix
  if [[ "$name" == CR\ * ]]; then
    new_name="${name#CR }"
    echo "Renaming audio track $id: '$name' → '$new_name'"
    mkvpropedit "$file" --edit track:a$id --set "name=$new_name"
  fi

done <<< "$audio_tracks"

##############################################
# SUBTITLE TRACK NAME CLEANUP
##############################################

subtitle_tracks=$(echo "$json" | jq -c '.tracks[] | select(.type=="subtitles")')

while IFS= read -r track; do
  id=$(echo "$track" | jq -r '.id')
  name=$(echo "$track" | jq -r '.properties.track_name // ""')

  [[ -z "$name" ]] && continue

  if [[ "$name" == CR\ * ]]; then
    new_name="${name#CR }"
    echo "Renaming subtitle track $id: '$name' → '$new_name'"
    mkvpropedit "$file" --edit track:s$id --set "name=$new_name"
  fi

done <<< "$subtitle_tracks"

##############################################
# RESTORE TIMESTAMPS
##############################################

touch -d "$orig_mtime" "$file"
touch -a -d "$orig_atime" "$file"

echo "Done. All timestamps preserved."
