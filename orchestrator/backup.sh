#!/usr/bin/env bash
# ==============================================================================
# BACKUP ORCHESTRATOR - MAIN BACKUP RUN
# ==============================================================================
# Description: Top-level entry that runs Postgres dumps, drives Kopia snapshot
#              creation across all defined sources, runs maintenance, and emits
#              an email notification via the spoke-mail-relay module.
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-04-29
# Version: 1.0.0
# Host: Your Server
# ==============================================================================
# Modes:
#   --snapshot  (default) Run pg_dump_all.sh, snapshot all sources, retain, notify.
#   --once               Alias for --snapshot.
#   --verify             Run kopia snapshot verify and notify.
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# Cron-spawned shells inherit no env; export the repo password from secret
# every invocation so kopia subcommands can unlock the encrypted metadata.
if [[ -s /run/secrets/kopia_repo_password ]]; then
    export KOPIA_PASSWORD="$(cat /run/secrets/kopia_repo_password)"
fi

readonly LOG_PREFIX="[backup]"
# Use $$ + epoch for uniqueness; busybox mktemp rejects suffixed templates.
readonly RUN_LOG="/tmp/backup-run.$$.$(date -u +%s).log"
: > "$RUN_LOG"
trap 'rm -f "$RUN_LOG"' EXIT

readonly SOURCES=(
    /sources/secrets
    /sources/shared-env
    /sources/appdata
    /sources/immich
    /sources/staging
)
# modules.yml is a single file — kopia snapshots only directories, so we
# copy it into the staging dir at run time and let /sources/staging carry it.

log() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $LOG_PREFIX $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$RUN_LOG"
}

err() {
    local line
    line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $LOG_PREFIX ERROR: $*"
    printf '%s\n' "$line" >&2
    printf '%s\n' "$line" >> "$RUN_LOG"
}

run_snapshot() {
    log "starting snapshot run"

    if [[ -f /sources/modules.yml ]]; then
        log "staging modules.yml for inclusion in /sources/staging snapshot"
        cp /sources/modules.yml /staging/modules.yml || \
            err "failed to copy modules.yml to staging (non-fatal)"
    fi

    log "stage 1/3: postgres dumps"
    if /usr/local/bin/pg_dump_all.sh 2>&1 | tee -a "$RUN_LOG"; then
        log "stage 1/3: pg_dump complete"
    else
        err "stage 1/3: pg_dump had failures (continuing with snapshot anyway)"
    fi

    log "stage 2/3: kopia snapshots (${#SOURCES[@]} sources)"
    local failures=0
    local src
    for src in "${SOURCES[@]}"; do
        log "snapshot: $src"
        if kopia snapshot create "$src" 2>&1 | tee -a "$RUN_LOG"; then
            log "snapshot: $src OK"
        else
            err "snapshot: $src FAILED"
            failures=$((failures + 1))
        fi
    done

    log "stage 3/3: kopia maintenance"
    if kopia maintenance run --safety=full 2>&1 | tee -a "$RUN_LOG"; then
        log "maintenance complete"
    else
        err "maintenance failed (non-fatal)"
    fi

    if [[ "$failures" -eq 0 ]]; then
        /usr/local/bin/notify.sh "success" "$RUN_LOG"
        log "snapshot run complete: success"
        return 0
    fi
    /usr/local/bin/notify.sh "failure (${failures} sources)" "$RUN_LOG"
    err "snapshot run complete with ${failures} failure(s)"
    return 1
}

run_verify() {
    log "starting verify run"
    if kopia snapshot verify --verify-files-percent=10 2>&1 | tee -a "$RUN_LOG"; then
        log "verify complete: OK"
        /usr/local/bin/notify.sh "verify success" "$RUN_LOG"
        return 0
    fi
    err "verify FAILED"
    /usr/local/bin/notify.sh "verify failure" "$RUN_LOG"
    return 1
}

main() {
    local mode="${1:---snapshot}"
    case "$mode" in
        --once|--snapshot)
            run_snapshot
            ;;
        --verify)
            run_verify
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--snapshot|--once|--verify]
  --snapshot   (default) pg_dump + kopia snapshot all sources + maintenance
  --once       Alias for --snapshot
  --verify     Verify the kopia repository (sample 10 percent of files)
EOF
            ;;
        *)
            err "unknown mode: $mode"
            exit 2
            ;;
    esac
}

main "$@"
