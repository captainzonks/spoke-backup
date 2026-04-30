# ==============================================================================
# BACKUP ORCHESTRATOR - DOCKERFILE
# ==============================================================================
# Description: Postgres 18 client + Kopia client + cron + jq + curl, alpine-based
# Author: Matt Barham
# Created: 2026-04-29
# Modified: 2026-04-29
# Version: 1.0.0
# Host: Your Server
# ==============================================================================
# Base: postgres:18-alpine (provides pg_dump 18 — compatible with PG 14-18 servers)
# Documentation:
#   - Kopia releases: https://github.com/kopia/kopia/releases
#   - PostgreSQL pg_dump compatibility: https://www.postgresql.org/docs/current/app-pgdump.html
# ==============================================================================

ARG KOPIA_VERSION=0.22.3
ARG POSTGRES_TAG=18-alpine

FROM postgres:${POSTGRES_TAG}

ARG KOPIA_VERSION

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        dcron \
        gettext \
        gzip \
        jq \
        tzdata \
 && curl -fsSL "https://github.com/kopia/kopia/releases/download/v${KOPIA_VERSION}/kopia-${KOPIA_VERSION}-linux-x64.tar.gz" \
      -o /tmp/kopia.tar.gz \
 && mkdir -p /tmp/kopia-extract \
 && tar -xzf /tmp/kopia.tar.gz -C /tmp/kopia-extract \
 && mv "/tmp/kopia-extract/kopia-${KOPIA_VERSION}-linux-x64/kopia" /usr/local/bin/kopia \
 && chmod 0755 /usr/local/bin/kopia \
 && rm -rf /tmp/kopia.tar.gz /tmp/kopia-extract \
 && /usr/local/bin/kopia --version

COPY entrypoint.sh    /usr/local/bin/entrypoint.sh
COPY backup.sh        /usr/local/bin/backup.sh
COPY pg_dump_all.sh   /usr/local/bin/pg_dump_all.sh
COPY notify.sh        /usr/local/bin/notify.sh
COPY policies.sh      /usr/local/bin/policies.sh
COPY crontab.template /etc/crontabs/root.template

RUN chmod 0755 /usr/local/bin/entrypoint.sh \
               /usr/local/bin/backup.sh \
               /usr/local/bin/pg_dump_all.sh \
               /usr/local/bin/notify.sh \
               /usr/local/bin/policies.sh \
 && chmod 0600 /etc/crontabs/root.template \
 && mkdir -p /var/log /staging \
 && chmod 0700 /etc/crontabs

WORKDIR /staging

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["crond", "-f", "-l", "8"]
