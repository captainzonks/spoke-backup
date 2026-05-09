# spoke-backup

Encrypted, deduplicated backup module for the [Spoke](https://github.com/captainzonks/spoke) hub-and-spoke platform.

Drives [Kopia](https://kopia.io/) in server mode plus a cron-based orchestrator that performs Postgres `pg_dump` runs across any clusters you configure, runs Kopia snapshots, enforces retention, verifies the repository on a weekly schedule, and reports results via the [`spoke-mail-relay`](https://github.com/captainzonks/spoke-mail-relay) module.

The module is **standalone** — it makes no assumptions about which other Spoke modules you have deployed. Postgres clusters and extra source paths are declared via environment variables; appdata exclude patterns come from a config file you provide.

## Features

- Server-mode Kopia with web UI behind Traefik + Authentik forward-auth.
- Backblaze B2 (S3-compatible) cloud storage backend.
- Daily logical Postgres dumps (`pg_dump`) for any number of clusters you declare.
- Configurable backup sources and per-source exclude patterns.
- GFS retention (daily / weekly / monthly / yearly).
- Email notifications via the `spoke-mail-relay` module.
- All secrets via Docker secrets at `/run/secrets/`.

## Architecture

```
                 +--------------------+
                 |   B2 Cloud (S3)    |
                 +---------^----------+
                           |
                           | encrypted blocks
                           |
+----------------+   +-----+------+        +------------------+
|   browser      |-->|   kopia    |<------>|     kopia        |
|  (admin UI)    |   |  (server)  |  TCP   |   web UI / API   |
+--------^-------+   +-----^------+        +------------------+
         |                 |
   Traefik+Authentik       | API (user/pass)
                           |
                  +--------+--------+
                  | backup-orches-  |
                  | trator (cron)   |
                  +--+-----------+--+
                     |           |
              pg_dump|           | HTTP POST
                     v           v
        +----------------+   +--------------+
        |  postgres-*    |   |  mail-relay  |
        |  (N clusters)  |   +------+-------+
        +----------------+          |
                                    v
                         +----------+----------+
                         |  protonmail-bridge  |
                         +---------------------+
```

## Networks

| Network | Purpose | Subnet |
|---------|---------|--------|
| `troxy` | Main Traefik / mail-relay reach | `192.168.35.0/24` |
| `db_backup` | DB backplane — orchestrator <-> postgres instances | `192.168.34.0/24` (internal-only) |

`db_backup` must exist before deploy. Create on the host one time:

```bash
docker network create db_backup \
  --driver bridge \
  --subnet 192.168.34.0/24 \
  --internal
```

Each Postgres cluster you want to dump must connect its container to `db_backup`. The convention in Spoke is to do this via a gitignored `docker-compose.override.yml` in the source module so the production compose file stays generic.

## Secrets

All under `${SECRETS_DIR}/backup/`:

| File | Purpose |
|------|---------|
| `kopia_repo_password` | Kopia repository encryption password. **Critical: losing this = backups unrecoverable.** Generate with `openssl rand -base64 48` and store offline (password manager + printed copy). |
| `kopia_server_password` | Authenticates orchestrator to the Kopia server API. |
| `b2_account_id` | Backblaze B2 application key ID. |
| `b2_account_key` | Backblaze B2 application key. |
| `postgres_hub_backup_password` | Read-only role on `postgres-hub` (the hub Postgres). |

### Adding more Postgres clusters

Each cluster listed in `BACKUP_PG_CLUSTERS` needs:

1. A secret file at `${SECRETS_DIR}/backup/postgres_<name>_backup_password`.
2. A top-level secret declaration plus a service-level secret reference for `backup-orchestrator`, both added via `docker-compose.override.yml`. Naming convention: `postgres_<name>_backup_password`.
3. The cluster's Postgres container connected to the `db_backup` network.

Provision a least-privilege role on each cluster:

```sql
CREATE ROLE backup WITH LOGIN PASSWORD '<random>';
GRANT pg_read_all_data TO backup;
```

## Environment Variables

See [`.env.example`](.env.example).

## First-time Setup

1. Create the `db_backup` network (one-time, see above).
2. Stage all secrets under `${SECRETS_DIR}/backup/` — the four core secrets plus one `postgres_<name>_backup_password` per cluster you list in `BACKUP_PG_CLUSTERS`.
3. Provision a `backup` role on each target Postgres cluster (see [Secrets](#secrets)).
4. Add a module entry in `modules.yml` (see your Spoke instance docs) with any `env_overrides` for `BACKUP_PG_CLUSTERS`, `BACKUP_EXTRA_SOURCES`, etc.
5. (Optional) Drop a `docker-compose.override.yml` next to the module compose file to mount extra source paths, declare extra Postgres secrets, or bind-mount your `appdata-excludes.conf`.
6. `make deploy MODULE=backup` — first deploy connects to B2 and creates the encrypted repository.
7. Verify the Kopia UI loads at `https://kopia.<your-domain>` and that the orchestrator container reports `service_healthy`.
8. Trigger a manual snapshot run:
   ```bash
   docker exec backup-orchestrator /usr/local/bin/backup.sh --once
   ```
9. Confirm a notification arrives at `BACKUP_NOTIFY_TO`.

## Backup Sources

Four core sources are always snapshotted, mounted read-only into both `kopia` and `backup-orchestrator`:

| Mount path | Host path | Contents |
|------------|-----------|----------|
| `/sources/secrets` | `${SECRETS_DIR}` | Docker secrets |
| `/sources/shared-env` | `${SPOKE_DIR}/shared/env/` | `base.env`, `hub.env` |
| `/sources/appdata` | `${SPOKE_DIR}/appdata/` | Container persistent data |
| `/staging` | `${BACKUP_STAGING_DIR}` | Postgres dumps + `modules.yml` |

Add additional paths by mounting them in `docker-compose.override.yml` and listing them in `BACKUP_EXTRA_SOURCES`.

To exclude regenerable subpaths from `/sources/appdata`, drop a config file at `/etc/backup/appdata-excludes.conf` (one glob pattern per line, `#` comments). Bind-mount it via `docker-compose.override.yml`. See [`docs/sources.md`](docs/sources.md) for the full breakdown.

## Restore

See [`docs/restore.md`](docs/restore.md) for the disaster-recovery runbook.

## License

MIT
