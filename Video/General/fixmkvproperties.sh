#!/usr/bin/env bash
IFS=''
set -euo pipefail

# Ensure Unicode filenames and metadata work correctly on Proxmox
export LANG=en_GB.UTF-8
export LC_ALL=en_GB.UTF-8

##############################################
# PREREQUISITE CHECKS
##############################################

for cmd in mkvmerge mkvpropedit jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$cmd' is not installed."
        echo "Install with: apt install mkvtoolnix jq"
        exit 1
    fi
done

##############################################
# SAFE & JUNK PATTERNS
##############################################

# These should NEVER be removed
safe_patterns=(
  "HEVC"
  "H265"
  "H.265"
  "x265"
  "x264"
  "AVC"
  "AV1"
  "10bit"
  "12bit"
  "HDR"
  "HDR10"
  "HDR10+"
  "Dolby Vision"
  "DV"
  "FLAC"
  "TrueHD"
  "Atmos"
  "DTS"
  "DTS-HD"
  "AAC"
  "Dual Audio"
)

# These should ALWAYS be removed if found
junk_patterns=(
  "Erai-raws"
  "SubsPlease"
  "ToonsHub"
  "Judas"
  "EMBER"
  "Anime Time"
  "HorribleSubs"
  "DeadFish"
  "AnimeRG"
  "NC-Raws"
  "LowPower-Raws"
  "Kirion"
  "Vodes"
  "Kawaiika-Raws"
  "Yameii"
  "AkihitoSubs"
  "CR WEB-DL"
  "CR "
  "CR -"
  "HiDive"
  "Netflix"
  "AMZN"
  "Amazon"
  "Disney+"
  "Bilibili"
  "Ani-One"
  "\\[Erai-raws\\]"
  "\\[SubsPlease\\]"
  "\\[Judas\\]"
  "\\[EMBER\\]"
  "\\[NC-Raws\\]"
  "\\[LowPower-Raws\\]"
)

##############################################
# CLEAN A TRACK NAME
##############################################

clean_name() {
    local name="$1"

    # Keep safe patterns
    for s in "${safe_patterns[@]}"; do
        if [[ "$name" == *"$s"* ]]; then
            # Still remove junk around it
            break
        fi
    done

    # Remove junk patterns
    for j in "${junk_patterns[@]}"; do
        if [[ "$name" =~ $j ]]; then
            name="${name//$j/}"
        fi
    done

    # Strip CR prefixes (longest first)
    if [[ "$name" == CR\ -\ * ]]; then
        name="${name#CR - }"
    elif [[ "$name" == CR\ * ]]; then
        name="${name#CR }"
    fi

    # Trim whitespace
    name="$(echo "$name" | sed 's/^ *//;s/ *$//')"

    echo "$name"
}

##############################################
# PROCESS A SINGLE MKV FILE
##############################################

process_file() {
    file="$1"
    echo "Processing: $file"

    # Save timestamps
    orig_mtime=$(stat -c %y "$file")
    orig_atime=$(stat -c %x "$file")

    # Load JSON metadata
    json=$(mkvmerge --identify --identification-format json "$file")

    ##############################################
    # VIDEO TRACK CLEANUP
    ##############################################

    video_tracks=$(echo "$json" | jq -c '.tracks[] | select(.type=="video")')

    while IFS= read -r track; do
        id=$(echo "$track" | jq -r '.id')
        name=$(echo "$track" | jq -r '.properties.track_name // ""')

        [[ -z "$name" ]] && continue

        new_name=$(clean_name "$name")

        if [[ "$new_name" != "$name" ]]; then
            if [[ -z "$new_name" ]]; then
                echo "  - Removing video track name '$name'"
                mkvpropedit "$file" --edit track:v$id --delete name
            else
                echo "  - Renaming video track $id: '$name' → '$new_name'"
                mkvpropedit "$file" --edit track:v$id --set "name=$new_name"
            fi
        fi
    done <<< "$video_tracks"

    ##############################################
    # AUDIO TRACK CLEANUP
    ##############################################

    audio_tracks=$(echo "$json" | jq -c '.tracks[] | select(.type=="audio")')

    while IFS= read -r track; do
        id=$(echo "$track" | jq -r '.id')
        name=$(echo "$track" | jq -r '.properties.track_name // ""')

        [[ -z "$name" ]] && continue

        # Special case: remove exactly "[Erai-raws]_AAC_CR"
        if [[ "$name" == "[Erai-raws]_AAC_CR" ]]; then
            echo "  - Removing audio track name '$name'"
            mkvpropedit "$file" --edit track:a$id --delete name
            continue
        fi

        new_name=$(clean_name "$name")

        if [[ "$new_name" != "$name" ]]; then
            if [[ -z "$new_name" ]]; then
                echo "  - Removing audio track name '$name'"
                mkvpropedit "$file" --edit track:a$id --delete name
            else
                echo "  - Renaming audio track $id: '$name' → '$new_name'"
                mkvpropedit "$file" --edit track:a$id --set "name=$new_name"
            fi
        fi
    done <<< "$audio_tracks"

    ##############################################
    # SUBTITLE TRACK CLEANUP
    ##############################################

    subtitle_tracks=$(echo "$json" | jq -c '.tracks[] | select(.type=="subtitles")')

    while IFS= read -r track; do
        id=$(echo "$track" | jq -r '.id')
        name=$(echo "$track" | jq -r '.properties.track_name // ""')

        [[ -z "$name" ]] && continue

        new_name=$(clean_name "$name")

        if [[ "$new_name" != "$name" ]]; then
            if [[ -z "$new_name" ]]; then
                echo "  - Removing subtitle track name '$name'"
                mkvpropedit "$file" --edit track:s$id --delete name
            else
                echo "  - Renaming subtitle track $id: '$name' → '$new_name'"
                mkvpropedit "$file" --edit track:s$id --set "name=$new_name"
            fi
        fi
    done <<< "$subtitle_tracks"

    ##############################################
    # RESTORE TIMESTAMPS
    ##############################################

    touch -d "$orig_mtime" "$file"
    touch -a -d "$orig_atime" "$file"

    echo "  - Done (timestamps preserved)"
}

##############################################
# RECURSIVE MKV SEARCH
##############################################

find . -type f -iname "*.mkv" -print0 | while IFS= read -r -d '' mkv; do
    process_file "$mkv"
done

echo "All MKV files processed."
