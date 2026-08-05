# Tarantool Jobs Queue with REST API

A persistent jobs queue implemented as a Tarantool Lua application and exposed over HTTP.

## Requirements

- Tarantool
- The Tarantool `http` rock, version `1.9.0-1`
- Hurl for HTTP contract tests
- PowerShell for the concurrency, lease, retry, and cursor tests

The application includes a rockspec declaring its Lua dependencies.

## Running

Install the HTTP dependency and start the application:

```shell
tt rocks install http 1.9.0-1
tarantool src/server.lua
```

Configuration is available through environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HTTP_HOST` | `0.0.0.0` | REST API bind address |
| `HTTP_PORT` | `3000` | REST API port |
| `TARANTOOL_LISTEN` | `0.0.0.0:3301` | Tarantool native protocol listener |

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

Run the API against a database with no pre-existing pending jobs, then execute:

```powershell
hurl --test --jobs 1 --variables-file tests/.vars tests/new-job.hurl tests/get-jobs.hurl
pwsh -File tests/cursor-pagination.ps1
pwsh -File tests/concurrent-claim.ps1
pwsh -File tests/concurrent-idempotency.ps1
pwsh -File tests/lease-retry.ps1
pwsh -File tests/restart-recovery.ps1 -ContainerName <running-container>
```

The migration test runs directly in Tarantool and constructs a legacy schema before upgrading it:

```powershell
docker run --rm -v "$($PWD.Path):/workspace" -w /tmp `
  --entrypoint env tarantool/tarantool:latest `
  -u TT_APP_NAME -u TT_INSTANCE_NAME `
  tarantool /workspace/tests/schema-migrations.lua
```

## Delivery semantics

This is a single-instance, lease-based at-least-once queue. A worker may process a job more than once when its lease expires before acknowledgement. Per-attempt fencing tokens prevent stale workers from modifying a reclaimed job. Attempts stop automatically at `max_attempts`, after which the job remains visible in the `failed` state for inspection or manual retry. Lease recovery is lazy and occurs during claim requests or when an expired worker attempts a transition, rather than in a background scheduler.
