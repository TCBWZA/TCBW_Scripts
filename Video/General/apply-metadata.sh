#!/usr/bin/env bash
#
# =============================================================================
# UNIFIED MOVIE + EPISODE METADATA APPLIER + REMUX + TRACK CLEANER (2026)
# MKVToolNix + Jellyfin Tag Set + BOM-safe XML parsing + Double-processing prevention
#
# Usage: apply-metadata.sh [OPTIONS] [FILE]
#   With no FILE, every .mkv under the current directory is processed.
#   With FILE, only that MKV is processed and the directory walk is skipped.
#   Callers that just produced one file should pass it: it is the work they
#   actually want, and it keeps two concurrent workers off the same file.
#
# Options: --dry-run, --debug, --audit-log FILE
# =============================================================================

set -uo pipefail
IFS=$'\n'

# U+2013 EN DASH, the generated episode-title separator. Escape keeps this ASCII.
EN_DASH=$'\u2013'

# ------------------------------
# Flags
# ------------------------------
DRYRUN=0
DEBUG=0
AUDIT_LOG=""
LOGGING_ENABLED=0
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRYRUN=1 ;;
        --debug)   DEBUG=1 ;;
        --audit-log) AUDIT_LOG="$2"; shift ;;
        # A leading dash means a mistyped option, not a path. Catching it here
        # keeps a typo from being taken as a filename and failing the existence
        # check with a misleading message.
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if [[ -n "$TARGET" ]]; then
                echo "Only one file may be given (already have: $TARGET)" >&2; exit 1
            fi
            TARGET="$1"
            ;;
    esac
    shift
done

[[ -n "$AUDIT_LOG" ]] && LOGGING_ENABLED=1

# Both helpers use an if rather than && on the last statement: a short-circuit
# that evaluates false makes the function return 1, and log's final call is the
# last command in the script. That made every run report failure to callers
# that check the exit status, however well the run had actually gone.
log() {
    local lvl="$1"; shift
    echo "[$lvl] $*"
    if [[ $LOGGING_ENABLED -eq 1 ]]; then
        printf '%s  [%s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >> "$AUDIT_LOG"
    fi
}

debug() { if [[ $DEBUG -eq 1 ]]; then log DEBUG "$*"; fi; }

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
        # Series root at TargetTypeValue 70 (VLC showName).
        # Empty Targets defaults to target 50, which VLC reads as Album.
        # TYPE is tested FIRST and the key is read through a default: the MOVIE
        # branch never assigns TAGS[SHOW], so dereferencing it under `set -u`
        # aborted every movie mid-run, before any tag was written.
        if [[ "$TYPE" == "EPISODE" && -n "${TAGS[SHOW]:-}" ]]; then
            local esc70
            esc70=$(printf '%s' "${TAGS[SHOW]}" | xmlstarlet esc)
            echo "  <Tag>"
            echo "    <Targets><TargetTypeValue>70</TargetTypeValue><TargetType>COLLECTION</TargetType></Targets>"
            printf '    <Simple><Name>TITLE</Name><String>%s</String></Simple>\n' "$esc70"
            echo "  </Tag>"
        fi
        echo "</Tags>"
    } > "$outfile"
}

# ------------------------------
# Series root resolver
# ------------------------------
trim_trailing_dash() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    # Strip trailing hyphens and the U+2013/U+2014 dashes NFOs use; escapes
    # keep the source ASCII because $'...' does not expand in a [[ ]] pattern.
    local DASH_CLASS=$'[-\u2013\u2014]'
    while [[ "$s" == *$DASH_CLASS ]]; do
        s="${s%$DASH_CLASS}"
        s="${s%"${s##*[![:space:]]}"}"
    done
    printf '%s' "$s"
}

resolve_series_root() {
    local d orig f="" t=""
    # Canonicalise before walking. dirname "." is ".", so a relative start path
    # never changes and the loop below spins forever. Single-file mode hands us
    # whatever path the caller passed, and a scan started from a directory yields
    # "./file.mkv", so this is reachable in normal use, not a corner case.
    orig=$(cd "${1:-.}" 2>/dev/null && pwd) || orig=""
    d="$orig"
    while [[ -n "$d" && "$d" != "/" ]]; do
        f=$(find "$d" -maxdepth 1 -type f \( -iname 'series.nfo' -o -iname 'tvshow.nfo' \) -print -quit 2>/dev/null)
        if [[ -n "$f" ]]; then
            # Prefer the title recorded in the series NFO itself. The folder name
            # is only a fallback, because the directory holding the NFO can be
            # named for the show, for a season, or for a release group.
            t=$(xml_get "$f" "/*/title")
            [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
            basename "$d"
            return 0
        fi
        d=$(dirname "$d")
    done
    # No series NFO anywhere above the episode: fall back to the parent of the
    # episode's own folder, computed from the canonical path so it cannot
    # degrade to ".".
    [[ -n "$orig" ]] && basename "$(dirname "$orig")" && return 0
    printf '%s' "${1:-}"
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
tmpfile=$(mktemp)

if [[ -n "$TARGET" ]]; then
    # Single-file mode. The extras filters below are deliberately NOT applied:
    # an explicit argument is explicit intent, and a caller that just produced
    # the file has already filtered it. The work list is still NUL-delimited so
    # the processing loop is the same code either way, which also means a path
    # containing a space needs no special handling.
    if [[ ! -f "$TARGET" ]]; then
        echo "Not a readable file: $TARGET" >&2
        exit 1
    fi
    case "$TARGET" in
        *.mkv) ;;
        *) echo "Not an MKV: $TARGET" >&2; exit 1 ;;
    esac
    log INFO "Single file: $TARGET"
    printf '%s\0' "$TARGET" > "$tmpfile"
