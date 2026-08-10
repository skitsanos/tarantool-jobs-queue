# Operations

This guide covers persistence, recovery, access control, and deployment boundaries.
The provided Compose configuration is appropriate for a single local queue instance;
adapt networking, secrets, monitoring, and backups for the deployment platform.

## Persistence

The queue stores memtx snapshots, write-ahead logs, and Vinyl files under
`TARANTOOL_DATA_DIR`. The directory is created during startup and must be writable by
the service account. The production image runs as the non-root `tarantool` user (UID
999), and Compose mounts the `jobs-data` volume at `/var/lib/tarantool`.

`TARANTOOL_WAL_MODE=fsync` is the default. A committing write waits for its WAL record
to reach the storage device before the API reports success. `write` offers lower
latency while accepting the risk of losing recent writes during host or storage
failure. WAL mode `none` is rejected.

Automatic snapshots run hourly by default and retain two checkpoints. Configure the
interval with `TARANTOOL_CHECKPOINT_INTERVAL` and retention with
`TARANTOOL_CHECKPOINT_COUNT`.

## Backups and restore

A named volume preserves data across container replacement, but it is not an off-host
backup and does not provide replication or high availability.

Snapshot and WAL files must be backed up as one consistent set. For a cold backup:

1. Stop the service without deleting the volume.
2. Snapshot or copy the volume using the storage platform.
3. Store the copy on independently managed storage.
4. Restart the service and verify `/health/ready`.

Restore only while the service is stopped and use a compatible Tarantool version.
Tarantool's `box.backup.start()` and `box.backup.stop()` APIs can coordinate a hot
backup when a secured administrative connection is available.

When changing startup, storage, the container image, or Compose, run:

```powershell
pwsh -NoProfile -File tests/persistence-recreate.ps1
```

This test writes to an isolated volume, creates a fresh container attached to the same
volume, and verifies recovery. It never uses the production `jobs-data` volume.

## Authentication

Set `API_BEARER_TOKEN` to a random secret containing 32 to 512 non-whitespace
characters. Invalid configuration stops the process before the database or HTTP
listeners open.

When enabled, all `/jobs` routes, `/version`, and `/health/ready` require:

```http
Authorization: Bearer <token>
```

`/health/live` remains public so an orchestrator can determine whether the HTTP process
is alive. Missing or incorrect credentials return `401` with a `WWW-Authenticate`
challenge.

Bearer tokens are reusable secrets:

- Terminate TLS before exposing the HTTP service beyond a trusted local network.
- Keep tokens in a secret manager, not source control, URLs, or command arguments.
- Do not log authorization headers.
- Restart the service after rotating the token.
- Do not trust proxy identity headers as a substitute for bearer authentication.

## Network exposure

HTTP and the native Tarantool protocol bind to loopback by default. Compose publishes
HTTP to host loopback and does not publish the native port.

Set `HTTP_HOST`, `HTTP_PUBLISH_ADDRESS`, or `TARANTOOL_LISTEN` only when remote access
is intentional. Keep the native protocol on a private network, create Tarantool users
with minimum privileges, and never expose port 3301 directly to the internet.

## Health checks

`GET /health/live` confirms only that the HTTP process responds. It is public even when
authentication is enabled.

`GET /health/ready` verifies:

- The schema migration version is current.
- Required job fields and indexes exist.
- Tarantool is not read-only.
- A transactional write succeeds and can be rolled back.

Readiness requires bearer authentication when configured. Remove an instance from
traffic while readiness returns `503`, but use liveness failures—not readiness alone—to
decide whether a process should be restarted.

## Capacity and availability boundaries

This project currently operates as a single Tarantool instance. Plan for:

- Monitoring disk capacity for snapshots and WAL files.
- Off-host backups and restore drills.
- Client timeouts and bounded retry backoff.
- A maintenance window for upgrades and schema migrations.
- Application-level handling when the queue is unavailable.

Replication, automated failover, queue metrics, and structured logging are not yet
provided by this project.
