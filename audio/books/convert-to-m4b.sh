#!/usr/bin/env bash
#
# convert-to-m4b.sh -- fold each single-format audiobook folder into one .m4b.
#
# For every book folder that holds exactly one audio media type (mp3, flac,
# ogg, opus, wav, aac, wma; m4b/m4a are treated as already-book containers):
#   - order the files by playlist.ll when it is complete, else by version sort
#   - refuse folders whose "NN of NN" naming declares parts that are missing
#   - concatenate and re-encode to a single AAC .m4b (64k, source layout)
#   - embed one chapter per source file, plus cover and tags from metadata.json
#   - verify the result, then move the source files to an archive tree
# Folders that fail an audit -- more than one audio media type in the folder
# (e.g. ogg alongside flac, mp3 alongside m4b), or an "NN of NN" naming that
# does not match the file count -- are never touched and are written to the
# audit-failure report as corruption.
#
# Dry-run by default. Pass --apply to make changes.

set -u -o pipefail

ROOT="/main/media/audiobooks"
ARCHIVE="/main/media/audiobooks_mp3"
AUDIT="/tmp/convert-to-m4b-audit.txt"
ONLY=""
LIMIT=0
APPLY=0
BITRATE="64k"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --apply             make changes (default is dry-run)
  --root DIR          library root (default: $ROOT)
  --archive DIR       where source files are moved (default: $ARCHIVE)
  --audit FILE        audit-failure report path (default: $AUDIT)
  --only FILE         process only the book dirs listed in FILE (one per line)
  --limit N           stop after N candidate folders
  -h, --help          this help
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Abort early when a tool the encode/verify path needs is missing.
check_prereqs() {
    local tool missing=0
    # shellcheck disable=SC2016
    while IFS= read -r tool; do
        command -v "$tool" >/dev/null 2>&1 || { warn "missing required tool: $tool"; missing=1; }
    done < <(printf '%s\n' ffmpeg ffprobe python3 jq)
    if [[ $missing -eq 1 ]]; then
        warn "install the missing tools and re-run"
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --root) ROOT="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --audit) AUDIT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

check_prereqs

AUDIO_FIND=(
    -iname '*.mp3' -o -iname '*.m4b' -o -iname '*.m4a'
    -o -iname '*.flac' -o -iname '*.ogg' -o -iname '*.opus'
    -o -iname '*.wav' -o -iname '*.aac' -o -iname '*.wma'
)

# Distinct audio media types in a folder, one lowercase extension per line.
audio_types() {
    find "$1" -maxdepth 1 -type f \( "${AUDIO_FIND[@]}" \) -printf '%f\n' \
        | sed 's/.*\.//I' | tr '[:upper:]' '[:lower:]' | sort -u
}

# True when an extension is a source format we fold into m4b. m4b/m4a are
# themselves book containers and are never re-encoded.
is_source_type() {
    case "$1" in
        mp3|flac|ogg|opus|wav|aac|wma) return 0 ;;
        *) return 1 ;;
    esac
}

# Numeric part index for a filename: the number before "of NN" when present,
# else the first integer run. 0 when the name carries no number. Sorting on
# this (not the whole name) keeps order correct when a series/book number leads
# the name, and when the part number widens from NN to NNN.
part_number() {
    local name="${1%.*}" n
    n=$(printf '%s' "$name" | grep -oiE '[0-9]+[._ -]+of[._ -]+[0-9]+' \
        | head -1 | grep -oE '^[0-9]+')
    if [[ -z "$n" ]]; then
        n=$(printf '%s' "$name" | grep -oE '[0-9]+' | head -1)
    fi
    printf '%d' "$((10#${n:-0}))"
}

# Print the files in play order: playlist.ll when complete, else by part number.
ordered_files() {
    local dir="$1" src="$2" pl="$1/playlist.ll" f
    if [[ -f "$pl" ]]; then
        local complete=1 listed=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ -f "$dir/$f" ]] || { complete=0; break; }
            listed=$((listed + 1))
        done < "$pl"
        local actual
        actual=$(find "$dir" -maxdepth 1 -type f -iname "*.$src" | wc -l)
        if [[ $complete -eq 1 && $listed -eq $actual ]]; then
            sed "s|^|$dir/|" "$pl"
            return 0
        fi
    fi
    find "$dir" -maxdepth 1 -type f -iname "*.$src" -printf '%f\n' \
        | while IFS= read -r f; do
            printf '%010d\t%s\n' "$(part_number "$f")" "$f"
        done \
        | sort -k1,1n -k2,2V \
        | cut -f2- \
        | sed "s|^|$dir/|"
}

