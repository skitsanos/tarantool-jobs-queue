param(
    [string]$BaseUri = 'http://127.0.0.1:3000',
    [int]$Requests = 10
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$key = 'concurrent-' + [guid]::NewGuid().ToString('N')
$client = [System.Net.Http.HttpClient]::new()
$client.DefaultRequestHeaders.Add('Idempotency-Key', $key)

try {
    $tasks = @()
    1..$Requests | ForEach-Object {
        $content = [System.Net.Http.StringContent]::new(
            '{"kind":"concurrent-idempotency-test"}',
            [System.Text.Encoding]::UTF8,
            'application/json'
        )
        $tasks += $client.PostAsync("$BaseUri/jobs", $content)
    }

    [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks)
    $responses = $tasks | ForEach-Object { $_.Result }
    $created = @($responses | Where-Object { [int]$_.StatusCode -eq 201 })
    $replayed = @($responses | Where-Object { [int]$_.StatusCode -eq 200 })
    if ($created.Count -ne 1 -or $replayed.Count -ne ($Requests - 1)) {
        throw "Expected one creation and $($Requests - 1) replays; " +
            "received $($created.Count) creations and $($replayed.Count) replays."
    }

    $jobs = $responses | ForEach-Object {
        $_.Content.ReadAsStringAsync().Result | ConvertFrom-Json
    }
    $ids = @($jobs.job_id | Select-Object -Unique)
    if ($ids.Count -ne 1) {
        throw 'Concurrent idempotent requests produced more than one job.'
    }

    Invoke-RestMethod -Method Delete -Uri "$BaseUri/jobs/$($ids[0])" | Out-Null
    Write-Output "Concurrent idempotency passed: one creation and $($Requests - 1) replays."
}
finally {
    $client.Dispose()
}
