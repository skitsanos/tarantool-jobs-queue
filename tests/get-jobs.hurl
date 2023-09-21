GET http://localhost:{{PORT}}/jobs
HTTP 200

GET http://localhost:{{PORT}}/jobs?status=done
HTTP 200

[Asserts]
jsonpath "$.total" == 0