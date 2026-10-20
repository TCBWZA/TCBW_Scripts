#!/bin/bash

# Update host packages and reconcile Docker Compose projects on Raspberry Pi OS.
# Manual run only. Place a .ignore file in a project directory to skip it.

ROOT="${1:-/DATA/AppData}"

FAILURES=0

prereqs() {
    local missing=()
    local tool

    for tool in apt-get docker find grep sudo; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: missing required tools: ${missing[*]}" >&2
        return 1
    fi

    if ! sudo -n true 2>/dev/null; then
        echo "ERROR: passwordless sudo is required for the host update step." >&2
        return 1
    fi
}

update_host() {
    echo "== host packages =="

    if ! sudo apt-get update; then
        echo "ERROR: apt-get update failed." >&2
        return 1
    fi

    if ! sudo apt-get upgrade -y; then
        echo "ERROR: apt-get upgrade failed." >&2
        return 1
    fi

    if ! sudo apt-get autoremove -y; then
        echo "WARN: autoremove failed, continuing." >&2
    fi
}

prune_images() {
    echo "== docker image prune =="

    if ! docker image prune -f; then
        echo "ERROR: docker image prune failed." >&2
        return 1
    fi
}

# Prints the compose filename inside the given directory, or fails.
find_compose_file() {
    local dir=$1
    local candidate

    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [ -f "$dir/$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    # Filename-only matching would miss a compose file using a non-standard name.
    for candidate in "$dir"/*.yml "$dir"/*.yaml; do
        [ -f "$candidate" ] || continue
        if grep -qE '^services:' "$candidate"; then
            printf '%s\n' "${candidate##*/}"
            return 0
        fi
    done

    return 1
}

update_project() {
    local dir=$1
    local file=$2
    local running
    local existing

    echo "== $dir ($file) =="

    if ! (cd "$dir" && docker compose -f "$file" pull); then
        echo "ERROR: pull failed for $dir." >&2
        return 1
    fi

    running=$(cd "$dir" && docker compose -f "$file" ps -q 2>/dev/null)
    existing=$(cd "$dir" && docker compose -f "$file" ps -aq 2>/dev/null)

    # Only recreate a project that is already up; 'docker compose up -d' would
    # otherwise also start a project whose containers were deliberately stopped.
    if [ -z "$running" ]; then
        if [ -n "$existing" ]; then
            echo "SKIP: containers exist but none are running, not starting them."
        else
            echo "SKIP: no containers exist for this project, not starting them."
        fi
        return 0
    fi

    if ! (cd "$dir" && docker compose -f "$file" up -d); then
        echo "ERROR: up -d failed for $dir." >&2
        return 1
    fi
}

main() {
    local dir
    local file
    local name

    if ! prereqs; then
        exit 1
    fi

    if [ ! -d "$ROOT" ]; then
        echo "ERROR: root directory not found: $ROOT" >&2
        exit 1
    fi

    update_host || FAILURES=$((FAILURES + 1))
    prune_images || FAILURES=$((FAILURES + 1))

    echo "== compose projects under $ROOT =="

    for dir in "$ROOT"/*/; do
        [ -d "$dir" ] || continue
        dir=${dir%/}

        if [ -f "$dir/.ignore" ]; then
            echo "SKIP: $dir (.ignore present)"
            continue
        fi

        name=$(find_compose_file "$dir") || continue
        update_project "$dir" "$name" || FAILURES=$((FAILURES + 1))
    done

    if [ -f /var/run/reboot-required ]; then
        echo "WARN: a reboot is required to finish applying updates."
    fi

    if [ "$FAILURES" -gt 0 ]; then
        echo "DONE WITH $FAILURES FAILURE(S)."
        exit 1
    fi

    echo "DONE."
}

main
