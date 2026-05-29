#!/usr/bin/env bash
# metadata-cleanup.sh
# Jellyfin-aware cleanup script
# - Episode-aware sidecar cleanup
# - Trickplay folder support (basename.trickplay/, treated atomically)
# - Series- and season-level metadata protection
# - Filesystem + Jellyfin API verification
# - Proxmox-safe (no -e, uses set -ou pipefail)

set -ou pipefail

JF_URL="http://localhost:8096"
JF_API_KEY="YOUR_API_KEY"

MEDIA_EXT="mkv|mp4|avi|mov|m4v"
SIDECAR_EXT="edl|nfo|xml|jpg|jpeg|png|srt|ass|vtt"

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <root-media-directory>"
    exit 1
fi

ROOT="$1"

log() {
    printf "[%s] %s\n" "$(date '+%F %T')" "$*"
}

jellyfin_has_item() {
    local path="$1"
    local encoded
    encoded=$(jq -rn --arg x "$path" '$x|@uri')

    curl -s \
        -H "X-Emby-Token: $JF_API_KEY" \
        "$JF_URL/Items?Recursive=true&Fields=Path&SearchTerm=$encoded" \
        | jq -e '.Items | length > 0' >/dev/null 2>&1
}

is_series_folder() {
    local dir="$1"
    find "$dir" -maxdepth 1 -type d -regex ".*/[Ss]eason[ _-]?[0-9]+" 2>/dev/null | grep -q .
}

extract_episode_code() {
    local name="$1"

    # S01E08 / s01e08
    if [[ "$name" =~ [Ss]([0-9]{1,2})[Ee]([0-9]{1,3}) ]]; then
        printf "S%02dE%02d" "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
        return
    fi

    # 1x08 / 01x08
    if [[ "$name" =~ ([0-9]{1,2})[xX]([0-9]{1,3}) ]]; then
        printf "S%02dE%02d" "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))"
        return
    fi

    # E08 (episode only)
    if [[ "$name" =~ [Ee]([0-9]{1,3}) ]]; then
        printf "E%02d" "$((10#${BASH_REMATCH[1]}))"
        return
    fi

    return 1
}

find_media_for_episode() {
    local dir="$1"
    local ep="$2"

    find "$dir" -maxdepth 1 -type f 2>/dev/null \
        | grep -E "$ep" \
        | grep -E "\.($MEDIA_EXT)$" \
        | head -n 1
}

find_media_by_basename() {
    local dir="$1"
    local base="$2"
    local f b noext

    while IFS= read -r f; do
        b=$(basename "$f")
        noext="${b%.*}"
        if [[ "$noext" == "$base" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | grep -E "\.($MEDIA_EXT)$" || true)

    return 1
}

cleanup_sidecars() {
    local root="$1"

    # --- File-based sidecars (excluding contents of .trickplay folders) ---
    find "$root" -type f 2>/dev/null \
        ! -path "*/.trickplay/*" ! -path "*.trickplay/*" \
        | grep -E "\.($SIDECAR_EXT)$" \
        | while read -r sidecar; do

        local filename dir ep media_file
        filename=$(basename "$sidecar")
        dir=$(dirname "$sidecar")

        # Season-level metadata protection (anywhere)
        case "$filename" in
            season.nfo|season*.nfo|season*-poster.jpg|season*-fanart.jpg|season*-banner.jpg)
                continue
                ;;
        esac

        # Series-level metadata protection (only in series folders)
        if is_series_folder "$dir"; then
            case "$filename" in
                series.nfo|tvshow.nfo|poster.jpg|fanart.jpg|banner.jpg|logo.png|clearart.png|landscape.jpg)
                    continue
                    ;;
            esac
        fi

        ep=$(extract_episode_code "$filename" || true)
        media_file=""

        if [[ -n "$ep" ]]; then
            media_file=$(find_media_for_episode "$dir" "$ep")

            if [[ -z "$media_file" ]]; then
                local parent
                parent=$(dirname "$dir")
                media_file=$(find_media_for_episode "$parent" "$ep")
            fi
        fi

        if [[ -n "$media_file" ]]; then
            continue
        fi

        if jellyfin_has_item "$sidecar"; then
            continue
        fi

        log "Deleting orphan sidecar file: $sidecar"
        rm -f -- "$sidecar"
    done

    # --- Trickplay folders (basename.trickplay/, treated atomically) ---
    find "$root" -type d -name "*.trickplay" 2>/dev/null \
        | while read -r tpdir; do

        local tpbase dir media_file parent
        tpbase=$(basename "$tpdir" .trickplay)
        dir=$(dirname "$tpdir")
        media_file=""

        media_file=$(find_media_by_basename "$dir" "$tpbase" || true)

        if [[ -z "$media_file" ]]; then
            parent=$(dirname "$dir")
            media_file=$(find_media_by_basename "$parent" "$tpbase" || true)
        fi

        if [[ -n "$media_file" ]]; then
            continue
        fi

        if jellyfin_has_item "$tpdir"; then
            continue
        fi

        log "Deleting orphan trickplay folder: $tpdir"
        rm -rf -- "$tpdir"
    done
}

cleanup_sidecars "$ROOT"
