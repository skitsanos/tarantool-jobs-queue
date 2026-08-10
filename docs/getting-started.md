# Getting started

This guide covers local startup, configuration, authentication, and the first queue
request. For worker behavior, continue with the [worker guide](worker-guide.md).

## Run with Docker Compose

Requirements:

- Docker with Compose
- PowerShell 7 for the examples and project test harness

Choose a random bearer token containing 32 to 512 non-whitespace characters, then
start the service:

```powershell
$env:API_BEARER_TOKEN = '<random-secret-of-at-least-32-characters>'
docker compose up --build --detach
docker compose ps
```

Compose publishes HTTP to `127.0.0.1:3000`, keeps Tarantool's native protocol private,
and stores database files in the `jobs-data` named volume.

Wait for readiness before sending traffic:

```powershell
$headers = @{ Authorization = "Bearer $env:API_BEARER_TOKEN" }
Invoke-RestMethod http://127.0.0.1:3000/health/ready -Headers $headers
```

Liveness is public and only confirms that the HTTP process can respond:

```powershell
Invoke-RestMethod http://127.0.0.1:3000/health/live
```

Readiness additionally checks the expected schema, required fields and indexes,
read-write state, and a transactional write that is rolled back.

## Create a job

The request body is the payload the worker will receive:

```powershell
$job = Invoke-RestMethod `
  -Method Post `
  -Uri 'http://127.0.0.1:3000/jobs?max_attempts=3&delay=0' `
  -Headers ($headers + @{ 'Idempotency-Key' = 'welcome-email-123' }) `
  -ContentType 'application/json' `
  -Body '{"kind":"send-email","recipient":"person@example.com"}'

$job
```

Creation options are query parameters:

| Parameter | Default | Allowed values | Purpose |
| --- | --- | --- | --- |
| `max_attempts` | `3` | Integer from `1` to `100` | Maximum claims before terminal failure |
| `delay` | `0` | Seconds from `0` to `86400` | Delay before the first claim |

`Idempotency-Key` is optional and may contain 1 to 200 characters. The first request
returns `201` with `Idempotency-Replayed: false`. Repeating the key returns the original
job with `200` and `Idempotency-Replayed: true`, even when the later payload differs.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `HTTP_HOST` | `127.0.0.1` | REST API bind address |
| `HTTP_PORT` | `3000` | REST API port |
| `TARANTOOL_LISTEN` | `127.0.0.1:3301` | Tarantool native protocol listener |
| `API_BEARER_TOKEN` | unset | Enables bearer authentication when set |
| `TARANTOOL_DATA_DIR` | `./data` | Snapshot, WAL, and Vinyl data directory |
| `TARANTOOL_WAL_MODE` | `fsync` | Durability mode: `fsync` or `write` |
| `TARANTOOL_CHECKPOINT_INTERVAL` | `3600` | Seconds between automatic snapshots |
| `TARANTOOL_CHECKPOINT_COUNT` | `2` | Snapshots to retain, from `2` to `100` |

Invalid bearer-token or persistence configuration stops startup before the listeners
open.

## Run without Compose

Requirements:

- Tarantool
- `tt`
- A C compiler toolchain and `unzip` for native rocks
- PowerShell 7 if you want to run the project tests

Install the rockspec dependencies and start the service:

```shell
task install
task run
```

Without Task:

```shell
tt rocks make tarantool-jobs-queue-scm-1.rockspec
tarantool src/server.lua
```

Authentication is disabled when `API_BEARER_TOKEN` is unset. This is convenient for
loopback-only development, but production deployments should always configure it.

## Stop or remove the service

Stop and remove the containers while preserving data:

```powershell
docker compose down
```

Deleting the named volume permanently deletes the queue and requires explicit intent:

```powershell
docker compose down --volumes
```

See [Operations](operations.md) before deploying or backing up the service.
