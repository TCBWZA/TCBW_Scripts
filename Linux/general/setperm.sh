#!/usr/bin/env bash
set -uo pipefail

# Usage: ./setperm.sh [-n] [target_dir]
# -n : dry-run (show what would be done)
# target_dir : directory to operate on (default: /main/media/Video)

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

# Ensure target exists
if [ ! -d "$TARGET" ]; then
  echo "Error: target directory '$TARGET' does not exist." >&2
  exit 1
fi

# Ensure UID/GID 1000 exist (warn if not)
# We prefer numeric UID/GID 1000 so the script can be run inside containers
# where the unprivileged user maps to UID 1000.
if ! getent passwd | awk -F: '$3==1000 {exit 0} END{exit 1}'; then
  echo "Warning: no local user has UID 1000; numeric UID 1000 will be used." >&2
fi

if ! getent group | awk -F: '$3==1000 {exit 0} END{exit 1}'; then
  echo "Warning: no local group has GID 1000; numeric GID 1000 will be used." >&2
fi

# Print or run a command safely
run_or_print() {
  # $1 = command name (e.g., chown, chmod)
  # $2 = mode/owner (e.g., 1000:1000 or 666)
  # $3 = path
  local cmd="$1"
  local arg="$2"
  local path="$3"

  if [ "$DRY_RUN" = true ]; then
    # Use printf '%q' to show a safely quoted representation of the path
    printf '+ %s %s -- %s\n' "$cmd" "$arg" "$(printf '%q' "$path")"
  else
    # Execute the command without eval
    "$cmd" "$arg" -- "$path"
  fi
}

echo "Target directory: $TARGET"
if [ "$DRY_RUN" = true ]; then
  echo "Dry-run mode enabled. No changes will be made."
fi

# 1) Change ownership for directories and for files except *.sh
find "$TARGET" \( -type d -o \( -type f ! -name '*.sh' \) \) -print0 \
  | while IFS= read -r -d '' item; do
      run_or_print chown 1000:1000 "$item"
    done

# 2) Set file permissions to 666 for files except *.sh
find "$TARGET" -type f ! -name '*.sh' -print0 \
  | while IFS= read -r -d '' file; do
      run_or_print chmod 666 "$file"
    done

# 3) Set directory permissions to 777
find "$TARGET" -type d -print0 \
  | while IFS= read -r -d '' dir; do
      run_or_print chmod 777 "$dir"
    done

echo "Done."
