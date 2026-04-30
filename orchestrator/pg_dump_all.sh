#!/usr/bin/env bash
# ==============================================================================
# BACKUP ORCHESTRATOR - POSTGRES DUMP ALL
# ==============================================================================
# Description: Logical pg_dump of every user database on each registered cluster
#              (hub, immich, piped, genetics). Output written to
#              ${BACKUP_STAGING_DIR}/postgres/<cluster>-<dbname>-<stamp>.sql.gz
#              for downstream Kopia snapshot. Also retains 14 days of dumps
#              locally so Kopia dedup benefits across runs.
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-04-29
# Version: 1.0.0
# Host: Your Server
# ==============================================================================
# Required env: BACKUP_STAGING_DIR
# Required secrets:
#   /run/secrets/postgres_hub_backup_password
#   /run/secrets/postgres_immich_backup_password
#   /run/secrets/postgres_piped_backup_password
#   /run/secrets/postgres_genetics_backup_password
# Network: orchestrator must be on db_backup so postgres host names resolve.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly LOG_PREFIX="[pg_dump]"
readonly STAMP="$(date -u +%Y%m%d_%H%M%SZ)"
readonly DUMP_USER="backup"
readonly RETENTION_DAYS=14

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

list_user_databases() {
    local host=$1
    local user=$2
    local pwd=$3

    PGPASSWORD="$pwd" psql \
        --host="$host" \
        --port=5432 \
        --username="$user" \
        --dbname=postgres \
        --tuples-only \
        --no-align \
        --command="SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');"
}

dump_cluster() {
    local cluster_name=$1
    local host=$2
    local secret_file=$3
    local staging
    staging="${BACKUP_STAGING_DIR}/postgres"

    if [[ ! -s "$secret_file" ]]; then
        err "$cluster_name: missing secret $secret_file — skipping"
        return 1
    fi

    local pwd
    pwd="$(cat "$secret_file")"

    log "$cluster_name: discovering databases on $host"
    local dbs
    if ! dbs="$(list_user_databases "$host" "$DUMP_USER" "$pwd")"; then
        err "$cluster_name: failed to list databases on $host"
        return 1
    fi

    if [[ -z "$dbs" ]]; then
        log "$cluster_name: no user databases found"
        return 0
    fi

    local db
    local out
    local size
    local rc=0
    while IFS= read -r db; do
        [[ -z "$db" ]] && continue
        out="${staging}/${cluster_name}-${db}-${STAMP}.sql.gz"
        log "$cluster_name: dumping $db -> $out"
        if PGPASSWORD="$pwd" pg_dump \
                --host="$host" \
                --port=5432 \
                --username="$DUMP_USER" \
                --dbname="$db" \
                --no-owner \
                --no-privileges \
                --clean \
                --if-exists \
                --format=plain \
                --serializable-deferrable \
            | gzip -9 > "$out"; then
            size="$(du -h "$out" | cut -f1)"
            log "$cluster_name: $db done ($size)"
        else
            err "$cluster_name: $db FAILED"
            rm -f "$out"
            rc=1
        fi
    done <<< "$dbs"

    return "$rc"
}

main() {
    require_env BACKUP_STAGING_DIR
    mkdir -p "${BACKUP_STAGING_DIR}/postgres"

    log "starting Postgres dump run, stamp=${STAMP}"

    local failures=0

    dump_cluster hub      postgres-hub        /run/secrets/postgres_hub_backup_password      || failures=$((failures + 1))
    dump_cluster immich   immich-postgres     /run/secrets/postgres_immich_backup_password   || failures=$((failures + 1))
    dump_cluster piped    piped-postgres      /run/secrets/postgres_piped_backup_password    || failures=$((failures + 1))
    dump_cluster genetics postgres18-genetics /run/secrets/postgres_genetics_backup_password || failures=$((failures + 1))

    log "applying local retention (delete dumps older than ${RETENTION_DAYS} days)"
    find "${BACKUP_STAGING_DIR}/postgres" -type f -name '*.sql.gz' -mtime +${RETENTION_DAYS} -print -delete || true

    if [[ "$failures" -gt 0 ]]; then
        err "completed with $failures cluster failure(s)"
        exit 1
    fi

    log "all clusters dumped"
}

main "$@"
