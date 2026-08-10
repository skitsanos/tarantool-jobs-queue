# Development

## Project layout

```text
src/                    Tarantool application modules and HTTP server
tests/                  Lua unit tests, Hurl contracts, and PowerShell scenarios
docs/openapi.yaml       HTTP API contract
examples/workers/       Runnable consumer examples
Dockerfile              Pinned production image
docker-compose.yaml     Single-instance persistent deployment
Taskfile.yml            Development commands
```

Lua runtime dependencies belong in `tarantool-jobs-queue-scm-1.rockspec`. Verify
published versions with `tt rocks search`; GitHub release tags do not guarantee that a
matching Tarantool rock exists.

## Tests

Run the complete isolated suite:

```powershell
task test
```

Focused commands:

```powershell
task lint
task test:unit
task test:http
```

Without Task, invoke `pwsh -NoProfile -File tests/run.ps1 -Suite All`, or use `Lint`,
`Unit`, or `Http`.

The harness uses pinned Tarantool and Hurl images. It creates an ephemeral database and
API container, waits for readiness, runs checks sequentially, prints logs on failure,
and removes the test container afterward.

The unit suite covers storage, transitions, leases, fencing, retries, pagination,
persistence settings, metadata, and migrations. HTTP validation covers contracts,
competing consumers, concurrent idempotency, cursor behavior, lease recovery,
authentication, container restart, and volume recreation. Docker Desktop on Windows
skips the direct container-restart scenario; Linux CI owns that scenario.

Format-check HTTP contracts directly with:

```powershell
hurlfmt --check tests/*.hurl
```

Run contracts against a clean, already-running test service with:

```powershell
hurl --test --jobs 1 --variables-file tests/.vars tests/*.hurl
```

## Queue invariants

Changes to queue behavior must preserve these properties:

- Claim selection and transition are one atomic operation.
- Status queries use the status index and preserve stable FIFO ordering.
- Every claim increments attempts and creates a fenced lease.
- State transitions reject missing jobs, invalid states, stale tokens, and expired
  leases explicitly.
- Expired leases are recovered before another ready job is selected.
- Concurrent requests sharing an idempotency key create one job.
- Pagination cursors recover the exact indexed key from the referenced job.

Run the competing-consumer, lease/retry, concurrent-idempotency, cursor, and migration
tests whenever the data model or lifecycle changes.

## Schema migrations

The current jobs schema version is `3`. Its version is stored in Tarantool's `_schema`
space under a jobs-space-specific key.

An existing legacy five-field space is treated as version 1. Version 2 adds retries,
leases, and idempotency fields; version 3 adds fenced lease tokens. Migrations are
idempotent, and their version marker is written only after the migration completes.

Never describe a migration as safe until both upgrade and interrupted-reapply tests
pass.

## Maintaining the API contract

`docs/openapi.yaml` is the detailed public HTTP contract. Update it in the same change
whenever a route, parameter, header, status code, response body, or authentication rule
changes. Keep the README API table as a short discovery index rather than a duplicate
reference. The metadata unit test also prevents `info.version` from drifting from the
API version in `src/metadata.lua`.

Contract tests remain the runtime proof of behavior. The OpenAPI document does not
replace Hurl coverage.
