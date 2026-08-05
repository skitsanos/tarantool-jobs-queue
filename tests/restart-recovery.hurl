# Wait for the restarted server and confirm that its migrated schema is intact.
GET http://localhost:{{PORT}}/version
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.schema_version" == 3


# The expired pre-restart lease is recovered as a fenced second attempt.
POST http://localhost:{{PORT}}/jobs/claim?lease=30
HTTP 200
Content-Type: application/json; charset=utf-8
[Captures]
second_lease_token: jsonpath "$.lease_token"
[Asserts]
jsonpath "$.job_id" == "{{job_id}}"
jsonpath "$.attempts" == 2
jsonpath "$.lease_token" != "{{first_lease_token}}"


# A worker holding the stale pre-restart token cannot acknowledge the new attempt.
POST http://localhost:{{PORT}}/jobs/{{job_id}}/ack
Lease-Token: {{first_lease_token}}
HTTP 409
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_lease"


POST http://localhost:{{PORT}}/jobs/{{job_id}}/ack
Lease-Token: {{second_lease_token}}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "done"


DELETE http://localhost:{{PORT}}/jobs/{{job_id}}
HTTP 204
