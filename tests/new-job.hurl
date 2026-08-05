# Create a job with a two-attempt limit and an idempotency key.
POST http://localhost:{{PORT}}/jobs?max_attempts=2
Content-Type: application/json
Idempotency-Key: lifecycle-test-v2
{
    "kind": "extract-tables",
    "file": "demo.pdf",
    "bucket": "public"
}
HTTP 201
Content-Type: application/json; charset=utf-8
Idempotency-Replayed: false
[Captures]
job_id: jsonpath "$.job_id"
[Asserts]
jsonpath "$.status" == "pending"
jsonpath "$.payload.kind" == "extract-tables"
jsonpath "$.attempts" == 0
jsonpath "$.max_attempts" == 2
jsonpath "$.lease_until" == null


# Repeating the same key returns the original job instead of inserting another.
POST http://localhost:{{PORT}}/jobs?max_attempts=2
Content-Type: application/json
Idempotency-Key: lifecycle-test-v2
{
    "kind": "extract-tables",
    "file": "demo.pdf",
    "bucket": "public"
}
HTTP 200
Content-Type: application/json; charset=utf-8
Idempotency-Replayed: true
[Asserts]
jsonpath "$.job_id" == "{{job_id}}"


POST http://localhost:{{PORT}}/jobs/claim?lease=30
HTTP 200
Content-Type: application/json; charset=utf-8
[Captures]
lease_token_1: jsonpath "$.lease_token"
[Asserts]
jsonpath "$.job_id" == "{{job_id}}"
jsonpath "$.status" == "in-progress"
jsonpath "$.attempts" == 1
jsonpath "$.lease_until" != null


# A retryable failure returns the job to the ready queue without resetting attempts.
POST http://localhost:{{PORT}}/jobs/{{job_id}}/fail
Content-Type: application/json
Lease-Token: {{lease_token_1}}
{
    "error": "temporary worker failure",
    "retry": true,
    "retry_delay": 0
}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "pending"
jsonpath "$.attempts" == 1
jsonpath "$.last_error" == "temporary worker failure"
jsonpath "$.lease_until" == null


POST http://localhost:{{PORT}}/jobs/claim?lease=30
HTTP 200
Content-Type: application/json; charset=utf-8
[Captures]
lease_token_2: jsonpath "$.lease_token"
[Asserts]
jsonpath "$.job_id" == "{{job_id}}"
jsonpath "$.status" == "in-progress"
jsonpath "$.attempts" == 2


# Releasing after the attempt cap produces a terminal failure.
POST http://localhost:{{PORT}}/jobs/{{job_id}}/release
Lease-Token: {{lease_token_2}}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "failed"
jsonpath "$.attempts" == 2


# Manual retry resets the attempt counter.
POST http://localhost:{{PORT}}/jobs/{{job_id}}/retry
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "pending"
jsonpath "$.attempts" == 0
jsonpath "$.last_error" == null


POST http://localhost:{{PORT}}/jobs/claim
HTTP 200
Content-Type: application/json; charset=utf-8
[Captures]
lease_token_3: jsonpath "$.lease_token"
[Asserts]
jsonpath "$.job_id" == "{{job_id}}"
jsonpath "$.attempts" == 1


POST http://localhost:{{PORT}}/jobs/{{job_id}}/ack
Lease-Token: {{lease_token_3}}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "done"
jsonpath "$.lease_until" == null


# Verify the terminal representation, then remove the fixture so this file is rerunnable.
GET http://localhost:{{PORT}}/jobs/{{job_id}}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "done"
jsonpath "$.attempts" == 1


DELETE http://localhost:{{PORT}}/jobs/{{job_id}}
HTTP 204


GET http://localhost:{{PORT}}/jobs/{{job_id}}
HTTP 404
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "job_not_found"
