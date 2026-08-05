# Repository Agent Instructions

## Scope

These instructions apply to the entire repository.

## Issue ledger

- Read the gitignored `ISSUES.md` before starting maintenance work.
- Keep only unresolved items in the ledger.
- Remove an item only after the relevant implementation and validation are complete.
- Do not add an `.editorconfig`; the maintainer has explicitly declined it.

## Queue invariants

- A job claim must select and transition the same job atomically.
- Status-based operations must use the `status` secondary index, never the `job_id` primary index.
- A successful claim returns the updated `in-progress` job.
- State transitions must reject missing jobs and invalid source states explicitly.
- Preserve stable FIFO ordering when changing indexes or pagination.
- Every claim must increment `attempts`, set a lease, and enforce `max_attempts`.
- Acknowledge, fail, and release must validate the current per-attempt lease token so stale workers are fenced out.
- Expired leases must be recovered before selecting another ready job.
- Idempotent creation must return one job under concurrent requests sharing a key.
- Cursor pagination must not serialize floating-point timestamps as resume keys; resolve the cursor job to recover its exact indexed key.

## Dependencies

- Declare Lua dependencies in the project rockspec.
- Verify versions against `tt rocks search`; GitHub tags do not necessarily match packages published on the Tarantool rocks server.
- Avoid floating runtime or dependency versions in reproducible workflows.

## Validation

- Prefer `task test` for the complete isolated validation suite.
- Run focused suites with `task lint`, `task test:unit`, or `task test:http`.
- Docker Desktop on Windows skips restart recovery; Linux CI owns that scenario.
- Format-check Hurl files with `hurlfmt --check tests/*.hurl`.
- Run HTTP contracts against a clean database with:
  `hurl --test --jobs 1 --variables-file tests/.vars tests/*.hurl`.
- Exercise create, retrieve, claim, release, reclaim, and acknowledge when changing queue behavior.
- Include a competing-consumer test when changing claim or transaction logic.
- Run lease/retry, concurrent idempotency, cursor pagination, and schema migration tests when changing the data model or lifecycle.
- If the required runtime is unavailable, report which static checks ran and what remains unverified.

## Documentation

- Update the README whenever endpoints, configuration, states, dependencies, or delivery guarantees change.
- Do not describe lease recovery, retries, or at-least-once delivery as implemented until runtime tests prove them.
