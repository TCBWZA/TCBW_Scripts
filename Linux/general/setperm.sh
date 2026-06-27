#!/usr/bin/env bash
set -uo pipefail

DRY_RUN=false
TARGET="/main/media/Video"

while getopts "n" opt; do
  case "$opt" in
    n) DRY_RUN=true ;;
    *) echo "Usage: $0 [-n] [target_dir]"; exit 2 ;;
  esac
done
shift $((OPTIND-1))
if [ $# -ge 1 ]; then
  TARGET="$1"
fi

# Safety guard
case "$TARGET" in
  "/"|"/main"|"/main/media")
    echo "Refusing to operate on unsafe directory: $TARGET" >&2
    exit 1
    ;;
esac

if [ ! -d "$TARGET" ]; then
  echo "Error: target directory '$TARGET' does not exist." >&2
  exit 1
fi

# Ensure UID/GID 1000 exist
if ! id -u 1000 >/dev/null 2>&1; then
  echo "Error: UID 1000 does not exist on this system." >&2
  exit 1
fi

if ! getent group 1000 >/dev/null 2>&1; then
  echo "Error: GID 1000 does not exist on this system." >&2
  exit 1
fi

echo "Target directory: $TARGET"
$DRY_RUN && echo "Dry-run mode enabled."

#############################################
# 1) Ownership (dirs + non-.sh files)
#############################################

if [ "$DRY_RUN" = true ]; then
  ionice -c3 nice -n 19 find "$TARGET" \
  \( ! -uid 1000 -o ! -gid 1000 \) \
  \( -type d -o \( -type f ! -name '*.sh' ! -name '*.tmp' \) \) -print0 |
  xargs -0 -P 2 -I{} printf '+ chown 1000:1000 %q\n' "{}"
else
  ionice -c3 nice -n 19 find "$TARGET" \
  \( ! -uid 1000 -o ! -gid 1000 \) \
  \( -type d -o \( -type f ! -name '*.sh' ! -name '*.tmp' \) \) -print0 |
  xargs -0 -P 2 -I{} chown 1000:1000 "{}"
fi

#############################################
# 2) File perms (666)
#############################################

if [ "$DRY_RUN" = true ]; then
  ionice -c3 nice -n 19 find "$TARGET" -type f ! -perm 666 ! -name '*.sh' ! -name '*.tmp' -print0 |
  xargs -0 -P 2 -I{} printf '+ chmod 666 %q\n' "{}"
else
  ionice -c3 nice -n 19 find "$TARGET" -type f ! -perm 666 ! -name '*.sh' ! -name '*.tmp' -print0 |
  xargs -0 -P 2 -I{} chmod 666 "{}"
fi

#############################################
# 3) Directory perms (777)
#############################################

if [ "$DRY_RUN" = true ]; then
  ionice -c3 nice -n 19 find "$TARGET" -type d ! -perm 777 -print0 |
  xargs -0 -P 2 -I{} printf '+ chmod 777 %q\n' "{}"
else
  ionice -c3 nice -n 19 find "$TARGET" -type d ! -perm 777 -print0 |
  xargs -0 -P 2 -I{} chmod 777 "{}"
fi

echo "Done."