# Return an audit-failure reason for a folder that must not be converted, or
# nothing when the folder is safe to convert. Corrupt folders: more than one
# audio media type present (duplicate/questionable content -- the folder could
# hold the book twice in different encodings). Then, for single-source
# folders: a declared "NN of NN" count that exceeds the files present
# (incomplete), or one that is exceeded by the files present (duplicate
# renditions -- e.g. two numbering schemes of the same parts).
audit_failure() {
    local dir="$1" types="$2" src count
    count=$(printf '%s\n' "$types" | grep -c .)
    if [[ "$count" -gt 1 ]]; then
        printf 'corruption: multiple media types present (%s)' \
            "$(printf '%s' "$types" | tr '\n' ' ' | sed 's/ $//')"
        return 0
    fi
    src="$types"
    if ! is_source_type "$src"; then
        return 0
    fi
    local declared actual
    declared=$(find "$dir" -maxdepth 1 -type f -iname "*.$src" -printf '%f\n' \
        | grep -oiE 'of[._ -]+[0-9]+' | grep -oE '[0-9]+' \
        | sed 's/^0*//' | sort -n | tail -1)
    [[ -z "$declared" ]] && return 0
    actual=$(find "$dir" -maxdepth 1 -type f -iname "*.$src" | wc -l)
    if [[ "$declared" -gt "$actual" ]]; then
        printf 'incomplete: names declare %s parts, %s present (%s missing)' \
            "$declared" "$actual" "$((declared - actual))"
    elif [[ "$actual" -gt "$declared" ]]; then
        printf 'duplicate renditions: names declare %s parts, %s present (%s surplus)' \
            "$declared" "$actual" "$((actual - declared))"
    fi
}

# First cover.* file, else the first image sidecar.
pick_cover() {
    local dir="$1" c
    for c in cover.jpg cover.jpeg cover.png cover.JPG cover.PNG; do
        [[ -f "$dir/$c" ]] && { printf '%s' "$dir/$c"; return 0; }
    done
    find "$dir" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
        -printf '%p\n' | sort | head -1
}

# Final .m4b name: book folder name with a trailing (YYYY)/()/[UID] stripped.
output_name() {
    local base name
    base=$(basename "$1")
    name=$(printf '%s' "$base" | sed -E 's/ +\(([0-9]{4})?\)$//; s/ +\[[^][]*\]$//')
    [[ -z "$name" ]] && name="$base"
    printf '%s/%s.m4b' "$1" "$name"
}

# Build an ffmpeg ffmetadata file (tags + one chapter per file); print total
# seconds. A separate helper keeps JSON and filename escaping out of bash.
build_ffmeta() {
    local listfile="$1" metafile="$2" out="$3"
    python3 - "$listfile" "$metafile" "$out" <<'PY'
import json, subprocess, sys

listfile, metafile, out = sys.argv[1], sys.argv[2], sys.argv[3]
files = [l.rstrip("\n") for l in open(listfile, encoding="utf-8", errors="replace") if l.strip()]

def esc(v):
    v = str(v).replace("\\", "\\\\").replace("\n", " ").replace("\r", " ")
    return v.replace(";", "\\;").replace("#", "\\#").replace("=", "\\=")

def dur(path):
    r = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0",
         "-show_entries", "format=duration", "-of", "csv=p=0", path],
        capture_output=True, text=True)
    return float(r.stdout.strip()) if r.stdout.strip() else 0.0

tags = {}
if metafile and __import__("os").path.isfile(metafile):
    try:
        tags = json.load(open(metafile, encoding="utf-8", errors="replace"))
    except Exception:
        tags = {}

def joined(key):
    v = tags.get(key)
    if isinstance(v, list):
        return ", ".join(str(x) for x in v if x)
    return "" if v is None else str(v)

def first(key):
    v = tags.get(key)
    if isinstance(v, list):
        return str(v[0]) if v else ""
    return "" if v is None else str(v)

lines = [";FFMETADATA1"]
for k, v in (("title", joined("title")), ("album", joined("title")),
             ("artist", joined("authors")), ("album_artist", joined("authors")),
             ("date", joined("publishedYear")), ("genre", first("genres")),
             ("comment", joined("narrators"))):
    if v:
        lines.append(f"{k}={esc(v)}")

total_ms = 0
for path in files:
    d = dur(path)
    start = total_ms
    total_ms += int(round(d * 1000))
    title = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
    lines += ["[CHAPTER]", "TIMEBASE=1/1000",
              f"START={start}", f"END={total_ms}", f"title={esc(title)}"]

open(out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(f"{total_ms/1000.0:.3f}")
PY
}

# Concatenate, re-encode to AAC, attach cover and chapters, write an .m4b.
encode() {
    local listfile="$1" cover="$2" ffmeta="$3" out="$4"
    local -a args=(-hide_banner -loglevel error -nostdin -y
        -f concat -safe 0 -i "$listfile")
    local meta_idx=1 cover_idx=-1
    if [[ -n "$cover" ]]; then
        args+=(-i "$cover")
        cover_idx=1
        meta_idx=2
    fi
    args+=(-i "$ffmeta")
    args+=(-map 0:a)
    [[ $cover_idx -ge 0 ]] && args+=(-map "$cover_idx:v")
    args+=(-map_metadata "$meta_idx" -map_chapters "$meta_idx")
    args+=(-c:a aac -b:a "$BITRATE")
    [[ $cover_idx -ge 0 ]] && args+=(-c:v mjpeg -disposition:v attached_pic)
    args+=(-movflags +faststart -f ipod "$out")
    ffmpeg "${args[@]}"
}

