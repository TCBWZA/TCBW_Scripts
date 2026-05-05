#!/usr/bin/env bash
IFS=''
set -euo pipefail

export LANG=C.UTF-8
export LC_ALL=C.UTF-8

###############################################################################
# fixmkvproperties.sh
#
# MKV Track Metadata Cleaner
#
# Description:
#   This script cleans MKV track metadata by:
#
#   1. Identify MKV structure using mkvmerge JSON.
#
#   2. If ANY track is missing .properties.track_number:
#        - Remux the file with mkvmerge to normalize the container.
#        - Re-check track numbers after remux.
#        - If track numbers are still missing, skip the file as corrupt.
#
#   3. For each track:
#        - If the track name matches an exact-match junk list entry, delete it.
#        - Otherwise, clean partial junk patterns from the name.
#        - Apply rename/delete operations using mkvpropedit.
#
# Usage:
#     ./fixmkvproperties.sh [--debug]
#
# Options:
#     --debug     Enable verbose debug logging
#
# Notes:
#   - mkvpropedit is only called with guaranteed-valid track selectors.
#   - Exact-match lists and junk patterns are fully configurable.
###############################################################################

##############################################
# COMMAND-LINE OPTION HANDLING
##############################################

DEBUG=0

usage() {
    echo "Usage: $0 [--debug]"
    exit 1
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        --debug)
            DEBUG=1
            shift
            ;;
        *)
            echo "ERROR: Invalid option '$1'"
            usage
            ;;
    esac
fi

dbg() {
    [[ "$DEBUG" -eq 1 ]] && echo "[DEBUG] $*"
}

##############################################
# PREREQUISITE CHECKS
##############################################

for cmd in mkvmerge mkvpropedit jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$cmd' is not installed."
        exit 1
    fi
done

##############################################
# EXACT-MATCH JUNK LISTS
##############################################

video_junk_exact=(
  "[Erai-raws]_AVC_CR"
  "[SubsPlease]_AVC"
  "[NC-Raws]_AVC"
  "[ToonsHub]_AVC"
)

audiosub_junk_exact=(
  "[Erai-raws]_AAC_CR"
  "[SubsPlease]_AAC"
  "[NC-Raws]_AAC"
)

##############################################
# PARTIAL JUNK PATTERNS
##############################################

junk_patterns=(
  "Erai-raws" "SubsPlease" "ToonsHub" "Judas" "EMBER"
  "Anime Time" "HorribleSubs" "DeadFish" "AnimeRG"
  "NC-Raws" "LowPower-Raws" "Kirion" "Vodes"
  "Kawaiika-Raws" "Yameii" "AkihitoSubs"
  "CR WEB-DL" "CR " "CR -" "HiDive" "Netflix"
  "AMZN" "Amazon" "Disney+" "Bilibili" "Ani-One"
  "\\[Erai-raws\\]" "\\[SubsPlease\\]" "\\[Judas\\]"
  "\\[EMBER\\]" "\\[NC-Raws\\]" "\\[LowPower-Raws\\]"
)

##############################################
# EXACT MATCH CHECK
##############################################

is_exact_junk() {
    local name="$1"
    shift
    local list=("$@")

    for item in "${list[@]}"; do
        if [[ "$name" == "$item" ]]; then
            dbg "Exact match: '$name' == '$item'"
            return 0
        fi
    done

    return 1
}

##############################################
# CLEAN A TRACK NAME
##############################################

clean_name() {
    local name="$1"
    dbg "Cleaning name: '$name'"

    for j in "${junk_patterns[@]}"; do
        if [[ "$name" =~ $j ]]; then
            dbg "Removing junk pattern '$j' from '$name'"
            name="${name//$j/}"
        fi
    done

    if [[ "$name" == CR\ -\ * ]]; then
        dbg "Removing CR - prefix"
        name="${name#CR - }"
    elif [[ "$name" == CR\ * ]]; then
        dbg "Removing CR prefix"
        name="${name#CR }"
    fi

    name="${name//\[\]/}"
    name="$(echo "$name" | sed 's/^ *//;s/ *$//')"

    dbg "Cleaned name: '$name'"
    echo "$name"
}

##############################################
# FULL TRACK-NUMBER VALIDATION
##############################################

all_tracks_have_numbers() {
    local json="$1"
    local missing
    missing=$(echo "$json" | jq '[.tracks[].properties.track_number] | map(select(. == null)) | length')

    dbg "Missing track numbers: $missing"

    [[ "$missing" -eq 0 ]]
}

##############################################
# NORMALIZE MKV IF ANY TRACK NUMBER IS MISSING
##############################################

normalize_mkv() {
    local file="$1"
    local tmp="${file%.mkv}.tmp.mkv"

    echo "  - Normalizing container (missing track numbers)..."
    dbg "Running mkvmerge: mkvmerge -o '$tmp' '$file'"

    local orig_mtime orig_atime
    orig_mtime=$(stat -c %y "$file")
    orig_atime=$(stat -c %x "$file")

    if ! mkvmerge -o "$tmp" "$file"; then
        dbg "mkvmerge failed with exit code $?"
        echo "  - ERROR: mkvmerge failed. Skipping file."
        return 1
    fi

    dbg "mkvmerge succeeded"

    mv "$tmp" "$file"

    touch -d "$orig_mtime" "$file"
    touch -a -d "$orig_atime" "$file"

    dbg "Timestamps restored"
    return 0
}

