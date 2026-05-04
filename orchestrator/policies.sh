#!/usr/bin/env bash
# ==============================================================================
# BACKUP ORCHESTRATOR - KOPIA PER-SOURCE POLICIES
# ==============================================================================
# Description: Sets Kopia ignore patterns per source path so regenerable cache,
#              transcoded media, and other low-value bulk data are excluded
#              from snapshots. Also sets a global GFS retention policy.
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-04-29
# Version: 1.0.0
# Host: Your Server
# ==============================================================================
# Idempotent: `kopia policy set` overwrites the named policy on each run.
# Source paths are addressed as orchestrator@rome:/sources/... per the
# `--override-hostname=rome --override-username=orchestrator` connect flags.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# Defensive: ensure KOPIA_PASSWORD set when invoked outside entrypoint context.
if [[ -z "${KOPIA_PASSWORD:-}" && -s /run/secrets/kopia_repo_password ]]; then
    export KOPIA_PASSWORD="$(cat /run/secrets/kopia_repo_password)"
fi

readonly LOG_PREFIX="[policies]"

log() {
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$*"
}

require_env() {
    local var
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            printf 'ERROR: required env var %s is unset\n' "$var" >&2
            exit 1
        fi
    done
}

main() {
    require_env \
        BACKUP_RETENTION_DAILY \
        BACKUP_RETENTION_WEEKLY \
        BACKUP_RETENTION_MONTHLY \
        BACKUP_RETENTION_YEARLY

    log "setting global GFS retention policy"
    kopia policy set --global \
        --keep-latest=10 \
        --keep-daily="${BACKUP_RETENTION_DAILY}" \
        --keep-weekly="${BACKUP_RETENTION_WEEKLY}" \
        --keep-monthly="${BACKUP_RETENTION_MONTHLY}" \
        --keep-annual="${BACKUP_RETENTION_YEARLY}" \
        --compression=zstd-fastest

    log "setting policy for /sources/appdata (Plex / Dionysus / Stash / ABS / InfluxDB exclusions)"
    kopia policy set /sources/appdata \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Media/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Metadata/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Cache/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Logs/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Drivers/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Codecs/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Scanners/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Crash Reports/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Diagnostics/' \
        --add-ignore '/plex/Library/Application Support/Plex Media Server/Updates/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Media/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Metadata/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Cache/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Logs/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Drivers/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Codecs/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Scanners/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Crash Reports/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Diagnostics/' \
        --add-ignore '/dionysus/Library/Application Support/Plex Media Server/Updates/' \
        --add-ignore '/stash/generated/' \
        --add-ignore '/stash/pip-install/' \
        --add-ignore '/stash/cache/' \
        --add-ignore '/audiobookshelf/metadata/' \
        --add-ignore '/influxdb3/' \
        --add-ignore '/immich/'

    log "setting policy for /sources/immich (skip regenerable thumbnails / transcodes)"
    kopia policy set /sources/immich \
        --add-ignore 'encoded-video/' \
        --add-ignore 'thumbs/'

    log "policies applied"
}

main "$@"
