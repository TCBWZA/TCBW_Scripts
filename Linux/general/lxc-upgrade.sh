#!/bin/bash

echo "pve update"

apt update && apt upgrade -y && apt autoremove -y

echo "Starting LXC update process..."

JOBS=3
CTIDS=$(pct list | awk 'NR>1 {print $1}')

# The container list is the entire point of this run. If pct list came back empty
# the loop below would do nothing and still report every container as updated, so
# abort loudly instead and let the caller see a non-zero status.
if [[ -z "${CTIDS// /}" ]]; then
    echo "ERROR: pct list returned no containers -- aborting, nothing was updated." >&2
    exit 1
fi

# Hard ceiling, in seconds, on a single container's app update and on each of its
# addon updates. A run that exceeds it is killed and reported, never waited on.
UPDATE_TIMEOUT=1800

# Hard ceiling on stopping a container this script started. A container whose init
# is already dead can deadlock lxc-stop indefinitely: observed on CT 103, where
# `lxc-stop --kill` sat blocked on a socket read for minutes while PVE still
# reported the container running and no PID existed. Left unbounded that stalled the
# whole stop loop and left every later container running. It does not abort the run,
# because the updates have already completed by this point -- a container that will
# not stop is reported, not treated as a failed update.
STOP_TIMEOUT=300

# Temp file to track containers started by this script
STARTED_FILE="/tmp/lxc-started-$$.list"
: > "$STARTED_FILE"

###############################################
# Detect package manager inside the container #
###############################################
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo apt
    elif command -v apk >/dev/null 2>&1; then
        echo apk
    elif command -v dnf >/dev/null 2>&1; then
        echo dnf
    elif command -v yum >/dev/null 2>&1; then
        echo yum
    elif command -v pacman >/dev/null 2>&1; then
        echo pacman
    elif command -v xbps-install >/dev/null 2>&1; then
        echo xbps
    else
        echo unknown
    fi
}

###############################################
# Run updates based on detected package mgr   #
###############################################
run_updates() {
    CTID="$1"
    PKG="$2"

    case "$PKG" in
        apt)
            pct exec "$CTID" -- bash -c "apt-get update && apt-get -y upgrade && apt-get -y autoremove"
            ;;
        apk)
            pct exec "$CTID" -- sh -c "apk update && apk upgrade"
            ;;
        dnf)
            pct exec "$CTID" -- bash -c "dnf -y upgrade"
            ;;
        yum)
            pct exec "$CTID" -- bash -c "yum -y update"
            ;;
        pacman)
            pct exec "$CTID" -- bash -c "pacman -Syu --noconfirm"
            ;;
        xbps)
            pct exec "$CTID" -- sh -c "xbps-install -Su -y"
            ;;
        *)
            echo "Unknown package manager in CT $CTID -- skipping updates"
            ;;
    esac
}

