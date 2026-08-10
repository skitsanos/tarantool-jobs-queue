# Worker guide

A worker repeatedly claims one job, processes its payload, and completes the same
attempt with the lease token returned by the claim. Workers may run concurrently; the
queue atomically selects and transitions one job for each successful claim.

Start with the executable [Python reference worker](../examples/workers/python_worker.py).
It uses only the Python standard library and is intended as a small integration example,
not a framework-specific SDK.

## Worker loop

1. Call `POST /jobs/claim?lease=<seconds>`.
2. On `204`, wait with bounded exponential backoff and jitter before polling again.
3. On `200`, retain `job_id`, `payload`, `attempts`, and `lease_token` together.
4. Dispatch the payload to an idempotent handler.
5. On success, call `POST /jobs/{job_id}/ack` with the `Lease-Token` header.
6. On a retryable error, call `POST /jobs/{job_id}/fail` with an error and retry delay.
7. On a permanent error, call the same failure endpoint with `retry: false`.
8. On graceful shutdown, stop claiming new jobs and finish or release the current job.

Example claim:

```http
POST /jobs/claim?lease=60 HTTP/1.1
Host: 127.0.0.1:3000
Authorization: Bearer <token>
```

The response includes a token scoped to this particular attempt:

```json
{
  "job_id": "ca43f0ea-9ca9-42e8-9df4-335d50770e19",
  "status": "in-progress",
  "payload": {
    "kind": "send-email",
    "recipient": "person@example.com"
  },
  "lease_until": 1785945661.25,
  "lease_token": "389526c8-edf0-4fe6-abdb-03b8236954e5",
  "attempts": 1,
  "max_attempts": 3
}
```

Do not claim another job with the same sequential worker until the current attempt has
been acknowledged, failed, or released. A process that wants concurrency should run a
bounded pool of independent worker loops.

## Completing an attempt

Successful work is acknowledged with:

```http
POST /jobs/ca43f0ea-9ca9-42e8-9df4-335d50770e19/ack HTTP/1.1
Authorization: Bearer <token>
Lease-Token: 389526c8-edf0-4fe6-abdb-03b8236954e5
```

A retryable failure can delay the next claim:

```http
POST /jobs/ca43f0ea-9ca9-42e8-9df4-335d50770e19/fail HTTP/1.1
Authorization: Bearer <token>
Lease-Token: 389526c8-edf0-4fe6-abdb-03b8236954e5
Content-Type: application/json

{
  "error": "upstream service unavailable",
  "retry": true,
  "retry_delay": 30
}
```

`error` must contain 1 to 1000 characters. `retry` defaults to `true`, and
`retry_delay` defaults to zero and may be at most 86400 seconds. If the attempt has
reached `max_attempts`, a retryable failure becomes terminal automatically.

Use `POST /jobs/{job_id}/release` to return work immediately without a failure body.
Release still consumes the current attempt and becomes terminal if the attempt limit
has been reached.

## Leases and stale workers

The lease duration may be from 0.1 to 3600 seconds. There is currently no heartbeat or
lease-renewal endpoint, so select a duration longer than the expected worst-case handler
time. Jobs that can legitimately run longer than one hour need to be divided into
shorter jobs or require a future lease-renewal API.

Expired leases are recovered lazily when another claim arrives or when the expired
worker attempts a transition. The job returns to pending or becomes failed when its
attempt limit has been exhausted.

An `ack`, `fail`, or `release` request can return `409` with:

- `invalid_lease`: another attempt owns the job.
- `lease_expired`: the current lease elapsed.
- `invalid_job_state`: the job is no longer in progress.

Treat all three as lost ownership. Do not retry the transition using the stale token,
and do not assume the work was committed exclusively.

## At-least-once processing

A handler can finish its external side effect and then lose connectivity before its
acknowledgement reaches the queue. The lease eventually expires and another worker can
process the same job. Fencing protects queue state, but it cannot undo or fence an
external side effect.

Design handlers to tolerate duplicates:

- Include a stable business identifier in the payload.
- Prefer idempotent destination APIs or conditional writes.
- Record completed business operations under a unique key before acknowledging.
- Do not use `attempts` as a business identifier.
- Assume two workers can overlap when a lease expires during slow processing.

The producer-side `Idempotency-Key` prevents duplicate queue records for the same key,
but it does not make the worker's external operation exactly once.

## Polling and backoff

An empty queue returns `204`. Avoid tight polling loops: start with a short delay,
increase it while the queue remains empty, cap it, and add jitter so many workers do not
wake simultaneously. Reset the delay after a successful claim.

Network failures should use a separate bounded backoff. Before retrying a transition
after an ambiguous network failure, retrieve the job and inspect its state. Never
substitute a newly claimed lease token for the original attempt.

## Graceful shutdown

On a termination signal:

1. Stop issuing new claim requests.
2. Let a short-running handler finish and acknowledge it.
3. If processing cannot finish safely within the shutdown window, release it with the
   current lease token.
4. Exit after the transition request completes or the lease is known to be lost.

Set the container or process-manager grace period long enough for this sequence.

## Run the Python reference worker

With Python 3.10 or newer, create one or more jobs whose payload has
`"kind": "echo"`, then run:

```powershell
$env:QUEUE_URL = 'http://127.0.0.1:3000'
$env:QUEUE_TOKEN = $env:API_BEARER_TOKEN
python examples/workers/python_worker.py
```

Optional settings:

| Variable | Default | Purpose |
| --- | --- | --- |
| `QUEUE_URL` | `http://127.0.0.1:3000` | Queue API base URL |
| `QUEUE_TOKEN` | unset | Bearer token |
| `WORKER_LEASE_SECONDS` | `60` | Lease requested by each claim |
| `WORKER_HTTP_TIMEOUT` | `10` | HTTP request timeout |
| `WORKER_POLL_MIN_SECONDS` | `0.25` | Initial empty-queue delay |
| `WORKER_POLL_MAX_SECONDS` | `5` | Maximum empty-queue delay |

Replace `handle_job()` with application-specific dispatch and error classification.
The example treats unsupported job kinds as permanent failures and other handler
exceptions as retryable failures.

For every endpoint and response schema, see [the OpenAPI document](openapi.yaml).
