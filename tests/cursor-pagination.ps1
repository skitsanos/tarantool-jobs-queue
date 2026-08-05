param(
    [string]$BaseUri = 'http://127.0.0.1:3000'
)

$ErrorActionPreference = 'Stop'
$createdJobs = @()

try {
    1..3 | ForEach-Object {
        $createdJobs += Invoke-RestMethod `
            -Method Post `
            -Uri "$BaseUri/jobs" `
            -ContentType 'application/json' `
            -Body "{`"kind`":`"cursor-test-$($_)`"}"
    }

    $firstPage = Invoke-RestMethod -Method Get -Uri "$BaseUri/jobs?status=pending&limit=2"
    if ($firstPage.data.Count -ne 2 -or [string]::IsNullOrWhiteSpace($firstPage.next_cursor)) {
        throw 'The first cursor page must contain two jobs and a next cursor.'
    }

    $encodedCursor = [uri]::EscapeDataString($firstPage.next_cursor)
    $secondPage = Invoke-RestMethod `
        -Method Get `
        -Uri "$BaseUri/jobs?status=pending&limit=2&cursor=$encodedCursor"
    if ($secondPage.data.Count -ne 1 -or $null -ne $secondPage.next_cursor) {
        throw 'The final cursor page must contain one job and no next cursor.'
    }
    if ($firstPage.total -ne 3 -or $secondPage.total -ne 3) {
        throw 'Cursor pages must report a total of three pending jobs.'
    }

    $allIds = @($firstPage.data.job_id) + @($secondPage.data.job_id)
    if (@($allIds | Select-Object -Unique).Count -ne 3) {
        throw 'Cursor pages returned a duplicate or omitted job.'
    }

    $mismatchedCursorUri = "$BaseUri/jobs?status=done&limit=2&cursor=$encodedCursor"
    try {
        Invoke-RestMethod -Method Get -Uri $mismatchedCursorUri | Out-Null
        throw 'A cursor reused with another status should have failed.'
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 400) {
            throw
        }
    }

    Write-Output 'Cursor pagination passed: three unique jobs across two stable pages.'
}
finally {
    foreach ($job in $createdJobs) {
        Invoke-RestMethod -Method Delete -Uri "$BaseUri/jobs/$($job.job_id)" | Out-Null
    }
}

