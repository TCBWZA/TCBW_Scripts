#!/bin/bash

echo "=== POWERING ON USB DRIVE ==="
usb-poweron.sh

echo "=== STARTING SYNC JOBS ==="

./sync_backups.sh
./sync_docker.sh
./sync_anime.sh
./sync_audiobooks.sh
./sync_books.sh
./sync_movies.sh
./sync_sysdocker_maindocker.sh
./sync_tv.sh

echo "=== ALL SYNC JOBS COMPLETE ==="

echo "=== POWERING OFF USB DRIVE ==="
usb-poweroff.sh

echo "=== BACKUP PROCESS COMPLETE ==="