else
    log INFO "Scanning for MKV files..."
    # Suffix extras (setreleasedate list) and Jellyfin extras directories are both
    # excluded: a promo can be flagged by name or by the folder it sits in, and the
    # live tree uses capitalised Trailers/Extras, so -path (case-sensitive) would
    # miss every one of them -- hence -ipath.
    find . -type f -iname '*.mkv' \
    ! -iname '*-trailer.*' \
    ! -iname '*-behindthescenes.*' \
    ! -iname '*-featurette.*' \
    ! -iname '*-interview.*' \
    ! -iname '*-scene.*' \
    ! -iname '*-short.*' \
    ! -iname '*-deleted.*' \
    ! -iname '*-sample.*' \
    ! -ipath '*/behind the scenes/*' \
    ! -ipath '*/deleted scenes/*' \
    ! -ipath '*/interviews/*' \
    ! -ipath '*/scenes/*' \
    ! -ipath '*/samples/*' \
    ! -ipath '*/shorts/*' \
    ! -ipath '*/featurettes/*' \
    ! -ipath '*/clips/*' \
    ! -ipath '*/other/*' \
    ! -ipath '*/extras/*' \
    ! -ipath '*/trailers/*' \
    ! -ipath '*/theme-music/*' \
        ! -ipath '*/backdrops/*' \
        -print0 > "$tmpfile"
fi

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
            log WARN "Invalid XML in NFO -- ignoring: $nfo"
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

        # Field-based classification fallback. The root element alone is not a
        # reliable discriminator, because not every NFO writer emits the
        # Sonarr/Radarr root. The field set still identifies the content: an
        # episode NFO carries showtitle, or at least a season number, while a
        # movie NFO carries a bare title with neither. Probing the fields lets an
        # unrecognised root classify correctly instead of being discarded.
        if [[ "$root" != "movie" && "$root" != "episodedetails" ]]; then
            if [[ -n "$(xml_get "$nfo_clean" '/*/showtitle')" || -n "$(xml_get "$nfo_clean" '/*/season')" ]]; then
                root="episodedetails"
            elif [[ -n "$(xml_get "$nfo_clean" '/*/title')" ]]; then
                root="movie"
            fi
        fi

        # XPaths are rooted at the detected element rather than hardcoded, so a
        # non-standard root still extracts its own fields.
        xp="/$root"

        case "$root" in
            movie)
                TYPE="MOVIE"
                title=$(xml_get "$nfo_clean" "$xp/title")
                plot=$(xml_get "$nfo_clean" "$xp/plot")
                premiered=$(xml_get "$nfo_clean" "$xp/premiered")
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
                showtitle=$(xml_get "$nfo_clean" "$xp/showtitle")
                etitle=$(xml_get "$nfo_clean" "$xp/title")
                season=$(xml_get "$nfo_clean" "$xp/season")
                episode=$(xml_get "$nfo_clean" "$xp/episode")
                plot=$(xml_get "$nfo_clean" "$xp/plot")
                aired=$(xml_get "$nfo_clean" "$xp/aired")
                year="${aired:0:4}"

                [[ -z "$showtitle" ]] && showtitle=$(resolve_series_root "$dir")
                showtitle=$(trim_trailing_dash "$showtitle")
                [[ -z "$etitle" ]] && etitle="Episode $episode"
                etitle=$(trim_trailing_dash "$etitle")

                s=$(printf '%02d' "$season")
                e=$(printf '%02d' "$episode")

                new_title="$showtitle $EN_DASH S${s}E${e} $EN_DASH $etitle"

                TAGS[TITLE]="$etitle"
                TAGS[DESCRIPTION]="$plot"
                TAGS[SERIES]="$showtitle"
                TAGS[SHOW]="$showtitle"
                TAGS[SEASON]="$season"
                TAGS[EPISODE]="$episode"
                TAGS[DATE_RELEASED]="$year"
                TAGS[AIRED]="$aired"
                ;;

            *)
                log WARN "Unknown NFO root <$root> -- skipping tags"
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
            ex_title=$(xmlstarlet sel -t -v "//Tag[not(Targets/TargetTypeValue='70')]//Simple[Name='TITLE']/String" "$tags_tmp" 2>/dev/null)
            ex_series=$(xmlstarlet sel -t -v "//Simple[Name='SERIES']/String" "$tags_tmp" 2>/dev/null)
            ex_show=$(xmlstarlet sel -t -v "//Simple[Name='SHOW']/String" "$tags_tmp" 2>/dev/null)
            ex_season=$(xmlstarlet sel -t -v "//Simple[Name='SEASON']/String" "$tags_tmp" 2>/dev/null)
            ex_episode=$(xmlstarlet sel -t -v "//Simple[Name='EPISODE']/String" "$tags_tmp" 2>/dev/null)
            ex_desc=$(xmlstarlet sel -t -v "//Simple[Name='DESCRIPTION']/String" "$tags_tmp" 2>/dev/null)

            if [[ "$TYPE" == "EPISODE" ]]; then
                if [[ "$ex_series" == "$showtitle" &&
                      "$ex_show" == "$showtitle" &&
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
