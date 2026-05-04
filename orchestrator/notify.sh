#!/usr/bin/env bash
# ==============================================================================
# BACKUP ORCHESTRATOR - EMAIL NOTIFICATION
# ==============================================================================
# Description: Posts a JSON message to the spoke-mail-relay module so a backup
#              run summary lands in BACKUP_NOTIFY_TO. Honors BACKUP_NOTIFY_ON
#              gating (always | failure | never).
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-04-29
# Version: 1.0.0
# Host: Your Server
# ==============================================================================
# Args:
#   $1  status string (e.g. "success", "failure (2 sources)", "verify success")
#   $2  path to log file whose contents become the email body
# Required env:
#   BACKUP_NOTIFY_TO    recipient email address
#   BACKUP_NOTIFY_FROM  sender identity (must match mail-relay allowlist)
#   BACKUP_NOTIFY_ON    "always" | "failure" | "never"
#   MAIL_RELAY_URL      e.g. http://mail-relay:8000/send
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly LOG_PREFIX="[notify]"
readonly STATUS="${1:-unknown}"
readonly LOG_FILE="${2:-}"

readonly BODY_MAX_BYTES=64000
readonly BODY_MAX_LINES=200
readonly HOSTNAME_VAL="$(hostname -s 2>/dev/null || echo rome)"

# Strip kopia per-blob progress/spinner/B2 debug noise. Keep:
#   - orchestrator log lines (ISO timestamp + [component] prefix)
#   - "Created snapshot" markers from kopia
#   - any line containing ERROR
filter_log() {
    tr '\r' '\n' | awk '
        /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \[/ { print; next }
        /Created snapshot/                         { print; next }
        /ERROR/                                    { print; next }
    '
}

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

should_send() {
    case "${BACKUP_NOTIFY_ON:-always}" in
        always)
            return 0
            ;;
        failure)
            if [[ "$STATUS" == *failure* || "$STATUS" == *FAILED* || "$STATUS" == *error* ]]; then
                return 0
            fi
            return 1
            ;;
        never)
            return 1
            ;;
        *)
            err "unknown BACKUP_NOTIFY_ON=${BACKUP_NOTIFY_ON} (defaulting to send)"
            return 0
            ;;
    esac
}

main() {
    require_env BACKUP_NOTIFY_TO BACKUP_NOTIFY_FROM MAIL_RELAY_URL

    if ! should_send; then
        log "skipping notification (BACKUP_NOTIFY_ON=${BACKUP_NOTIFY_ON:-always}, status=${STATUS})"
        exit 0
    fi

    local body
    if [[ -n "$LOG_FILE" && -s "$LOG_FILE" ]]; then
        # Filter kopia noise, then cap line count and byte budget.
        body="$(filter_log < "$LOG_FILE" | tail -n "$BODY_MAX_LINES" | tail -c "$BODY_MAX_BYTES")"
        if [[ -z "$body" ]]; then
            body="(log produced no notable lines after filtering)"
        fi
    else
        body="(no log content available)"
    fi

    local subject
    subject="[rome-backup] ${STATUS} $(date -u +%Y-%m-%dT%H:%M:%SZ) on ${HOSTNAME_VAL}"

    log "sending notification to ${BACKUP_NOTIFY_TO} (subject=${subject})"

    local payload
    payload="$(jq -n \
        --arg to        "$BACKUP_NOTIFY_TO" \
        --arg from      "$BACKUP_NOTIFY_FROM" \
        --arg subject   "$subject" \
        --arg body_text "$body" \
        '{to: $to, from: $from, subject: $subject, body_text: $body_text}')"

    if curl -sf -X POST "$MAIL_RELAY_URL" \
        -H 'Content-Type: application/json' \
        --max-time 30 \
        --data "$payload" > /dev/null; then
        log "notification sent"
        exit 0
    fi

    err "failed to POST to mail-relay at $MAIL_RELAY_URL"
    exit 1
}

main "$@"