##############################################
# PROCESS A SINGLE MKV FILE
##############################################

process_file() {
    local file="$1"
    echo "Processing: $file"

    local json
    json=$(mkvmerge --identify --identification-format json "$file")

    dbg "Initial mkvmerge JSON loaded"

    if ! all_tracks_have_numbers "$json"; then
        dbg "Track numbers missing — normalizing"
        if ! normalize_mkv "$file"; then
            echo "  - Skipping due to mkvmerge failure."
            return
        fi

        json=$(mkvmerge --identify --identification-format json "$file")
        dbg "Re-loaded JSON after normalization"

        if ! all_tracks_have_numbers "$json"; then
            echo "  - ERROR: Track numbers still missing after normalization. Skipping corrupt file."
            return
        fi
    fi

    local orig_mtime orig_atime
    orig_mtime=$(stat -c %y "$file")
    orig_atime=$(stat -c %x "$file")

    ##############################################
    # VIDEO TRACKS
    ##############################################

    echo "$json" | jq -c '.tracks[] | select(.type=="video")' | while read -r track; do
        local id name new_name

        id=$(echo "$track" | jq -r '.properties.track_number')
        name=$(echo "$track" | jq -r '.properties.track_name // ""')

        dbg "Video track $id name: '$name'"

        [[ -z "$name" ]] && continue

        if is_exact_junk "$name" "${video_junk_exact[@]}"; then
            echo "  - Removing video track name '$name'"
            dbg "Running mkvpropedit delete for video track $id"
            mkvpropedit "$file" --edit track:v$id --delete name
            continue
        fi

        new_name=$(clean_name "$name")

        if [[ "$new_name" != "$name" ]]; then
            if [[ -z "$new_name" ]]; then
                echo "  - Removing video track name '$name'"
                dbg "Running mkvpropedit delete for video track $id"
                mkvpropedit "$file" --edit track:v$id --delete name
            else
                echo "  - Renaming video track $id: '$name' -> '$new_name'"
                dbg "Running mkvpropedit set name='$new_name' for video track $id"
                mkvpropedit "$file" --edit track:v$id --set "name=$new_name"
            fi
        fi
    done

    ##############################################
    # AUDIO TRACKS
    ##############################################

    echo "$json" | jq -c '.tracks[] | select(.type=="audio")' | while read -r track; do
        local id name new_name

        id=$(echo "$track" | jq -r '.properties.track_number')
        name=$(echo "$track" | jq -r '.properties.track_name // ""')

        dbg "Audio track $id name: '$name'"

        [[ -z "$name" ]] && continue

        if is_exact_junk "$name" "${audiosub_junk_exact[@]}"; then
            echo "  - Removing audio track name '$name'"
            dbg "Running mkvpropedit delete for audio track $id"
            mkvpropedit "$file" --edit track:a$id --delete name
            continue
        fi

        new_name=$(clean_name "$name")

        if [[ "$new_name" != "$name" ]]; then
            if [[ -z "$new_name" ]]; then
                echo "  - Removing audio track name '$name'"
                dbg "Running mkvpropedit delete for audio track $id"
                mkvpropedit "$file" --edit track:a$id --delete name
            else
                echo "  - Renaming audio track $id: '$name' -> '$new_name'"
                dbg "Running mkvpropedit set name='$new_name' for audio track $id"
                mkvpropedit "$file" --edit track:a$id --set "name=$new_name"
            fi
        fi
    done

    ##############################################
    # SUBTITLE TRACKS
    ##############################################

    echo "$json" | jq -c '.tracks[] | select(.type=="subtitles")' | while read -r track; do
        local id name new_name

        id=$(echo "$track" | jq -r '.properties.track_number')
        name=$(echo "$track" | jq -r '.properties.track_name // ""')

        dbg "Subtitle track $id name: '$name'"

        [[ -z "$name" ]] && continue

        if is_exact_junk "$name" "${audiosub_junk_exact[@]}"; then
            echo "  - Removing subtitle track name '$name'"
            dbg "Running mkvpropedit delete for subtitle track $id"
            mkvpropedit "$file" --edit track:s$id --delete name
            continue
        fi

        new_name=$(clean_name "$name")

        if [[ "$new_name" != "$name" ]]; then
            if [[ -z "$new_name" ]]; then
                echo "  - Removing subtitle track name '$name'"
                dbg "Running mkvpropedit delete for subtitle track $id"
                mkvpropedit "$file" --edit track:s$id --delete name
            else
                echo "  - Renaming subtitle track $id: '$name' -> '$new_name'"
                dbg "Running mkvpropedit set name='$new_name' for subtitle track $id"
                mkvpropedit "$file" --edit track:s$id --set "name=$new_name"
            fi
        fi
    done

    touch -d "$orig_mtime" "$file"
    touch -a -d "$orig_atime" "$file"

    dbg "Timestamps restored"
    echo "  - Done (timestamps preserved)"
}

##############################################
# RECURSIVE MKV SEARCH
##############################################

find . -type f -iname "*.mkv" -print0 | while IFS= read -r -d '' mkv; do
    process_file "$mkv"
done

echo "All MKV files processed."
