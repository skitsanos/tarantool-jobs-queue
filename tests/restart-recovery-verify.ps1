param(
    [string]$BaseUri,
    [string]$JobId,
    [string]$FirstLeaseToken
)

$ErrorActionPreference = 'Stop'

try {
    $version = Invoke-RestMethod `
        -DisableKeepAlive `
        -Uri "$BaseUri/version" `
        -TimeoutSec 5
    if ($version.schema_version -ne 3) {
        throw 'The server did not recover with schema version 3.'
    }

    $second = Invoke-RestMethod `
        -DisableKeepAlive `
        -Method Post `
        -Uri "$BaseUri/jobs/claim?lease=30" `
        -TimeoutSec 5
    if ($second.job_id -ne $JobId `
        -or $second.attempts -ne 2 `
        -or $second.lease_token -eq $FirstLeaseToken) {
        throw 'Restart recovery did not issue a fenced second attempt.'
    }

    $staleStatus = $null
    try {
        Invoke-WebRequest `
            -DisableKeepAlive `
            -UseBasicParsing `
            -Method Post `
            -Uri "$BaseUri/jobs/$JobId/ack" `
            -Headers @{ 'Lease-Token' = $FirstLeaseToken } `
            -TimeoutSec 5 | Out-Null
    }
    catch {
        $staleStatus = [int]$_.Exception.Response.StatusCode
    }
    if ($staleStatus -ne 409) {
        throw 'The stale pre-restart lease token was not rejected.'
    }

    $acknowledged = Invoke-RestMethod `
        -DisableKeepAlive `
        -Method Post `
        -Uri "$BaseUri/jobs/$JobId/ack" `
        -Headers @{ 'Lease-Token' = $second.lease_token } `
        -TimeoutSec 5
    if ($acknowledged.status -ne 'done') {
        throw 'The recovered job could not be acknowledged.'
    }
    Write-Output 'Restart recovery passed: schema, lease retry, and stale-token fencing survived.'
}
finally {
    try {
        Invoke-RestMethod `
            -DisableKeepAlive `
            -Method Delete `
            -Uri "$BaseUri/jobs/$JobId" `
            -TimeoutSec 5 | Out-Null
    }
    catch {
        # Preserve the original test failure when cleanup cannot reach the server.
    }
}
