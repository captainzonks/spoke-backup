# spoke-backup

Encrypted, deduplicated backup module for the [Spoke](https://github.com/captainzonks/spoke) hub-and-spoke platform.

Drives [Kopia](https://kopia.io/) in server mode plus a cron-based orchestrator that performs Postgres `pg_dump` runs across hub and module databases, triggers Kopia snapshots via API, enforces retention, verifies the repository on a weekly schedule, and reports results via the [`spoke-mail-relay`](https://github.com/captainzonks/spoke-mail-relay) module.

## Features

- Server-mode Kopia with web UI behind Traefik + Authentik forward-auth.
- Backblaze B2 (S3-compatible) cloud storage backend.
- Daily logical Postgres dumps (`pg_dump`) for one or more databases.
- Selective backup sources — exclude regenerable cache/transcode dirs, include DB and config dirs.
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
        |  (4 instances) |   +------+-------+
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

Each Postgres-hosting module (hub, immich, piped, genetics) connects its `postgres-*` container to this network via a gitignored `docker-compose.override.yml`. See the deployment notes in your private Spoke instance.

## Secrets

All under `${SECRETS_DIR}/backup/`:

| File | Purpose |
|------|---------|
| `kopia_repo_password` | Kopia repository encryption password. **Critical: losing this = backups unrecoverable.** Generate with `openssl rand -base64 48` and store offline (password manager + printed copy). |
| `kopia_server_password` | Authenticates orchestrator to the Kopia server API. |
| `b2_account_id` | Backblaze B2 application key ID. |
| `b2_account_key` | Backblaze B2 application key. |
| `postgres_hub_backup_password` | Read-only role on `postgres-hub`. |
| `postgres_immich_backup_password` | Read-only role on `immich-postgres`. |
| `postgres_piped_backup_password` | Read-only role on `piped-postgres`. |
| `postgres_genetics_backup_password` | Read-only role on `postgres18-genetics`. |

Provision a least-privilege role per Postgres instance:

```sql
CREATE ROLE backup WITH LOGIN PASSWORD '<random>';
GRANT pg_read_all_data TO backup;
```

## Environment Variables

See [`.env.example`](.env.example).

## First-time Setup

1. Create the `db_backup` network (one-time, see above).
2. Stage all secrets under `${SECRETS_DIR}/backup/`.
3. Stage Postgres `backup` roles on every target instance.
4. Add module entry in `modules.yml` (see your Spoke instance docs).
5. `make deploy MODULE=backup` — first deploy connects to B2 and creates the encrypted repository.
6. Verify the Kopia UI loads at `https://kopia.<your-domain>` and that the orchestrator container reports `service_healthy`.
7. Trigger a manual snapshot run:
   ```bash
   docker exec backup-orchestrator /usr/local/bin/backup.sh --once
   ```
8. Confirm a notification arrives at `BACKUP_NOTIFY_TO`.

## Backup Sources

Sources are mounted read-only into the Kopia container at `/sources/...`. Selective coverage is enforced by a Kopia per-source policy file (managed by the orchestrator). See `docs/sources.md`.

Highlights:

- **Skipped** (regenerable): `appdata/plex/**/Media/`, `appdata/plex/**/Metadata/`, `appdata/dionysus/**/Media/`, `appdata/dionysus/**/Metadata/`, `appdata/stash/generated/`, `appdata/audiobookshelf/metadata/`, `appdata/influxdb3/`, transcoded Immich (`encoded-video/`, `thumbs/`).
- **Selective**: Plex/Dionysus `Plug-in Support/`, Stash `config/` + `blobs/`, Audiobookshelf `config/`.
- **Full**: every other small module appdata directory plus `secrets/`, `shared/env/`, `modules.yml`, and Postgres dumps.

## Restore

See [`docs/restore.md`](docs/restore.md) for the disaster-recovery runbook.

## License

MIT
