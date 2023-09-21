POST http://localhost:{{PORT}}/jobs
Content-Type: application/json
{
    "kind": "extract-tables",
    "file": "demo.pdf",
    "bucket": "public"
}
HTTP 201
