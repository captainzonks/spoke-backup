# Backup Sources

`spoke-backup` snapshots a fixed set of core sources on every run, plus any extras you declare. Sources are mounted read-only into both the `kopia` server and the `backup-orchestrator` container at `/sources/...`.

## Core Sources

These four are always snapshotted by `backup.sh`:

| Mount path | Host path | What it contains |
|------------|-----------|------------------|
| `/sources/secrets` | `${SECRETS_DIR}` | All Docker secrets |
| `/sources/shared-env` | `${SPOKE_DIR}/shared/env/` | `base.env`, `hub.env` — instance configuration |
| `/sources/appdata` | `${SPOKE_DIR}/appdata/` | Container persistent data (configs, databases, state) |
| `/staging` | `${BACKUP_STAGING_DIR}` | Postgres dumps + a copy of `modules.yml` written at run time |

`modules.yml` is a single file, not a directory. The orchestrator copies it into `/staging` at the start of each snapshot run so it is captured by the `/staging` snapshot.

## Adding Extra Sources

To back up paths beyond the core four:

1. Mount the host path into both `kopia` and `backup-orchestrator` as a read-only volume in `docker-compose.override.yml`. Convention: mount at `/sources/<name>`.
2. Add the mount path to `BACKUP_EXTRA_SOURCES` (space-separated) — set in your `modules.yml` `env_overrides` or `.env`.
3. Redeploy: `make rebuild MODULE=backup NO_CACHE=true`.

`backup.sh` snapshots the core sources first, then everything in `BACKUP_EXTRA_SOURCES`.

## Excluding Regenerable Subpaths

For each source, you can tell Kopia to skip subpaths that are large and regenerable (transcoded media, caches, generated thumbnails, etc.).

The orchestrator looks for a file at `/etc/backup/appdata-excludes.conf` on startup. If present, every non-blank, non-comment line is applied as a `--add-ignore` glob for `/sources/appdata`.

Format: one glob pattern per line; lines starting with `#` are ignored.

```
# Example /etc/backup/appdata-excludes.conf
/myapp/cache/
/myapp/logs/
/another/transcodes/
```

Bind-mount your file via `docker-compose.override.yml`:

```yaml
services:
  backup-orchestrator:
    volumes:
      - ./appdata-excludes.conf:/etc/backup/appdata-excludes.conf:ro
```

If the file is absent or empty, all of `/sources/appdata` is snapshotted as-is.

To inspect what's currently excluded:

```bash
docker exec backup-orchestrator kopia policy show /sources/appdata
```

## Removing a Source

Reverse the steps in [Adding Extra Sources](#adding-extra-sources). Existing snapshots for the removed path remain in the Kopia repository until retention expires.
