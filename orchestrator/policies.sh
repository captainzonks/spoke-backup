#!/usr/bin/env bash
# ==============================================================================
# BACKUP ORCHESTRATOR - KOPIA PER-SOURCE POLICIES
# ==============================================================================
# Description: Sets Kopia ignore patterns per source path so regenerable cache,
#              transcoded media, and other low-value bulk data are excluded
#              from snapshots. Also sets a global GFS retention policy.
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-05-06
# Version: 1.1.0
# Host: Your Server
# ==============================================================================
# Idempotent: `kopia policy set` overwrites the named policy on each run.
# Source paths are addressed by their local filesystem paths (/sources/...).
# Kopia uses the container hostname as the snapshot owner (shown in `kopia snapshot list`).
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

    # Per-source exclude patterns for /sources/appdata.
    # Provide your own list by bind-mounting a file at /etc/backup/appdata-excludes.conf
    # in your docker-compose.override.yml. One glob pattern per line; lines starting
    # with # are ignored. Example:
    #   /plex/Library/Application Support/Plex Media Server/Media/
    #   /myapp/cache/
    # If the file is absent or empty, no excludes are applied and all of /sources/appdata
    # is snapshotted. Use `kopia policy show /sources/appdata` to inspect the active set.
    local excludes_conf="/etc/backup/appdata-excludes.conf"
    if [[ -s "$excludes_conf" ]]; then
        log "applying appdata excludes from $excludes_conf"
        local -a ignore_args=()
        local pattern
        local pattern_count=0
        while IFS= read -r pattern; do
            [[ -z "$pattern" || "$pattern" == \#* ]] && continue
            ignore_args+=(--add-ignore "$pattern")
            pattern_count=$((pattern_count + 1))
        done < "$excludes_conf"
        if [[ "$pattern_count" -gt 0 ]]; then
            kopia policy set /sources/appdata "${ignore_args[@]}"
            log "applied ${pattern_count} appdata exclude(s)"
        fi
    else
        log "no appdata-excludes.conf found — snapshotting all of /sources/appdata"
    fi

    log "policies applied"
}

main "$@"
