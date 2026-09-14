#!/usr/bin/env bash
#
# Unified MKV cleaner + NFO applier
# - Conservative remuxing
# - UID sanity check
# - Track renaming and NFO tag application
#

set -u
IFS=$'\n'

DRYRUN=0
DEBUG=0
AUDIT_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log)
            if [[ $# -ge 2 ]]; then
                AUDIT_LOG="$2"
                shift
            else
                echo "--audit-log requires a path" >&2
                exit 1
            fi
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

for cmd in xmlstarlet mkvmerge mkvpropedit mkvextract jq stat touch ffmpeg; do
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
  "\[Erai-raws\]_AAC_CR"
  "\[Erai-raws\]_AVC_CR"
  "CR - "
  "CR "
)

junk_patterns=(
  "\[Erai-raws\]" "\[SubsPlease\]" "\[Judas\]" "\[EMBER\]" "\[NC-Raws\]" "\[LowPower-Raws\]"
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

remux_mkv() {
    local mkv="$1"
    local orig_mtime="$2"
    local reason="$3"

    if [[ ! -f "$mkv" ]]; then
        echo "ERROR: remux requested but file not found: $mkv"
        log_audit "ERROR: remux requested but file not found: $mkv (reason: $reason)"
        return 1
    fi

    echo "Remuxing MKV ($reason): $mkv"
    log_audit "Remuxing MKV ($reason): $mkv"

    local fixed="${mkv%.mkv}.tmp"

    ffmpeg -y -i "$mkv" -map 0 -c copy -max_interleave_delta 0 -f matroska "$fixed"
    local ff_rc=$?

    if [[ $ff_rc -ne 0 ]]; then
        echo "ERROR: ffmpeg remux failed for $mkv (exit $ff_rc)"
        log_audit "ERROR: ffmpeg remux failed for $mkv (exit $ff_rc)"
        safe_rm "$fixed" yes
        return $ff_rc
    fi

    mv -f "$fixed" "$mkv"
    touch -d "$orig_mtime" "$mkv"
    return 0
}

# Prints 1 when any track UID is missing, non-numeric, zero, or duplicated
uids_invalid() {
    local json="$1"
    local -A seen_uid
    local uid

    while read -r uid; do
        if [[ "$uid" == "MISSING" ]] || [[ ! "$uid" =~ ^[0-9]+$ ]] || (( uid == 0 )); then
            echo 1
            return
        fi
        if [[ -n "${seen_uid[$uid]+x}" ]]; then
            echo 1
            return
        fi
        seen_uid[$uid]=1
    done <<< "$(echo "$json" | jq -r '.tracks[].properties.uid // "MISSING"')"

    echo 0
}

echo "Scanning recursively for MKV files..."
log_audit "=== Unified run started ==="

# Trailers and extras are not episodes: skip Kodi trailer naming and
# trailers/extras folders so the cleaner never touches promotional files.
tmpfile=$(mktemp)
find . -type f -iname '*.mkv' \
    ! -iname '*-trailer*' \
    ! -path '*/trailers/*' \
    ! -path '*/extras/*' \
    -print0 > "$tmpfile"

while IFS= read -r -d '' mkv; do
    echo "----"
    echo "Processing MKV: $mkv"
    log_audit "Processing MKV: $mkv"

    if [[ ! -f "$mkv" ]]; then
        echo "WARNING: File disappeared, skipping: $mkv"
        log_audit "WARNING: File disappeared, skipping: $mkv"
        continue
    fi

    dir=$(dirname "$mkv")
    base=$(basename "$mkv" .mkv)

    orig_mtime=$(stat -c %y "$mkv")

    # 1) Get JSON, remux once if mkvmerge cannot parse
    if ! json=$(mkvmerge -J "$mkv" 2>/dev/null); then
        if remux_mkv "$mkv" "$orig_mtime" "mkvmerge -J failed"; then
            if ! json=$(mkvmerge -J "$mkv" 2>/dev/null); then
                echo "ERROR: mkvmerge still fails after remux, skipping: $mkv"
                log_audit "ERROR: mkvmerge still fails after remux, skipping: $mkv"
                continue
            fi
        else
            # remux failed
            continue
        fi
    fi

    # 2) UID sanity check (conservative); re-check after any remux
    if [[ "$(uids_invalid "$json")" -eq 1 ]]; then
        if ! remux_mkv "$mkv" "$orig_mtime" "UID sanity check"; then
            continue
        fi
        if ! json=$(mkvmerge -J "$mkv" 2>/dev/null); then
            echo "ERROR: mkvmerge failed after UID remux, skipping: $mkv"
            log_audit "ERROR: mkvmerge failed after UID remux, skipping: $mkv"
            continue
        fi
        if [[ "$(uids_invalid "$json")" -eq 1 ]]; then
            echo "ERROR: UIDs still broken after remux, skipping: $mkv"
            log_audit "ERROR: UIDs still broken after remux, skipping: $mkv"
            continue
        fi
    fi

    # 3) NFO handling
    nfo="$dir/$base.nfo"

    apply_tags=1
    series=""
    new_global_title=""

    if [[ -f "$nfo" ]]; then
        nfo_clean="$(mktemp /tmp/cleannfo_XXXXXX)"
        sed $'1s/^\uFEFF//' "$nfo" > "$nfo_clean"
        log_debug "Created cleaned NFO: $nfo_clean"

        xml_out=$(xmlstarlet sel -t -v "count(//episodedetails)" "$nfo_clean" 2>&1)
        xml_rc=$?
        count="$xml_out"
        log_debug "xmlstarlet rc=$xml_rc out='$xml_out'"

        if [[ $xml_rc -ne 0 ]] || [[ ! "$count" =~ ^[0-9]+$ ]] || [[ "$count" -lt 1 ]]; then
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

    # Skip already-processed files (tags already match the NFO)
    if [[ $apply_tags -eq 1 ]]; then
        tags_tmp="$(mktemp /tmp/mkvextract_XXXXXX)"
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

    container_title=$(echo "$json" | jq -r '.container.properties.title // ""')

    # 4) Track rename plan (positional selectors -- track:@n is the TrackNumber,
    #    not the TrackUID, so uid-based edits were silently no-ops)
    declare -A rename_plan
    rename_needed=0
    v_idx=1
    a_idx=1
    s_idx=1

    while IFS= read -r track; do
        ttype=$(echo "$track" | jq -r '.type')

        case "$ttype" in
            video) sel="track:v${v_idx}"; v_idx=$((v_idx+1));;
            audio) sel="track:a${a_idx}"; a_idx=$((a_idx+1));;
            subtitles) sel="track:s${s_idx}"; s_idx=$((s_idx+1));;
            *) continue;;
        esac

        tname=$(echo "$track" | jq -r '.properties.track_name // ""')

        if [[ "$ttype" == "video" ]]; then
            desired="Video"
        else
            desired=$(clean_name "$tname")

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

            lower="${desired,,}"
            is_sdh=0
            [[ "$lower" =~ sdh|cc|hi|closed[[:space:]]captions|hearing[[:space:]]impaired|hoh ]] && is_sdh=1
            is_signs=0
            [[ "$lower" =~ signs ]] && is_signs=1
            already_has_lang=0
            [[ "$lower" =~ english|japanese|chinese|simplified[[:space:]]chinese|mandarin|cantonese|korean|spanish|french|german ]] && already_has_lang=1

            if [[ $is_sdh -eq 1 || $is_signs -eq 1 ]]; then
                if [[ $already_has_lang -eq 0 && -n "$lang_name" ]]; then
                    desired="$lang_name $desired"
                fi
            elif [[ -n "$desired" ]]; then
                if [[ $already_has_lang -eq 0 && -n "$lang_name" ]]; then
                    desired="$lang_name $desired"
                fi
            else
                desired="$lang_name"
            fi
        fi

        current=$(echo "$track" | jq -r '.properties.track_name // ""')

        if [[ "$desired" == "$current" ]]; then
            continue
        fi

        rename_plan["$sel"]="$desired"
        rename_needed=1
    done < <(echo "$json" | jq -c '.tracks[]')

    # Fast path: nothing to change (empty title, no renames, no tags to apply)
    if [[ $apply_tags -eq 0 ]] && [[ -z "$container_title" ]] && [[ $rename_needed -eq 0 ]]; then
        echo "Skipping: Already processed."
        log_audit "Skipping (already processed): $mkv"
        continue
    fi

    # 5) Normalize container title to empty (only when one exists)
    #    Guard: replace the source only when the output is valid
    if [[ -n "$container_title" ]]; then
        norm_tmp="$dir/$base.tmp"
        rm -f "$norm_tmp"
        mkvmerge --title "" -o "$norm_tmp" "$mkv" >/dev/null 2>&1
        mkv_rc=$?
        if (( mkv_rc != 0 )) || [[ ! -s "$norm_tmp" ]] || ! mkvmerge -J "$norm_tmp" >/dev/null 2>&1; then
            echo "ERROR: normalizing failed for $mkv, keeping original"
            log_audit "ERROR: normalizing failed for $mkv, keeping original"
            rm -f "$norm_tmp"
            continue
        fi
        chmod 666 "$norm_tmp" || true
        chown 1000:1000 "$norm_tmp" 2>/dev/null || true
        mv -f "$norm_tmp" "$mkv"
        chmod 666 "$mkv" || true
        chown 1000:1000 "$mkv" 2>/dev/null || true
        log_debug "Normalized MKV"
    fi

    # 6) Apply track renames (positional selectors)
    for sel in "${!rename_plan[@]}"; do
        mkvpropedit "$mkv" --edit "$sel" --set "name=${rename_plan[$sel]}" >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            log_debug "Set $sel name=${rename_plan[$sel]}"
        else
            log_debug "Failed to set $sel name=${rename_plan[$sel]}"
        fi
    done

    # 7) Tags + container title
    if [[ $apply_tags -eq 1 ]]; then
        temp_tags="$(mktemp /tmp/mkvtagsxml_XXXXXX)"
        build_tags_xml "$temp_tags"
        log_debug "Generated tags XML: $temp_tags"

        log_debug "Applying container title: $new_global_title"
        mkvpropedit "$mkv" --edit info --set "title=$new_global_title" >/dev/null 2>&1 || true

        log_debug "Applying tags from: $temp_tags"
        mkvpropedit "$mkv" --tags all:"$temp_tags" >/dev/null 2>&1 || true

        safe_rm "$temp_tags" yes
    fi

    touch -d "$orig_mtime" "$mkv"
    log_audit "Finished: $mkv"

done < "$tmpfile"

rm -f "$tmpfile"