# Tarantool Jobs Queue

A persistent, lease-based jobs queue implemented as a Tarantool Lua application and
exposed over HTTP.

The queue provides atomic FIFO claims, retry limits, delayed availability,
idempotent creation, cursor pagination, and per-attempt fencing tokens. It is designed
for a single Tarantool instance and provides at-least-once delivery.

## Quick start

Requirements: Docker with Compose.

Set an API token and start the service:

```powershell
$env:API_BEARER_TOKEN = '<random-secret-of-at-least-32-characters>'
docker compose up --build --detach
docker compose ps
```

The API is published at `http://127.0.0.1:3000`. Queue data is stored in the
`jobs-data` named volume and survives `docker compose down`. Do not use
`docker compose down --volumes` unless you intend to delete the queue.

Check readiness:

```powershell
$headers = @{ Authorization = "Bearer $env:API_BEARER_TOKEN" }
Invoke-RestMethod http://127.0.0.1:3000/health/ready -Headers $headers
```

Create, claim, and acknowledge a job:

```powershell
$job = Invoke-RestMethod `
  -Method Post `
  -Uri 'http://127.0.0.1:3000/jobs?max_attempts=3' `
  -Headers $headers `
  -ContentType 'application/json' `
  -Body '{"kind":"send-email","recipient":"person@example.com"}'

$claimed = Invoke-RestMethod `
  -Method Post `
  -Uri 'http://127.0.0.1:3000/jobs/claim?lease=60' `
  -Headers $headers

$ackHeaders = $headers + @{ 'Lease-Token' = $claimed.lease_token }
Invoke-RestMethod `
  -Method Post `
  -Uri "http://127.0.0.1:3000/jobs/$($claimed.job_id)/ack" `
  -Headers $ackHeaders
```

## How it works

```text
                                      acknowledge
                            +----------------------> done
                            |
pending -- atomic claim --> in-progress
   ^            + lease     |
   |                        +-- retryable failure, release,
   |                            or expired lease
   +------------------------------------+

in-progress -- permanent failure or exhausted attempts --> failed
failed      -- manual retry --------------------------------> pending
```

Every claim increments `attempts` and returns a unique `lease_token`. A worker must
provide that token when acknowledging, failing, or releasing the attempt. Expired or
superseded tokens receive `409`, preventing stale workers from changing a reclaimed
job.

Because delivery is at least once, worker handlers must tolerate duplicate execution.
See the [worker guide](docs/worker-guide.md) and the
[Python reference worker](examples/workers/python_worker.py).

## Documentation

- [Getting started and configuration](docs/getting-started.md)
- [Building and running workers](docs/worker-guide.md)
- [Operations, persistence, and security](docs/operations.md)
- [Development, migrations, and tests](docs/development.md)
- [OpenAPI 3.1 specification](docs/openapi.yaml)

## API overview

| Method and path | Purpose |
| --- | --- |
| `POST /jobs` | Create or idempotently replay a job |
| `GET /jobs` | Cursor-paginate jobs |
| `POST /jobs/claim` | Atomically claim an available job |
| `GET /jobs/:id` | Retrieve a job |
| `POST /jobs/:id/ack` | Complete a leased attempt |
| `POST /jobs/:id/fail` | Report a retryable or permanent failure |
| `POST /jobs/:id/release` | Return a leased attempt immediately |
| `POST /jobs/:id/retry` | Reset a failed job to pending |
| `DELETE /jobs/:id` | Delete a job idempotently |
| `GET /version` | Return API and schema versions |
| `GET /health/live` | Confirm that the HTTP process is alive |
| `GET /health/ready` | Verify schema state and write availability |

When `API_BEARER_TOKEN` is configured, every endpoint except `/health/live` requires
`Authorization: Bearer <token>`. See the OpenAPI specification for parameters,
schemas, and error responses.

## Development

Run the complete isolated validation suite:

```powershell
task test
```

Focused commands are `task lint`, `task test:unit`, and `task test:http`. The suite
uses pinned Tarantool and Hurl container images and does not reuse the production data
volume.

The application can also run directly with Tarantool; see
[Getting started](docs/getting-started.md#run-without-compose).

## Delivery and durability boundaries

- Delivery is at least once, not exactly once.
- Lease recovery is triggered by claim or transition requests, not a background timer.
- There is currently no lease-renewal endpoint; choose a lease longer than expected
  processing time.
- The default named volume provides local persistence, not backup, replication, or
  high availability.

## License

[MIT](LICENSE)
