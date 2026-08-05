param(
    [string]$BaseUri = 'http://127.0.0.1:3000',
    [int]$Consumers = 10
)

$ErrorActionPreference = 'Stop'

if ($Consumers -lt 2) {
    throw 'Consumers must be at least 2.'
}

$created = Invoke-RestMethod `
    -Method Post `
    -Uri "$BaseUri/jobs" `
    -ContentType 'application/json' `
    -Body '{"kind":"concurrent-claim-test"}'

Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()

try {
    $tasks = @()
    1..$Consumers | ForEach-Object {
        $tasks += $client.PostAsync(
            "$BaseUri/jobs/claim",
            [System.Net.Http.StringContent]::new('')
        )
    }

    [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks)
    $responses = $tasks | ForEach-Object { $_.Result }
    $claimedResponses = @($responses | Where-Object { [int]$_.StatusCode -eq 200 })
    $emptyResponses = @($responses | Where-Object { [int]$_.StatusCode -eq 204 })

    if ($claimedResponses.Count -ne 1 -or $emptyResponses.Count -ne ($Consumers - 1)) {
        throw "Expected one claim and $($Consumers - 1) empty responses; " +
            "received $($claimedResponses.Count) claims and $($emptyResponses.Count) empty responses."
    }

    $claimedBody = $claimedResponses[0].Content.ReadAsStringAsync().Result
    $claimed = $claimedBody | ConvertFrom-Json
    if ($claimed.job_id -ne $created.job_id -or $claimed.status -ne 'in-progress') {
        throw "Unexpected claimed job: $claimedBody"
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri "$BaseUri/jobs/$($claimed.job_id)/ack" `
        -Headers @{ 'Lease-Token' = $claimed.lease_token } | Out-Null
    Write-Output "Concurrent claim passed: one claim and $($Consumers - 1) empty responses."
}
finally {
    $client.Dispose()
}
