# Tarantool Jobs Queue with REST API

A persistent jobs queue implemented as a Tarantool Lua application and exposed over HTTP.

## Requirements

Runtime:

- Tarantool
- A C compiler toolchain and `unzip` for building native rocks
- The Tarantool `http` rock, version `1.9.0-1`

Development and CI:

- Docker
- PowerShell 7
- Task (optional, for the short commands below)

The application includes a rockspec declaring its Lua dependencies.

## Running

Install the HTTP dependency and start the application:

```shell
task install
task run
```

Without Task, run `tt rocks make tarantool-jobs-queue-scm-1.rockspec` and then
`tarantool src/server.lua`.

Configuration is available through environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HTTP_HOST` | `127.0.0.1` | REST API bind address |
| `HTTP_PORT` | `3000` | REST API port |
| `TARANTOOL_LISTEN` | `127.0.0.1:3301` | Tarantool native protocol listener |
| `API_BEARER_TOKEN` | unset | Enables HTTP bearer authentication when set |
| `TARANTOOL_DATA_DIR` | `./data` | Snapshot, WAL, and Vinyl data directory |
| `TARANTOOL_WAL_MODE` | `fsync` | WAL durability mode: `fsync` or `write` |
| `TARANTOOL_CHECKPOINT_INTERVAL` | `3600` | Seconds between automatic snapshots |
| `TARANTOOL_CHECKPOINT_COUNT` | `2` | Number of snapshots to retain |

To run the production image with persistent storage, set a secret and start Compose:

```powershell
$env:API_BEARER_TOKEN = '<random-secret-of-at-least-32-characters>'
docker compose up --build --detach
docker compose ps
```

Compose stores database files in the `jobs-data` named volume. `docker compose down`
preserves this volume; `docker compose down --volumes` permanently deletes the queue.

## Security and access control

Set `API_BEARER_TOKEN` to a randomly generated secret of 32 to 512 characters to
protect the API. Whitespace and control characters are rejected, and invalid token
configuration stops the process before Tarantool opens its listener.

```powershell
$env:API_BEARER_TOKEN = '<random-secret-of-at-least-32-characters>'
task run
```

When authentication is enabled, send the token in the `Authorization` header:

```http
Authorization: Bearer <token>
```

All `/jobs` routes, `/version`, and `/health/ready` require the token. `/health/live`
remains public so a local orchestrator can determine whether the HTTP process is alive.
Missing and incorrect credentials return `401` with a `WWW-Authenticate` challenge.

Both HTTP and the native Tarantool protocol bind to loopback by default. The provided
Compose configuration listens on the container network only for authenticated HTTP,
publishes HTTP to host loopback, and does not publish the native protocol. Set
`HTTP_HOST`, `HTTP_PUBLISH_ADDRESS`, or `TARANTOOL_LISTEN` explicitly only when remote
access is required. Restrict native access with private networking and Tarantool users
with the minimum necessary privileges. Never expose port 3301 directly to the internet.

Bearer credentials are reusable secrets. Terminate TLS before exposing the HTTP API,
keep the token in a secret manager rather than source control or command-line arguments,
and restart the service after rotating it. The application intentionally does not trust
proxy identity headers.

## Persistence and recovery

The queue stores memtx snapshots, write-ahead logs, and Vinyl files under
`TARANTOOL_DATA_DIR`. The directory is created during startup and must be writable by the
service account. The production image runs as the non-root `tarantool` user (UID 999),
and its Compose volume is mounted at `/var/lib/tarantool`.

`TARANTOOL_WAL_MODE=fsync` is the default: a committing write waits for its WAL record to
reach the storage device before the API reports success. `write` is available when lower
latency is worth accepting the risk of losing the latest writes during host or storage
failure. WAL mode `none` is rejected because this application is a durable queue.

Automatic snapshots run hourly by default and retain two checkpoints. Snapshot and WAL
files must be backed up as one consistent set. For a simple cold backup, stop the service,
snapshot or copy the volume with your storage platform, and then restart it. Restore only
while the service is stopped and use a compatible Tarantool version. Tarantool's
`box.backup.start()` and `box.backup.stop()` APIs can coordinate a hot backup when a
secured administrative connection is available.

A named volume protects data across container replacement, but it is not an off-host
backup and does not provide replication or high availability. Monitor free space and
copy backups to independently managed storage.

## Job lifecycle

```text
                                      ack
                            +--------------------> done
                            |
pending --claim + lease--> in-progress
   ^                        |
   |                        +-- retryable fail/release/expired lease
   |                                        |
   +----------------------------------------+

in-progress -- permanent failure or exhausted attempts --> failed
failed      -- manual retry, resetting attempts ----------> pending
```

Important behavior:

- Claiming atomically selects and transitions one available job.
- Every claim increments `attempts` and creates a processing lease with a unique fencing token.
- A retry is accepted only while `attempts < max_attempts`.
- Retry delays are enforced through `available_at`.
- Expired leases are recovered when the next claim is made. They become pending again or failed when the attempt limit has been reached.
- Manual retry resets a failed job's attempt counter to zero.

## Creating jobs and idempotency

`POST /jobs` accepts the job payload as a JSON object. Options are query parameters:

- `max_attempts`: integer from `1` to `100`; default `3`.
- `delay`: seconds before the first claim, from `0` to `86400`; default `0`.

An optional `Idempotency-Key` header, containing 1–200 characters, makes creation idempotent. The first request returns `201` and `Idempotency-Replayed: false`; subsequent requests with the same key return the original job with `200` and `Idempotency-Replayed: true`. A replay returns the original payload and options even if the later request differs.

## Claiming and processing

`POST /jobs/claim?lease=60` claims the next available job. `lease` may be between `0.1` and `3600` seconds. The endpoint returns `204` when no job is currently available.

The response contains `lease_token`. The worker must send it in the `Lease-Token` header when acknowledging, failing, or releasing the job. Expired tokens and tokens from older attempts receive `409`, preventing a stale worker from completing a newer attempt.

Successful work is acknowledged with:

```text
POST /jobs/:id/ack
Lease-Token: <token returned by claim>
```

A worker can report failure with:

```http
POST /jobs/:id/fail
Content-Type: application/json
Lease-Token: <token returned by claim>

