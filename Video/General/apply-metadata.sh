#!/usr/bin/env bash
#
# =============================================================================
# UNIFIED MOVIE + EPISODE METADATA APPLIER + REMUX + TRACK CLEANER (2026)
# MKVToolNix + Jellyfin Tag Set + BOM-safe XML parsing + Double-processing prevention
# =============================================================================

set -uo pipefail
IFS=$'\n'

# ------------------------------
# Flags
# ------------------------------
DRYRUN=0
DEBUG=0
AUDIT_LOG=""
LOGGING_ENABLED=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log) AUDIT_LOG="$2"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ -n "$AUDIT_LOG" ]] && LOGGING_ENABLED=1

log() {
    local lvl="$1"; shift
    echo "[$lvl] $*"
    [[ $LOGGING_ENABLED -eq 1 ]] && printf '%s  [%s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >> "$AUDIT_LOG"
}

debug() { [[ $DEBUG -eq 1 ]] && log DEBUG "$*"; }

# ------------------------------
# Dependency check
# ------------------------------
for cmd in xmlstarlet mkvmerge mkvpropedit mkvextract jq ffmpeg stat touch; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing: $cmd"; exit 1; }
done

# ------------------------------
# XML helpers (stdin-safe)
# ------------------------------
xml_get() {
    local file="$1" xpath="$2"
    xmlstarlet sel -t -v "$xpath" < "$file" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

xml_root() {
    xmlstarlet sel -t -v "name(/*)" < "$1" 2>/dev/null
}

# ------------------------------
# Tag builder (Jellyfin + MKVToolNix)
# ------------------------------
build_tags_xml() {
    local outfile="$1"
    {
        echo "<Tags>"
        echo "  <Tag>"
        for key in "${!TAGS[@]}"; do
            local esc
            esc=$(printf '%s' "${TAGS[$key]}" | xmlstarlet esc)
            printf '    <Simple><Name>%s</Name><String>%s</String></Simple>\n' "$key" "$esc"
        done
        echo "  </Tag>"
        echo "</Tags>"
    } > "$outfile"
}

# ------------------------------
# Anime junk cleaner
# ------------------------------
clean_name() {
    local name="$1"

    local long_patterns=(
      "[Erai-raws]_AAC_CR"
      "[Erai-raws]_AVC_CR"
      "CR - "
      "CR "
    )

    local junk_patterns=(
      "\[Erai-raws\]" "\[SubsPlease\]" "\[Judas\]" "\[EMBER\]" "\[NC-Raws\]" "\[LowPower-Raws\]"
      "Erai-raws" "SubsPlease" "ToonsHub" "Judas" "EMBER"
      "Anime Time" "HorribleSubs" "DeadFish" "AnimeRG"
      "NC-Raws" "LowPower-Raws" "Kirion" "Vodes"
      "Kawaiika-Raws" "Yameii" "AkihitoSubs"
      "CR WEB-DL" "HiDive" "Netflix" "AMZN" "Amazon"
      "Disney+" "Bilibili" "Ani-One"
    )

    for p in "${long_patterns[@]}"; do name="${name//$p/}"; done
    name="$(printf '%s' "$name" | sed 's/\[\]_//g; s/\[\]//g')"
    for j in "${junk_patterns[@]}"; do name="${name//$j/}"; done

    printf '%s' "$(echo "$name" | sed 's/^[[:space:]]*//')"
}

# ------------------------------
# Remux engine
# ------------------------------
remux_mkv() {
    local mkv="$1" orig_mtime="$2" reason="$3"
    log INFO "Remuxing ($reason): $mkv"

    local tmp="${mkv%.mkv}.tmp"
    ffmpeg -y -i "$mkv" -map 0 -c copy -max_interleave_delta 0 -f matroska "$tmp"
    local rc=$?

    if [[ $rc -ne 0 ]]; then
        log ERROR "ffmpeg remux failed ($rc)"
        rm -f "$tmp"
        return 1
    fi

    mv -f "$tmp" "$mkv"
    touch -d "$orig_mtime" "$mkv"
    return 0
}

# ------------------------------
# Begin
# ------------------------------
log INFO "Scanning for MKV files..."
tmpfile=$(mktemp)
find . -type f -iname '*.mkv' -print0 > "$tmpfile"

while IFS= read -r -d '' mkv; do
    log INFO "Processing: $mkv"
    orig_mtime=$(stat -c %y "$mkv")

    # ------------------------------
    # mkvmerge JSON (with remux fallback)
    # ------------------------------
    if ! json=$(mkvmerge -J "$mkv" 2>/dev/null); then
        remux_mkv "$mkv" "$orig_mtime" "mkvmerge -J failed" || continue
        json=$(mkvmerge -J "$mkv" 2>/dev/null) || continue
    fi

    # ------------------------------
    # UID sanity check
    # ------------------------------
    force_remux=0
    declare -A seen=()

    while read -r uid; do
        [[ "$uid" == "null" || "$uid" == "0" ]] && force_remux=1
        [[ -n "${seen[$uid]+x}" ]] && force_remux=1
        seen[$uid]=1
    done < <(echo "$json" | jq -r '.tracks[].properties.uid // "null"')

    if [[ $force_remux -eq 1 ]]; then
        remux_mkv "$mkv" "$orig_mtime" "UID sanity" || continue
        json=$(mkvmerge -J "$mkv" 2>/dev/null) || continue
    fi

    # ------------------------------
    # NFO detection
    # ------------------------------
    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)

    nfo_candidates=(
        "$dir/$base.nfo"
        "$dir/${base%% - *}.nfo"
        "$dir/${base% - Episode*}.nfo"
        "$dir/$(echo "$base" | sed -E 's/( - Episode.*)//').nfo"
        "$dir/$(echo "$base" | grep -oE 'S[0-9]{2}E[0-9]{2}').nfo"
        "$dir/episode.nfo"
        "$dir/movie.nfo"
    )

    nfo=""
    for f in "${nfo_candidates[@]}"; do
        [[ -f "$f" ]] && { nfo="$f"; break; }
    done

    apply_tags=1
    [[ -z "$nfo" ]] && apply_tags=0

    # ------------------------------
    # Clean NFO (BOM + whitespace)
    # ------------------------------
    if [[ $apply_tags -eq 1 ]]; then
        nfo_clean=$(mktemp)
        sed $'1s/^\uFEFF//' "$nfo" | sed 's/^[[:space:]]*//' > "$nfo_clean"

        # Validate XML
        if ! xmlstarlet val "$nfo_clean" >/dev/null 2>&1; then
            log WARN "Invalid XML in NFO — ignoring: $nfo"
            apply_tags=0
        fi
    fi

    # ------------------------------
    # Parse NFO to Jellyfin tag set
    # ------------------------------
    declare -A TAGS=()
    new_title=""
    TYPE=""

    if [[ $apply_tags -eq 1 ]]; then
        root=$(xml_root "$nfo_clean")

        case "$root" in
            movie)
                TYPE="MOVIE"
                title=$(xml_get "$nfo_clean" "/movie/title")
                plot=$(xml_get "$nfo_clean" "/movie/plot")
                premiered=$(xml_get "$nfo_clean" "/movie/premiered")
                year="${premiered:0:4}"

                [[ -z "$title" ]] && title="$base"

                new_title="$title"
                [[ -n "$year" ]] && new_title="$title ($year)"

                TAGS[TITLE]="$title"
                TAGS[DESCRIPTION]="$plot"
                TAGS[DATE_RELEASED]="$year"
                TAGS[PREMIERED]="$premiered"
                ;;

            episodedetails)
                TYPE="EPISODE"
                showtitle=$(xml_get "$nfo_clean" "/episodedetails/showtitle")
                etitle=$(xml_get "$nfo_clean" "/episodedetails/title")
                season=$(xml_get "$nfo_clean" "/episodedetails/season")
                episode=$(xml_get "$nfo_clean" "/episodedetails/episode")
                plot=$(xml_get "$nfo_clean" "/episodedetails/plot")
                aired=$(xml_get "$nfo_clean" "/episodedetails/aired")
                year="${aired:0:4}"

                [[ -z "$showtitle" ]] && showtitle=$(basename "$dir")
                [[ -z "$etitle" ]] && etitle="Episode $episode"

                s=$(printf '%02d' "$season")
                e=$(printf '%02d' "$episode")

                new_title="$showtitle – S${s}E${e} – $etitle"

                TAGS[TITLE]="$etitle"
                TAGS[DESCRIPTION]="$plot"
                TAGS[SERIES]="$showtitle"
                TAGS[SEASON]="$season"
                TAGS[EPISODE]="$episode"
                TAGS[DATE_RELEASED]="$year"
                TAGS[AIRED]="$aired"
                ;;

            *)
                log WARN "Unknown NFO root <$root> — skipping tags"
                apply_tags=0
                ;;
        esac
    fi

    # ------------------------------
    # DOUBLE PROCESSING PREVENTION
    # ------------------------------
    if [[ $apply_tags -eq 1 ]]; then
        tags_tmp=$(mktemp)
        mkvextract "$mkv" tags "$tags_tmp" 2>/dev/null || true

        if [[ -s "$tags_tmp" ]]; then
            ex_title=$(xmlstarlet sel -t -v "//Simple[Name='TITLE']/String" "$tags_tmp" 2>/dev/null)
            ex_series=$(xmlstarlet sel -t -v "//Simple[Name='SERIES']/String" "$tags_tmp" 2>/dev/null)
            ex_season=$(xmlstarlet sel -t -v "//Simple[Name='SEASON']/String" "$tags_tmp" 2>/dev/null)
            ex_episode=$(xmlstarlet sel -t -v "//Simple[Name='EPISODE']/String" "$tags_tmp" 2>/dev/null)
            ex_desc=$(xmlstarlet sel -t -v "//Simple[Name='DESCRIPTION']/String" "$tags_tmp" 2>/dev/null)

            if [[ "$TYPE" == "EPISODE" ]]; then
                if [[ "$ex_series" == "$showtitle" &&
                      "$ex_season" == "$season" &&
                      "$ex_episode" == "$episode" &&
                      "$ex_title" == "$etitle" ]]; then
                    log INFO "Skipping: Already processed."
                    rm -f "$tags_tmp"
                    continue
                fi
            else
                if [[ "$ex_title" == "$title" &&
                      "$ex_desc" == "$plot" ]]; then
                    log INFO "Skipping: Already processed."
                    rm -f "$tags_tmp"
                    continue
                fi
            fi
        fi

        rm -f "$tags_tmp"
    fi

    # ------------------------------
    # Normalise container title
    # ------------------------------
    if [[ $DRYRUN -eq 0 ]]; then
        mkvmerge --title "" -o "$dir/$base.tmp" "$mkv" >/dev/null 2>&1
        mv -f "$dir/$base.tmp" "$mkv"
    fi

    # ------------------------------
    # Track renaming by UID
    # ------------------------------
    if [[ $DRYRUN -eq 0 ]]; then
        while read -r track; do
            uid=$(echo "$track" | jq -r '.properties.uid')
            ttype=$(echo "$track" | jq -r '.type')
            tname=$(echo "$track" | jq -r '.properties.track_name // ""')

            real_raw=$(mkvpropedit "$mkv" --edit "track:@$uid" --get name 2>&1 || true)
            real_name=""
            [[ "$real_raw" == name=* ]] && real_name="${real_raw#name=}"

            cleaned=$(clean_name "${real_name:-$tname}")

            if [[ "$ttype" == "video" ]]; then
                cleaned="Video"
            fi

            mkvpropedit "$mkv" --edit "track:@$uid" --set "name=$cleaned" >/dev/null 2>&1 || true
        done < <(echo "$json" | jq -c '.tracks[]')
    fi

    # ------------------------------
    # Apply tags + container title
    # ------------------------------
    if [[ $apply_tags -eq 1 && $DRYRUN -eq 0 ]]; then
        temp_tags="$dir/$base.tags.tmp"
        build_tags_xml "$temp_tags"

        mkvpropedit "$mkv" --edit info --set "title=$new_title" >/dev/null 2>&1 || true
        mkvpropedit "$mkv" --tags all:"$temp_tags" >/dev/null 2>&1 || true

        rm -f "$temp_tags"
    fi

    touch -d "$orig_mtime" "$mkv"
    log INFO "Finished: $mkv"

done < "$tmpfile"

rm -f "$tmpfile"
log INFO "Unified metadata run complete."