###############################################
# Update a single container                   #
###############################################
update_container() {
    CTID="$1"
    LOGFILE="/var/log/lxc-update-$CTID.log"
    STARTED_FILE="$2"

    echo "----------------------------------------"
    echo "Updating container $CTID"

    # Start container if stopped
    if pct status "$CTID" | grep -q "stopped"; then
        echo "Container $CTID was stopped. Starting..."
        pct start "$CTID"
        echo "$CTID" >> "$STARTED_FILE"
        sleep 60
    fi

    # Detect package manager
    echo "Detecting package manager for CT $CTID..."
    PKG=$(pct exec "$CTID" -- bash -c "$(declare -f detect_pkg_manager); detect_pkg_manager")
    echo "Package manager detected: $PKG"

    # Run updates
    echo "Running updates inside container $CTID..."
    run_updates "$CTID" "$PKG" > "$LOGFILE" 2>&1

    # Run container-provided update command.
    # Unattended by construction, so no upstream change to the app script can turn
    # this into an interactive run or a hang:
    #   < /dev/null  makes [ -t 0 ] false, so a TTY-gated menu never renders and the
    #                 three parallel jobs cannot steal each other's stdin
    #   TERM=xterm   keeps a working terminfo entry. It must NOT be dumb or unset:
    #                 either makes the helper's exit-time `clear` fail, which aborts
    #                 the whole update with rc=1. The menu needs no help from TERM,
    #                 because [ -t 0 ] is already false above.
    #   timeout      sets a hard bound, so a hang is killed and reported
    if pct exec "$CTID" -- test -x /usr/bin/update; then
        echo "Running container custom update command (/usr/bin/update)..."
        pct exec "$CTID" -- env TERM=xterm timeout -k 30 "$UPDATE_TIMEOUT" /usr/bin/update \
            < /dev/null >> "$LOGFILE" 2>&1
        rc=$?
        if (( rc == 124 || rc == 137 )); then
            echo "WARNING: /usr/bin/update timed out after ${UPDATE_TIMEOUT}s in CT $CTID -- see $LOGFILE"
        elif (( rc != 0 )); then
            echo "WARNING: /usr/bin/update exited rc=$rc in CT $CTID -- see $LOGFILE"
        fi

        # The app script only runs addons when it can ask about them, and it reads
        # that answer from /dev/tty, which does not exist under pct exec -- so it
        # silently skips every addon. Invoke them directly so they are never
        # dropped. Each gets its own timeout, so one stuck addon cannot block the
        # rest or the job slot.
        pct exec "$CTID" -- env TERM=xterm ADDON_TIMEOUT="$UPDATE_TIMEOUT" bash -c '
            shopt -s nullglob
            addons=(/usr/local/bin/update_*)
            (( ${#addons[@]} )) || exit 0
            for a in "${addons[@]}"; do
                n="${a##*/update_}"
                echo "--- addon: $n ---"
                timeout -k 30 "$ADDON_TIMEOUT" bash "$a" || echo "addon $n failed or timed out (rc=$?)"
            done
        ' < /dev/null >> "$LOGFILE" 2>&1
    else
        echo "No /usr/bin/update command found in CT $CTID"
    fi

    # APT-only reboot detection
    if [[ "$PKG" == "apt" ]]; then
        if pct exec "$CTID" -- test -f /var/run/reboot-required; then
            echo "Reboot required for container $CTID. Rebooting..."
            # Prefer `pct reboot` over `pct exec -- reboot`. Both do recycle a
            # systemd guest -- verified on CT 102, where a guest reboot replaced
            # PID 1 and PVE never reported the container as stopped. But the guest
            # form returns the moment the reboot is REQUESTED, so the run carries
            # on while the container is still coming back, and it depends on the
            # guest init honouring reboot at all rather than on a Proxmox
            # guarantee. `pct reboot` blocks on the PVE task until the container
            # is running again and reports whether that actually happened.
            if ! pct reboot "$CTID"; then
                echo "WARNING: pct reboot returned non-zero for CT $CTID"
            fi

            echo "Waiting for container $CTID to come back online..."
            restarted=0
            for i in {1..60}; do
                if pct status "$CTID" | grep -q "running"; then
                    restarted=1
                    break
                fi
                sleep 2
            done
            if (( restarted == 0 )); then
                echo "WARNING: container $CTID did not return to running within 120s of reboot -- check $CTID manually"
            fi
        fi
    fi

    echo "Finished updating container $CTID"
}

export -f update_container
export -f detect_pkg_manager
export -f run_updates

# The parallel dispatch below runs each container in a `bash -c`, so these three
# functions only cross into that process because they were exported. The timeouts are
# NOT functions, and a plain shell variable does NOT cross that boundary: an
# unexported UPDATE_TIMEOUT arrived empty, timeout rejected the blank interval, and
# every container exited rc=125 having updated nothing at all. Exported here for the
# same reason, so the same failure cannot recur.
export UPDATE_TIMEOUT
export STOP_TIMEOUT

###############################################
# Parallel update execution                   #
###############################################
for CTID in $CTIDS; do
    bash -c "update_container $CTID $STARTED_FILE" &

    while (( $(jobs -r | wc -l) >= JOBS )); do
        sleep 1
    done
done

wait

###############################################
# Stop containers that were started by script #
###############################################
echo "----------------------------------------"
echo "Stopping containers that were started by this script..."

if [[ -s "$STARTED_FILE" ]]; then
    while read -r CTID; do
        echo "Stopping container $CTID"
        timeout -k 10 "$STOP_TIMEOUT" pct stop "$CTID"
        rc=$?
        if (( rc == 124 || rc == 137 )); then
            echo "WARNING: pct stop did not return within ${STOP_TIMEOUT}s for CT $CTID -- it is most likely still running and needs clearing by hand" >&2
        elif (( rc != 0 )); then
            echo "WARNING: pct stop exited rc=$rc for CT $CTID" >&2
        fi
    done < "$STARTED_FILE"
else
    echo "No containers were started by this script."
fi

rm -f "$STARTED_FILE"

echo "All LXC containers updated."
