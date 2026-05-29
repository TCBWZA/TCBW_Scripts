#!/usr/bin/env bash
#
# Unified MKV cleaner + NFO applier
# Full DEBUG mode with selective temp preservation
#

set -uo pipefail
IFS=$'\n\t'

DRYRUN=0
DEBUG=0
AUDIT_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log)
            AUDIT_LOG="$2"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

LOGGING_ENABLED=0
[[ -n "$AUDIT_LOG" ]] && LOGGING_ENABLED=1

log_audit() {
    [[ $LOGGING_ENABLED -eq 1 ]] || return
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$AUDIT_LOG"
}

log_debug() {
    if [[ $DEBUG -eq 1 ]]; then
        printf '[DEBUG] %s\n' "$1"
        [[ $LOGGING_ENABLED -eq 1 ]] && log_audit "[DEBUG] $1"
    fi
}

safe_rm() {
    local f="$1"
    local keep="$2"

    if [[ $DEBUG -eq 1 && "$keep" == "yes" ]]; then
        echo "[DEBUG] Preserving temp file: $f"
    else
        rm -f "$f"
    fi
}

for cmd in xmlstarlet mkvmerge mkvpropedit mkvextract jq stat touch; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done

xml_get() {
    local file="$1"
    local xpath="$2"
    xmlstarlet sel -t -v "$xpath" -n "$file" 2>/dev/null || true
}

get_mkv_tag() {
    local xmlfile="$1"
    local tagname="$2"
    xmlstarlet sel -t -v "//Simple[Name='$tagname']/String" "$xmlfile" 2>/dev/null || true
}

build_tags_xml() {
    local outfile="$1"
    {
        echo "<Tags>"
        echo "  <Tag>"
        for key in TITLE SERIES SEASON EPISODE DESCRIPTION DATE_RELEASED; do
            local val="${TAGS[$key]}"
            local esc
            esc=$(printf '%s' "$val" | xmlstarlet esc)
            printf '    <Simple><Name>%s</Name><String>%s</String></Simple>\n' \
                "$key" "$esc"
        done
        echo "  </Tag>"
        echo "</Tags>"
    } > "$outfile"
}

long_patterns=(
  "[Erai-raws]_AAC_CR"
  "[Erai-raws]_AVC_CR"
  "CR - "
  "CR "
)

junk_patterns=(
  "\[Erai-raws\]" "\[SubsPlease\]" "\[Judas\]" "\[EMBER\]"
  "\[SubsPlease\]" "\[Judas\]" "\[EMBER\]" "\[NC-Raws\]" "\[LowPower-Raws\]"
  "Erai-raws" "SubsPlease" "ToonsHub" "Judas" "EMBER"
  "Anime Time" "HorribleSubs" "DeadFish" "AnimeRG"
  "NC-Raws" "LowPower-Raws" "Kirion" "Vodes"
  "Kawaiika-Raws" "Yameii" "AkihitoSubs"
  "CR WEB-DL" "HiDive" "Netflix" "AMZN" "Amazon"
  "Disney+" "Bilibili" "Ani-One"
)

clean_name() {
    local name="$1"

    for p in "${long_patterns[@]}"; do
        name="${name//$p/}"
    done

    name="$(printf '%s' "$name" | sed 's/\[\]_//g; s/\[\]//g')"

    for j in "${junk_patterns[@]}"; do
        name="${name//$j/}"
    done

    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//')"
    echo "$name"
}

echo "Scanning recursively for MKV files..."
log_audit "=== Unified run started ==="

tmpfile=$(mktemp)
find . -type f -iname '*.mkv' -print0 > "$tmpfile"