{
  "error": "upstream service unavailable",
  "retry": true,
  "retry_delay": 30
}
```

`retry` defaults to `true`, and `retry_delay` defaults to zero. `POST /jobs/:id/release` is equivalent to a retryable failure with no delay. `POST /jobs/:id/retry` manually resets a terminally failed job.

## Cursor pagination

`GET /jobs` supports:

- `status`: `pending`, `in-progress`, `done`, or `failed`.
- `limit`: integer from `1` to `100`; default `50`.
- `cursor`: the opaque `next_cursor` returned by the previous page.

Example response:

```json
{
  "total": 3,
  "limit": 2,
  "next_cursor": "eyJzdGF0dXMiOiJwZW5kaW5nIiwiam9iX2lkIjoiLi4uIn0",
  "data": []
}
```

Cursors are bound to the selected status. If the cursor job is deleted or moves out of that status, the API returns `400 invalid_cursor`. Offset pagination is no longer supported.

## REST API

| Method and path | Description | Successful response |
| --- | --- | --- |
| `POST /jobs` | Create or idempotently replay a job | `201` or `200` and the job |
| `GET /jobs` | Cursor-paginate jobs | `200` and a page |
| `POST /jobs/claim` | Atomically claim an available job with a lease | `200` and the job, or `204` |
| `GET /jobs/:id` | Retrieve one job | `200`, or `404` |
| `POST /jobs/:id/ack` | Complete an in-progress job | `200`, `404`, or `409` |
| `POST /jobs/:id/fail` | Fail, delay, or retry an in-progress job | `200`, `400`, `404`, or `409` |
| `POST /jobs/:id/release` | Immediately retry or terminally fail an in-progress job | `200`, `404`, or `409` |
| `POST /jobs/:id/retry` | Reset a failed job to pending | `200`, `404`, or `409` |
| `DELETE /jobs/:id` | Delete a job idempotently | `204` |
| `GET /version` | Return API and schema versions | `200` |
| `GET /health/live` | Confirm that the HTTP process is serving requests | `200` |
| `GET /health/ready` | Verify schema state and rolled-back write availability | `200` or `503` |

`GET /health/live` is intentionally independent of database state. `GET /health/ready`
returns `200` only when the jobs space is at the expected migration version, its fields
and indexes are present, the Tarantool instance is not read-only, and a transactional
insert succeeds. The probe transaction is rolled back and does not create a queue job.
When bearer authentication is enabled, readiness probes must include the authorization
header; liveness probes do not need one.

Example job:

```json
{
  "job_id": "ca43f0ea-9ca9-42e8-9df4-335d50770e19",
  "status": "in-progress",
  "payload": {
    "kind": "extract-tables",
    "file": "demo.pdf"
  },
  "created_at": 1785945600.25,
  "updated_at": 1785945601.25,
  "available_at": 1785945600.25,
  "lease_until": 1785945661.25,
  "lease_token": "389526c8-edf0-4fe6-abdb-03b8236954e5",
  "attempts": 1,
  "max_attempts": 3,
  "last_error": null,
  "idempotency_key": "extract-demo-pdf"
}
```

Errors use a consistent JSON envelope:

```json
{
  "error": {
    "code": "job_not_found",
    "message": "Job was not found"
  }
}
```

## Schema migrations

The current jobs schema version is `3`. The version is stored in Tarantool's `_schema` space under a key scoped to the jobs space. An existing legacy five-field jobs space is detected as version 1 and upgraded in place. Version 2 adds retry, lease, and idempotency fields; version 3 adds fenced lease tokens. Each migration can be safely reapplied after interruption, and the version marker is written only after the migration completes.

## Tests

The complete test harness uses pinned Tarantool and Hurl images. It creates an ephemeral
database and API container, waits for schema readiness, runs every check sequentially,
prints server logs on failure, and removes the container afterward:

```powershell
task test
```

Focused commands are available for faster iteration:

```powershell
task lint
task test:unit
task test:http
```

Without Task, invoke `pwsh -NoProfile -File tests/run.ps1 -Suite All` (or use
`Lint`, `Unit`, or `Http`). The unit suite exercises storage, lifecycle transitions,
leases, fencing, retries, pagination, and versioned migration directly in Tarantool.
The HTTP suite runs Hurl contracts plus concurrency, idempotency, cursor, retry, and
restart-recovery scenarios. The Linux restart check verifies the restarted service over
container-local networking with bounded startup retries. GitHub Actions runs the same
`All` suite on every pull request and every push to `main`. Docker Desktop on Windows
skips the container-restart scenario because its native restart command can block the calling PowerShell process;
Linux CI always runs that scenario. The suite also starts an authenticated instance to
verify public liveness, protected routes, rejected writes, and fail-fast token validation.
Finally, it builds the production image, writes a job to an isolated named volume,
destroys the first container, and verifies recovery from a fresh container.

## Delivery semantics

This is a single-instance, lease-based at-least-once queue. A worker may process a job more than once when its lease expires before acknowledgement. Per-attempt fencing tokens prevent stale workers from modifying a reclaimed job. Attempts stop automatically at `max_attempts`, after which the job remains visible in the `failed` state for inspection or manual retry. Lease recovery is lazy and occurs during claim requests or when an expired worker attempts a transition, rather than in a background scheduler.
