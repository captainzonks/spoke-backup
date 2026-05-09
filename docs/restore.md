# Disaster Recovery Runbook

This runbook covers two scenarios:

1. **Restore from existing repository** — Spoke instance is gone but the B2 repository is intact.
2. **Reconnect a fresh deploy** — Backup module is being redeployed against an existing repo.

You will need:

- The `kopia_repo_password` (the encryption password). **Without this, the repository is unrecoverable.**
- The `b2_account_id` and `b2_account_key` for the B2 application key.
- Your `KOPIA_REPO_BUCKET`, `KOPIA_REPO_PREFIX`, `KOPIA_REPO_ENDPOINT`, `KOPIA_REPO_REGION` values.

## 1. Reconnect to an Existing B2 Repository

If the Spoke host is rebuilt but the B2 repository still exists, you need to *connect* to the existing repository instead of *creating* a new one.

The `kopia-init` service in `docker-compose.yml` handles first-time creation only — it skips itself when `repository.config` already exists in the `kopia_config` volume. After a rebuild, `kopia_config` is empty, so you need to seed it manually:

```bash
# Stage all four core secrets first under ${SECRETS_DIR}/backup/
ls ${SECRETS_DIR}/backup/
#   b2_account_id
#   b2_account_key
#   kopia_repo_password
#   kopia_server_password

# Bring up just the kopia volume
docker compose -f modules/backup/docker-compose.yml up -d --no-start kopia

# Connect to the existing repository
docker run --rm \
  -v spoke-backup_kopia_config:/app/config \
  -e KOPIA_PASSWORD="$(cat ${SECRETS_DIR}/backup/kopia_repo_password)" \
  -e KOPIA_CONFIG_PATH=/app/config/repository.config \
  kopia/kopia:0.22.3 \
  repository connect b2 \
    --bucket="${KOPIA_REPO_BUCKET}" \
    --prefix="${KOPIA_REPO_PREFIX}" \
    --key-id="$(cat ${SECRETS_DIR}/backup/b2_account_id)" \
    --key="$(cat ${SECRETS_DIR}/backup/b2_account_key)"
```

Then `make deploy MODULE=backup` — `kopia-init` will detect the populated config and skip, and the `kopia` server will start against the existing repo.

## 2. Restore Files

### List snapshots

```bash
docker exec backup-orchestrator sh -c 'KOPIA_PASSWORD=$(cat /run/secrets/kopia_repo_password) kopia snapshot list --all'
```

This prints every snapshot, grouped by source path, with snapshot IDs and tags (`latest-1`, `daily-3`, `monthly-1`, etc.).

### Restore a snapshot to disk

```bash
# Pick a snapshot ID from the list above
SNAP_ID=<id>
docker exec backup-orchestrator sh -c "
  KOPIA_PASSWORD=\$(cat /run/secrets/kopia_repo_password) \
  kopia snapshot restore $SNAP_ID /tmp/restore
"

# Copy out of the container
docker cp backup-orchestrator:/tmp/restore ./restore-${SNAP_ID}
```

For large restores, mount a host volume into the container instead of using `/tmp` (which is a small tmpfs).

### Restore a single file

```bash
docker exec backup-orchestrator sh -c "
  KOPIA_PASSWORD=\$(cat /run/secrets/kopia_repo_password) \
  kopia show <snapshot-id>/path/to/file > /tmp/file.out
"
```

## 3. Restore Postgres

Postgres dumps live in the `/staging` snapshot at `postgres/<cluster>-<dbname>-<stamp>.sql.gz` where `<stamp>` is `YYYYMMDD_HHMMSSZ`.

```bash
# Restore the latest /staging snapshot (filtered to postgres dumps)
docker exec backup-orchestrator sh -c '
  KOPIA_PASSWORD=$(cat /run/secrets/kopia_repo_password)
  kopia snapshot restore --filter "postgres/*" \
    $(kopia snapshot list /staging --json | jq -r ".[0].id") \
    /tmp/pg-restore
'

# Pick the dump you want
docker cp backup-orchestrator:/tmp/pg-restore/postgres/<cluster>-<dbname>-<stamp>.sql.gz ./

# Apply it (against a fresh database)
gunzip -c <cluster>-<dbname>-<stamp>.sql.gz | \
  docker exec -i <postgres-container> psql -U postgres -d <dbname>
```

The dumps are written with `--clean --if-exists`, so they drop and recreate objects safely.

## 4. Verify Repository Integrity

The orchestrator runs `kopia snapshot verify --verify-files-percent=10` weekly via cron and emails the result. To run a verification on demand:

```bash
docker exec backup-orchestrator /usr/local/bin/backup.sh --verify
```

For a paranoid full-content verify:

```bash
docker exec backup-orchestrator sh -c '
  KOPIA_PASSWORD=$(cat /run/secrets/kopia_repo_password)
  kopia snapshot verify --verify-files-percent=100
'
```

## 5. Critical Reminders

- **Back up `kopia_repo_password` offline.** Print it on paper, store it in a password manager. Without it, the encrypted repository is unrecoverable.
- **Test a restore at least once.** A backup you've never restored is a hope, not a backup.
- **B2 application key permissions** must allow read+write on the bucket. A read-only key cannot run maintenance.
- **Maintenance** (compaction, GC of orphaned blobs) runs after each snapshot via `kopia maintenance run --safety=full`. If the orchestrator has been down for an extended period, expect the first run after recovery to take longer.
