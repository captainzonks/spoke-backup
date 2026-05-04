#!/usr/bin/env bash
# ==============================================================================
# BACKUP ORCHESTRATOR - ENTRYPOINT
# ==============================================================================
# Description: Renders crontab from template, registers this container as a
#              Kopia client to the kopia server, applies per-source policies,
#              then hands off to the supplied CMD (typically `crond -f -l 8`).
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-04-29
# Version: 1.0.0
# Host: Your Server
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly LOG_PREFIX="[orchestrator]"

log() {
    printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$*"
}

err() {
    printf '%s %s ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$*" >&2
}

require_env() {
    local var
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            err "required env var $var is unset"
            exit 1
        fi
    done
}

require_secret() {
    local path
    for path in "$@"; do
        if [[ ! -s "$path" ]]; then
            err "required secret missing or empty: $path"
            exit 1
        fi
    done
}

main() {
    log "starting orchestrator"

    require_env \
        TZ \
        KOPIA_API_URL \
        KOPIA_SERVER_USERNAME \
        BACKUP_STAGING_DIR \
        BACKUP_PG_DUMP_HOUR \
        BACKUP_SNAPSHOT_HOUR \
        BACKUP_VERIFY_DAY

    require_secret /run/secrets/kopia_server_password

    mkdir -p /var/log "${BACKUP_STAGING_DIR}/postgres"
    touch /var/log/backup-pgdump.log /var/log/backup-run.log /var/log/backup-verify.log

    log "rendering crontab from template"
    sed \
        -e "s|__TZ__|${TZ}|g" \
        -e "s|__BACKUP_PG_DUMP_HOUR__|${BACKUP_PG_DUMP_HOUR}|g" \
        -e "s|__BACKUP_SNAPSHOT_HOUR__|${BACKUP_SNAPSHOT_HOUR}|g" \
        -e "s|__BACKUP_VERIFY_DAY__|${BACKUP_VERIFY_DAY}|g" \
        /etc/crontabs/root.template > /etc/crontabs/root
    chmod 0600 /etc/crontabs/root

    log "rendered crontab:"
    sed 's/^/    /' /etc/crontabs/root

    # TCP-probe wait — kopia 0.22+ enforces session cookies on /api/v1/* so
    # basic-auth curl probes flood the kopia log with "missing or invalid
    # session cookie". Port-listening is sufficient liveness signal; the
    # subsequent `kopia repository connect server` performs cookie-aware login.
    log "waiting for kopia server at ${KOPIA_API_URL}"
    local host port
    host="$(printf '%s' "${KOPIA_API_URL#*://}" | cut -d: -f1 | cut -d/ -f1)"
    port="$(printf '%s' "${KOPIA_API_URL#*://}" | cut -d: -f2 | cut -d/ -f1)"
    local i
    for i in $(seq 1 60); do
        if bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
            log "kopia server reachable on ${host}:${port}"
            break
        fi
        if [[ "$i" -eq 60 ]]; then
            err "kopia server not reachable after 120s"
            exit 1
        fi
        sleep 2
    done

    # Orchestrator shares the kopia_config volume with the kopia server.
    # KOPIA_PASSWORD must be set so kopia CLI can unlock the repo metadata.
    export KOPIA_PASSWORD="$(cat /run/secrets/kopia_repo_password)"
    log "kopia repository status (smoke test against shared config)"
    if ! kopia repository status 2>&1 | sed 's/^/    /'; then
        err "kopia repository status FAILED — repository.config missing or password mismatch"
        exit 1
    fi
    log "kopia repository OK"

    log "applying per-source policies"
    /usr/local/bin/policies.sh

    log "starting cron daemon"
    exec "$@"
}

main "$@"
