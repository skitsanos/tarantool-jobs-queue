GET http://localhost:{{PORT}}/health/live
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "ok"


GET http://localhost:{{PORT}}/version
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.version" == "1.0.0-beta"
jsonpath "$.schema_version" == 3


GET http://localhost:{{PORT}}/health/ready
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.status" == "ok"
jsonpath "$.checks.schema.ready" == true
jsonpath "$.checks.schema.version" == 3
jsonpath "$.checks.schema.expected_version" == 3
jsonpath "$.checks.storage.writable" == true
jsonpath "$.checks.storage.write_probe" == true


GET http://localhost:{{PORT}}/jobs?limit=25
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.limit" == 25
jsonpath "$.total" isInteger
jsonpath "$.data" isCollection


GET http://localhost:{{PORT}}/jobs?status=failed
HTTP 200
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.data" isCollection


GET http://localhost:{{PORT}}/jobs?status=unknown
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_status"


GET http://localhost:{{PORT}}/jobs?limit=0
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_pagination"


GET http://localhost:{{PORT}}/jobs?offset=0
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_pagination"


GET http://localhost:{{PORT}}/jobs?cursor=not-a-valid-cursor
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_cursor"


GET http://localhost:{{PORT}}/jobs/00000000-0000-0000-0000-000000000000
HTTP 404
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "job_not_found"


POST http://localhost:{{PORT}}/jobs
Content-Type: application/json
[]
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_payload"


POST http://localhost:{{PORT}}/jobs?max_attempts=0
Content-Type: application/json
{}
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_max_attempts"


POST http://localhost:{{PORT}}/jobs/claim?lease=0
HTTP 400
Content-Type: application/json; charset=utf-8
[Asserts]
jsonpath "$.error.code" == "invalid_lease"
