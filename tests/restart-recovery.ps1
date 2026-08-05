param(
    [string]$BaseUri = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'

$created = Invoke-RestMethod `
    -DisableKeepAlive `
    -Method Post `
    -Uri "$BaseUri/jobs?max_attempts=2" `
    -ContentType 'application/json' `
    -Body '{"kind":"restart-fencing-test"}'
$first = Invoke-RestMethod `
    -DisableKeepAlive `
    -Method Post `
    -Uri "$BaseUri/jobs/claim?lease=0.2"
if ($first.job_id -ne $created.job_id -or $first.attempts -ne 1) {
    throw 'Unable to claim the restart fixture.'
}

[pscustomobject]@{
    job_id = $created.job_id
    lease_token = $first.lease_token
} | ConvertTo-Json -Compress
