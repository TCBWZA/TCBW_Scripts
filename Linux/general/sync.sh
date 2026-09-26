#!/bin/bash
set -uo pipefail

echo "=== POWERING ON USB DRIVE ==="
usb-poweron.sh

echo "=== STARTING SYNC JOBS ==="

# Each job is an independent target: run them all, then report every failure.
JOBS=(
    ./sync_backups.sh
    ./sync_docker.sh
    ./sync_anime.sh
    ./sync_audiobooks.sh
    ./sync_books.sh
    ./sync_movies.sh
    # ./sync_etv.sh
    ./sync_sysdocker_maindocker.sh
    ./sync_tv.sh
)

FAILED=()

for job in "${JOBS[@]}"; do
    echo "--- $job"
    if ! "$job"; then
        FAILED+=("$job")
        echo "!!! FAILED: $job" >&2
    fi
done

echo "=== POWERING OFF USB DRIVE ==="
usb-poweroff.sh

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "=== SYNC FINISHED WITH ${#FAILED[@]} FAILURE(S) ===" >&2
    printf '    failed: %s\n' "${FAILED[@]}" >&2
    exit 1
fi

echo "=== ALL SYNC JOBS COMPLETE ==="
echo "=== BACKUP PROCESS COMPLETE ==="
