# Liveness remains public so an orchestrator can detect the HTTP process.
GET http://localhost:{{PORT}}/health/live
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "ok"


# Readiness exposes storage state and therefore requires authorization.
GET http://localhost:{{PORT}}/health/ready
HTTP 401
Content-Type: application/json; charset=utf-8
WWW-Authenticate: Bearer realm="tarantool-jobs-queue"
[Asserts]
jsonpath "$.error.code" == "unauthorized"


GET http://localhost:{{PORT}}/version
Authorization: Bearer incorrect-token
HTTP 401
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "unauthorized"


# The scheme is case-insensitive, as required for HTTP authentication schemes.
GET http://localhost:{{PORT}}/health/ready
Authorization: bearer {{bearer_token}}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "ok"


# An unauthorized mutation must fail before creating a job.
POST http://localhost:{{PORT}}/jobs
Content-Type: application/json
{
    "kind": "must-not-be-created"
}
HTTP 401
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "unauthorized"


GET http://localhost:{{PORT}}/jobs
Authorization: Bearer {{bearer_token}}
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.total" == 0
jsonpath "$.data" count == 0