probe_duration() {
    ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null
}

probe_chapters() {
    ffprobe -v error -print_format json -show_chapters "$1" 2>/dev/null \
        | jq '.chapters | length'
}

MAIN_TMP=$(mktemp -d)
cleanup() { rm -rf "$MAIN_TMP"; }
trap cleanup EXIT

if [[ -n "$ONLY" ]]; then
    mapfile -t DIRS < <(grep -v '^[[:space:]]*$' "$ONLY")
else
    mapfile -t DIRS < <(find "$ROOT" -type f \( "${AUDIO_FIND[@]}" \) -printf '%h\n' | sort -u)
fi

mode="DRY-RUN"; [[ $APPLY -eq 1 ]] && mode="APPLY"
log "mode=$mode root=$ROOT archive=$ARCHIVE"
log "book folders with audio media: ${#DIRS[@]}"
: > "$AUDIT"

cand=0 converted=0 failed=0 audited=0 skipped=0
for dir in "${DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    types=$(audio_types "$dir")
    src="$types"

    reason=$(audit_failure "$dir" "$types")
    if [[ -n "$reason" ]]; then
        printf '%s\t%s\n' "$dir" "$reason" >> "$AUDIT"
        log "[audit failure] $reason :: $dir"
        audited=$((audited + 1))
        continue
    fi

    if ! is_source_type "$src"; then
        skipped=$((skipped + 1))
        continue
    fi

    mapfile -t files < <(ordered_files "$dir" "$src")
    if [[ ${#files[@]} -eq 0 ]]; then
        skipped=$((skipped + 1))
        continue
    fi

    if [[ $LIMIT -gt 0 && $cand -ge $LIMIT ]]; then
        log "limit reached ($LIMIT candidates)"
        break
    fi
    cand=$((cand + 1))

    out=$(output_name "$dir")
    if [[ $APPLY -eq 0 ]]; then
        log "[dry-run] ${#files[@]} $src -> $(basename "$out") :: $dir"
        continue
    fi

    pathsfile="$MAIN_TMP/paths.txt"
    listfile="$MAIN_TMP/list.txt"
    : > "$pathsfile"
    : > "$listfile"
    for f in "${files[@]}"; do
        printf '%s\n' "$f" >> "$pathsfile"
        printf "file '%s'\n" "${f//\'/\'\\\'\'}" >> "$listfile"
    done

    cover=$(pick_cover "$dir")
    ffmeta="$MAIN_TMP/ffmeta.txt"
    if ! expected=$(build_ffmeta "$pathsfile" "$dir/metadata.json" "$ffmeta"); then
        warn "metadata build failed: $dir"
        failed=$((failed + 1))
        continue
    fi

    partial="$dir/.convert-to-m4b.partial"
    rm -f "$partial"
    if ! encode "$listfile" "$cover" "$ffmeta" "$partial" 2>"$MAIN_TMP/ffmpeg.err"; then
        warn "ffmpeg failed: $dir"
        sed 's/^/    /' "$MAIN_TMP/ffmpeg.err" >&2
        rm -f "$partial"
        failed=$((failed + 1))
        continue
    fi

    got=$(probe_duration "$partial")
    gotch=$(probe_chapters "$partial")
    tol=$(awk -v e="$expected" 'BEGIN{t=e*0.01; if(t<2)t=2; printf "%.3f", t}')
    ok=1
    if [[ -z "$got" || -z "$gotch" ]]; then ok=0; fi
    if [[ "$gotch" != "${#files[@]}" ]]; then ok=0; fi
    if ! awk -v a="$got" -v b="$expected" -v t="$tol" 'BEGIN{d=a-b; if(d<0)d=-d; exit (d>t)}'; then ok=0; fi
    if [[ $ok -eq 0 ]]; then
        warn "verify failed: $dir (dur=$got want=$expected chap=$gotch want=${#files[@]})"
        rm -f "$partial"
        failed=$((failed + 1))
        continue
    fi

    if ! mv -f "$partial" "$out"; then
        warn "output move failed: $dir"
        rm -f "$partial"
        failed=$((failed + 1))
        continue
    fi
    rel="${dir#"$ROOT"/}"
    if ! mkdir -p "$ARCHIVE/$rel"; then
        warn "archive mkdir failed, output written but sources left in place: $dir"
        failed=$((failed + 1))
        continue
    fi
    mv_fail=0
    for f in "${files[@]}"; do
        mv -f "$f" "$ARCHIVE/$rel/" || mv_fail=1
    done
    if [[ $mv_fail -ne 0 ]]; then
        warn "source move incomplete, check $dir and $ARCHIVE/$rel"
        failed=$((failed + 1))
        continue
    fi
    converted=$((converted + 1))
    log "[ok] ${#files[@]} $src -> $(basename "$out") ($got s) :: $dir"
done

log "---"
log "candidates=$cand converted=$converted audit_failures=$audited skipped=$skipped failed=$failed"
log "audit-failure report: $AUDIT ($audited entries)"
