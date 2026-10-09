#!/usr/bin/env bash
#
# find_incomplete.sh -- move book folders missing parts out of the library.
#
# A book is incomplete when its single-format filenames (mp3, flac, ogg, opus,
# wav, aac, wma) declare "NN of NN" parts and the highest declared part exceeds
# the file count. Such folders are moved to the same archive the converter uses
# (`audio/books/convert-to-m4b.sh`), with the book folder renamed with an
# INCOMPLETE_ prefix, so the library scan leaves it alone and the source is not
# lost. Folders holding more than one media type are corruption, not incomplete,
# and are left for the converter's audit.
#
# Dry-run by default. Pass --apply to move.

set -u -o pipefail

ROOT="/main/media/audiobooks"
ARCHIVE="/main/media/audiobooks_mp3"
LIMIT=0
APPLY=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  --apply             move folders (default is dry-run)
  --root DIR          library root (default: $ROOT)
  --archive DIR       archive root (default: $ARCHIVE)
  --limit N           stop after N incomplete folders
  -h, --help          this help
EOF
}

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Source formats folded into m4b; m4b/m4a are book containers, not sources.
is_source_type() {
    case "$1" in
        mp3|flac|ogg|opus|wav|aac|wma) return 0 ;;
        *) return 1 ;;
    esac
}

# Distinct source media types in a folder, one lowercase extension per line.
source_types() {
    find "$1" -maxdepth 1 -type f \
        \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.ogg' \
        -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aac' \
        -o -iname '*.wma' \) -printf '%f\n' \
        | sed 's/.*\.//I' | tr '[:upper:]' '[:lower:]' | sort -u
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --root) ROOT="$2"; shift 2 ;;
        --archive) ARCHIVE="$2"; shift 2 ;;
        --limit) LIMIT="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
done

mapfile -t DIRS < <(find "$ROOT" -type f \
    \( -iname '*.mp3' -o -iname '*.flac' -o -iname '*.ogg' \
    -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.aac' \
    -o -iname '*.wma' \) -printf '%h\n' | sort -u)

mode="DRY-RUN"; [[ $APPLY -eq 1 ]] && mode="APPLY"
log "mode=$mode root=$ROOT archive=$ARCHIVE"

found=0 moved=0 collisions=0
for dir in "${DIRS[@]}"; do
    src=$(source_types "$dir")
    [[ "$(printf '%s\n' "$src" | grep -c .)" -eq 1 ]] || continue
    is_source_type "$src" || continue

    declared=$(find "$dir" -maxdepth 1 -type f -iname "*.$src" -printf '%f\n' \
        | grep -oiE 'of[._ -]+[0-9]+' | grep -oE '[0-9]+' \
        | sed 's/^0*//' | sort -n | tail -1)
    [[ -z "$declared" ]] && continue
    actual=$(find "$dir" -maxdepth 1 -type f -iname "*.$src" | wc -l)
    [[ "$declared" -le "$actual" ]] && continue

    found=$((found + 1))
    if [[ $LIMIT -gt 0 && $found -gt $LIMIT ]]; then break; fi

    rel_author=$(dirname "${dir#$ROOT/}")
    book=$(basename "$dir")
    target="$ARCHIVE/$rel_author/INCOMPLETE_$book"
    if [[ -e "$target" ]]; then
        warn "target exists, skipped: $target"
        collisions=$((collisions + 1))
        continue
    fi
    if [[ $APPLY -eq 0 ]]; then
        log "[dry-run] incomplete ($declared declared, $actual present) would move $dir -> $target"
        continue
    fi
    mkdir -p "$ARCHIVE/$rel_author"
    mv -f "$dir" "$target"
    moved=$((moved + 1))
    log "[moved] $dir -> $target"
done

log "---"
log "incomplete=$found moved=$moved collisions=$collisions"