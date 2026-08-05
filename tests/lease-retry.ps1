param(
    [string]$BaseUri = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'

function Assert-LeaseConflict {
    param(
        [string]$Uri,
        [string]$LeaseToken
    )

    $statusCode = $null
    try {
        Invoke-WebRequest `
            -Method Post `
            -Uri $Uri `
            -Headers @{ 'Lease-Token' = $LeaseToken } `
            -UseBasicParsing | Out-Null
    }
    catch {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -ne 409) {
        throw "Expected a lease conflict from $Uri."
    }
}

$created = Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUri/jobs?max_attempts=2" `
    -ContentType 'application/json' `
    -Body '{"kind":"lease-retry-test"}'

$firstClaim = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim?lease=0.2"
if ($firstClaim.job_id -ne $created.job_id -or $firstClaim.attempts -ne 1) {
    throw 'The first leased claim was incorrect.'
}

Start-Sleep -Milliseconds 300
Assert-LeaseConflict `
    -Uri "$BaseUri/jobs/$($created.job_id)/ack" `
    -LeaseToken $firstClaim.lease_token
$secondClaim = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim?lease=0.2"
if ($secondClaim.job_id -ne $created.job_id -or $secondClaim.attempts -ne 2) {
    throw 'The expired lease was not recovered for the second attempt.'
}
Assert-LeaseConflict `
    -Uri "$BaseUri/jobs/$($created.job_id)/ack" `
    -LeaseToken $firstClaim.lease_token

Start-Sleep -Milliseconds 300
$emptyResponse = Invoke-WebRequest `
    -Method Post `
    -Uri "$BaseUri/jobs/claim?lease=0.2" `
    -UseBasicParsing
if ($emptyResponse.StatusCode -ne 204) {
    throw 'The queue should be empty after terminal lease failure.'
}

$failed = Invoke-RestMethod -Method Get -Uri "$BaseUri/jobs/$($created.job_id)"
if ($failed.status -ne 'failed' `
    -or $failed.attempts -ne 2 `
    -or $failed.last_error -notlike '*lease expired*') {
    throw 'Lease expiry did not produce the expected terminal failure.'
}

$retried = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/$($created.job_id)/retry"
if ($retried.status -ne 'pending' -or $retried.attempts -ne 0) {
    throw 'Manual retry did not reset the failed job.'
}

$finalClaim = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim"
Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUri/jobs/$($finalClaim.job_id)/ack" `
    -Headers @{ 'Lease-Token' = $finalClaim.lease_token } | Out-Null

$delayed = Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUri/jobs?max_attempts=2" `
    -ContentType 'application/json' `
    -Body '{"kind":"delayed-retry-test"}'
$delayedClaim = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim"
$failureBody = '{"error":"retry later","retry":true,"retry_delay":0.2}'
$pendingRetry = Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUri/jobs/$($delayedClaim.job_id)/fail" `
    -Headers @{ 'Lease-Token' = $delayedClaim.lease_token } `
    -ContentType 'application/json' `
    -Body $failureBody
if ($pendingRetry.status -ne 'pending' -or $pendingRetry.attempts -ne 1) {
    throw 'Retryable failure did not return the job to pending.'
}

$beforeDelay = Invoke-WebRequest `
    -Method Post `
    -Uri "$BaseUri/jobs/claim" `
    -UseBasicParsing
if ($beforeDelay.StatusCode -ne 204) {
    throw 'A delayed retry became claimable too early.'
}

Start-Sleep -Milliseconds 300
$afterDelay = Invoke-RestMethod -Method Post -Uri "$BaseUri/jobs/claim"
if ($afterDelay.job_id -ne $delayed.job_id -or $afterDelay.attempts -ne 2) {
    throw 'A delayed retry did not become claimable after its delay.'
}

$terminalBody = '{"error":"permanent failure","retry":false}'
$terminal = Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUri/jobs/$($afterDelay.job_id)/fail" `
    -Headers @{ 'Lease-Token' = $afterDelay.lease_token } `
    -ContentType 'application/json' `
    -Body $terminalBody
if ($terminal.status -ne 'failed' -or $terminal.last_error -ne 'permanent failure') {
    throw 'A non-retryable failure did not become terminal.'
}
Invoke-RestMethod -Method Delete -Uri "$BaseUri/jobs/$($terminal.job_id)" | Out-Null

Write-Output 'Lease and retry tests passed: expiry recovery, caps, delay, manual reset, and terminal failure.'