while IFS= read -r -d '' mkv; do
    echo "----"
    echo "Processing MKV: $mkv"
    log_audit "Processing MKV: $mkv"

    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)
    nfo="$dir/$base.nfo"

    apply_tags=1

    if [[ -f "$nfo" ]]; then
        nfo_clean="$(mktemp /tmp/cleannfo_XXXXXX)"

        sed $'1s/^\uFEFF//' "$nfo" > "$nfo_clean"
        sync "$nfo_clean"
        log_debug "Created cleaned NFO: $nfo_clean"

        xml_out=$(xmlstarlet sel -t -v "count(//episodedetails)" "$nfo_clean" 2>&1)
        xml_rc=$?
        log_debug "xmlstarlet rc=$xml_rc out='$xml_out'"
        count="$xml_out"

        log_debug "episodedetails count = $count"

        if [[ "$count" -lt 1 ]]; then
            apply_tags=0
            series=$(basename "$(dirname "$dir")")
            new_global_title="$series"
            log_debug "No episodetails found; apply_tags=0"
        else
            ep_title=$(xml_get "$nfo_clean" "//episodedetails/title")
            ep_season=$(xml_get "$nfo_clean" "//episodedetails/season")
            ep_number=$(xml_get "$nfo_clean" "//episodedetails/episode")
            ep_plot=$(xml_get "$nfo_clean" "//episodedetails/plot")
            ep_aired=$(xml_get "$nfo_clean" "//episodedetails/aired")
            ep_year="${ep_aired:0:4}"

            series=$(xml_get "$nfo_clean" "//episodedetails/showtitle")
            [[ -z "$series" ]] && series=$(basename "$(dirname "$dir")")

            declare -A TAGS=(
                [TITLE]="$ep_title"
                [SERIES]="$series"
                [SEASON]="$ep_season"
                [EPISODE]="$ep_number"
                [DESCRIPTION]="$ep_plot"
                [DATE_RELEASED]="$ep_year"
            )

            new_global_title="${series}: ${ep_title}"
            log_debug "NFO episodic detected: S${ep_season}E${ep_number} - $ep_title"
        fi

        safe_rm "$nfo_clean" yes
    else
        apply_tags=0
        series=$(basename "$(dirname "$dir")")
        new_global_title="$series"
        log_debug "No NFO found; apply_tags=0"
    fi

    if [[ $apply_tags -eq 1 ]]; then
        tags_tmp="$dir/$base.extracted.tmp"
        mkvextract "$mkv" tags "$tags_tmp" 2>/dev/null || true
        log_debug "Extracted tags to: $tags_tmp"

        if [[ -s "$tags_tmp" ]]; then
            ex_series=$(get_mkv_tag "$tags_tmp" "SERIES")
            ex_season=$(get_mkv_tag "$tags_tmp" "SEASON")
            ex_episode=$(get_mkv_tag "$tags_tmp" "EPISODE")
            ex_ep_title=$(get_mkv_tag "$tags_tmp" "TITLE")

            log_debug "Existing tags: SERIES='$ex_series' SEASON='$ex_season' EPISODE='$ex_episode' TITLE='$ex_ep_title'"

            if [[ "$ex_series" == "$series" && \
                  "$ex_season" == "$ep_season" && \
                  "$ex_episode" == "$ep_number" && \
                  "$ex_ep_title" == "$ep_title" ]]; then
                echo "Skipping: Already processed."
                log_audit "Skipping (already processed): $mkv"
                safe_rm "$tags_tmp" yes
                continue
            fi
        fi

        safe_rm "$tags_tmp" yes
    fi

    orig_mtime=$(stat -c %y "$mkv")

    if [[ $DRYRUN -eq 1 ]]; then
        echo "Dry-run: would normalize, clean tracks, set title, apply tags."
        continue
    fi

    norm_tmp="$dir/$base.tmp"
    mkvmerge --title "" -o "$norm_tmp" "$mkv" >/dev/null 2>&1
    chmod 666 "$norm_tmp"
    chown 1000:1000 "$norm_tmp"
    mv -f "$norm_tmp" "$mkv"
    chmod 666 "$mkv"
    chown 1000:1000 "$mkv"
    log_debug "Normalized MKV"

    json=$(mkvmerge -J "$mkv")

    v_idx=1
    a_idx=1
    s_idx=1

    while read -r track; do
        ttype=$(echo "$track" | jq -r '.type')
        uid=$(echo "$track" | jq -r '.properties.uid')
        tname=$(echo "$track" | jq -r '.properties.track_name // ""')

        case "$ttype" in
            video) sel="track:v${v_idx}"; v_idx=$((v_idx+1));;
            audio) sel="track:a${a_idx}"; a_idx=$((a_idx+1));;
            subtitles) sel="track:s${s_idx}"; s_idx=$((s_idx+1));;
            *) continue;;
        esac

        real_name_raw=$(mkvpropedit "$mkv" --edit "$sel" --get name 2>&1 || true)
        if [[ "$real_name_raw" == name=* ]]; then
            real_name="${real_name_raw#name=}"
        else
            real_name=""
        fi

        if [[ "$ttype" == "video" ]]; then
            mkvpropedit "$mkv" \
                --edit "$sel" --set "name=Video"
            continue
        else
            if [[ -n "$real_name" ]]; then
                cleaned_name=$(clean_name "$real_name")
            else
                cleaned_name=$(clean_name "$tname")
            fi
        fi

        lang=$(echo "$track" | jq -r '.properties.language // ""')
        lang_name=""
        case "$lang" in
            eng) lang_name="English" ;;
            jpn) lang_name="Japanese" ;;
            chi|zho|cmn) lang_name="Chinese" ;;
            yue) lang_name="Cantonese" ;;
            kor) lang_name="Korean" ;;
            spa) lang_name="Spanish" ;;
            fra|fre) lang_name="French" ;;
            deu|ger) lang_name="German" ;;
        esac

        is_sdh=0
        [[ "$cleaned_name" =~ [Ss][Dd][Hh]|[Cc][Cc]|[Hh][Ii]|Closed[[:space:]]Captions|Hearing[[:space:]]Impaired|HOH ]] && is_sdh=1

        is_signs=0
        [[ "$cleaned_name" =~ [Ss]igns ]] && is_signs=1

        already_has_lang=0
        [[ "$cleaned_name" =~ English|Japanese|Chinese|Simplified\ Chinese|Mandarin|Cantonese|Korean|Spanish|French|German ]] && already_has_lang=1

        if [[ "$ttype" != "video" ]]; then
            if [[ $is_sdh -eq 1 ]]; then
                if [[ $already_has_lang -eq 0 && -n "$lang_name" ]]; then
                    cleaned_name="$lang_name $cleaned_name"
                fi
            elif [[ $is_signs -eq 1 ]]; then
                if [[ $already_has_lang -eq 0 && -n "$lang_name" ]]; then
                    cleaned_name="$lang_name $cleaned_name"
                fi
            else
                if [[ $already_has_lang -eq 0 && -n "$lang_name" ]]; then
                    cleaned_name="$lang_name"
                fi
            fi
        fi

        log_debug "Track UID=$uid type=$ttype lang=$lang_name real='$real_name' tname='$tname' -> '$cleaned_name'"

        if [[ "$ttype" == "video" ]]; then
            mkvpropedit "$mkv" \
                --edit "$sel" --set "name=Video" >/dev/null 2>&1
        else
            mkvpropedit "$mkv" \
                --edit "$sel" --set "name=$cleaned_name" >/dev/null 2>&1
        fi

    done < <(echo "$json" | jq -c '.tracks[]')

    temp_tags="$dir/$base.tags.tmp"
    build_tags_xml "$temp_tags"
    log_debug "Generated tags XML: $temp_tags"

    if [[ $apply_tags -eq 1 ]]; then
        log_debug "Applying container title: $new_global_title"
        mkvpropedit "$mkv" --edit info --set "title=$new_global_title" >/dev/null 2>&1

        log_debug "Applying tags from: $temp_tags"
        mkvpropedit "$mkv" --tags all:"$temp_tags" >/dev/null 2>&1
    fi

    safe_rm "$temp_tags" yes

    touch -d "$orig_mtime" "$mkv"
    log_audit "Finished: $mkv"

done < "$tmpfile"

rm -f "$tmpfile"
