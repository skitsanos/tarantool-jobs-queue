param(
    [string]$BaseUri = 'http://127.0.0.1:3000',
    [string]$ContainerName = 'codex-tarantool-jobs-queue-test'
)

$ErrorActionPreference = 'Stop'
$created = $null

try {
    $created = Invoke-RestMethod `
        -Method Post `
        -Uri "$BaseUri/jobs?max_attempts=2" `
        -ContentType 'application/json' `
        -Body '{"kind":"restart-fencing-test"}'
    $first = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim?lease=0.2"
    Start-Sleep -Milliseconds 300

    docker restart $ContainerName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to restart container $ContainerName."
    }

    $version = $null
    1..30 | ForEach-Object {
        if ($null -eq $version) {
            try {
                $candidate = Invoke-RestMethod -Uri "$BaseUri/version" -TimeoutSec 1
                if ($candidate.schema_version -eq 3) {
                    $version = $candidate
                }
            }
            catch {
                Start-Sleep -Milliseconds 250
            }
        }
    }
    if ($null -eq $version) {
        throw 'The server did not recover with schema version 3.'
    }

    $second = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim?lease=30"
    if ($second.job_id -ne $created.job_id `
        -or $second.attempts -ne 2 `
        -or $second.lease_token -eq $first.lease_token) {
        throw 'Restart recovery did not issue a fenced second attempt.'
    }

    $staleStatus = $null
    try {
        Invoke-WebRequest `
            -UseBasicParsing `
            -Method Post `
            -Uri "$BaseUri/jobs/$($created.job_id)/ack" `
            -Headers @{ 'Lease-Token' = $first.lease_token } | Out-Null
    }
    catch {
        $staleStatus = [int]$_.Exception.Response.StatusCode
    }
    if ($staleStatus -ne 409) {
        throw 'The stale pre-restart lease token was not rejected.'
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri "$BaseUri/jobs/$($created.job_id)/ack" `
        -Headers @{ 'Lease-Token' = $second.lease_token } | Out-Null
    Write-Output 'Restart recovery passed: schema, lease retry, and stale-token fencing survived.'
}
finally {
    if ($null -ne $created) {
        try {
            Invoke-RestMethod -Method Delete -Uri "$BaseUri/jobs/$($created.job_id)" | Out-Null
        }
        catch {
            # Preserve the original test failure when cleanup cannot reach the server.
        }
    }
}
