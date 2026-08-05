param(
    [ValidateSet('All', 'Lint', 'Unit', 'Http')]
    [string]$Suite = 'All'
)

$ErrorActionPreference = 'Stop'
$TarantoolImage = 'tarantool/tarantool:3.8.0'
$HurlImage = 'ghcr.io/orange-opensource/hurl:8.0.1'
$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$RepositoryMount = "${RepositoryRoot}:/workspace:ro"

if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker is required to run the test harness.'
}

function Invoke-Docker {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed with exit code $LASTEXITCODE."
    }
}

function Invoke-LintSuite {
    Write-Output 'Checking Lua sources with Luacheck...'
    Invoke-Docker run --rm `
        --volume $RepositoryMount `
        --workdir /tmp `
        --entrypoint sh `
        $TarantoolImage `
        -lc "apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates git unzip && mkdir -p /tmp/lint && cd /tmp/lint && tt rocks install luacheck 0.26.0-1 >/dev/null && env -u TT_APP_NAME -u TT_INSTANCE_NAME .rocks/bin/luacheck --config /workspace/.luacheckrc /workspace/src /workspace/tests/*.lua"

    Write-Output 'Checking Hurl formatting...'
    Invoke-Docker run --rm `
        --volume $RepositoryMount `
        --entrypoint hurlfmt `
        $HurlImage `
        --check `
        /workspace/tests/new-job.hurl `
        /workspace/tests/get-jobs.hurl `
        /workspace/tests/restart-recovery.hurl
}

function Invoke-UnitSuite {
    foreach ($testFile in @('jobs-unit.lua', 'schema-migrations.lua')) {
        Write-Output "Running $testFile..."
        Invoke-Docker run --rm `
            --volume $RepositoryMount `
            --workdir /tmp `
            --entrypoint env `
            $TarantoolImage `
            -u TT_APP_NAME `
            -u TT_INSTANCE_NAME `
            tarantool "/workspace/tests/$testFile"
    }
}

function Invoke-HttpSuite {
    $containerName = 'tarantool-jobs-queue-test-' + [guid]::NewGuid().ToString('N')
    $serverReady = $false
    $suitePassed = $false

    try {
        Write-Output "Starting isolated API container $containerName..."
        Invoke-Docker run --detach `
            --name $containerName `
            --publish '127.0.0.1::3000' `
            --volume $RepositoryMount `
            --workdir /tmp `
            --entrypoint sh `
            $TarantoolImage `
            /workspace/tests/start-test-server.sh | Out-Null

        $portOutput = & docker port $containerName '3000/tcp'
        if ($LASTEXITCODE -ne 0 -or $portOutput -notmatch ':(\d+)$') {
            throw 'Unable to resolve the test server port.'
        }
        $baseUri = "http://127.0.0.1:$($Matches[1])"

        $deadline = (Get-Date).AddMinutes(3)
        while ((Get-Date) -lt $deadline) {
            $running = & docker inspect --format '{{.State.Running}}' $containerName
            if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
                throw 'The test API container exited during startup.'
            }
            try {
                $version = Invoke-RestMethod -Uri "$baseUri/version" -TimeoutSec 2
                if ($version.schema_version -eq 3) {
                    $serverReady = $true
                    break
                }
            }
            catch {
                Start-Sleep -Seconds 1
            }
        }
        if (-not $serverReady) {
            throw 'The test API did not become ready within three minutes.'
        }

        Write-Output 'Running isolated Hurl contracts...'
        Invoke-Docker run --rm `
            --network "container:$containerName" `
            --volume $RepositoryMount `
            $HurlImage `
            --test `
            --jobs 1 `
            --variables-file /workspace/tests/.vars `
            /workspace/tests/new-job.hurl `
            /workspace/tests/get-jobs.hurl

        Write-Output 'Running queue integration scenarios...'
        & (Join-Path $PSScriptRoot 'cursor-pagination.ps1') -BaseUri $baseUri
        & (Join-Path $PSScriptRoot 'concurrent-claim.ps1') -BaseUri $baseUri
        & (Join-Path $PSScriptRoot 'concurrent-idempotency.ps1') -BaseUri $baseUri
        & (Join-Path $PSScriptRoot 'lease-retry.ps1') -BaseUri $baseUri
        if ($env:OS -eq 'Windows_NT') {
            Write-Output 'Restart recovery is exercised in Linux CI (Docker Desktop restart is skipped).'
        }
        else {
            $restartFixtureJson = & (Join-Path $PSScriptRoot 'restart-recovery.ps1') `
                -BaseUri $baseUri
            $restartFixture = $restartFixtureJson | ConvertFrom-Json
            Start-Sleep -Milliseconds 300
            Invoke-Docker restart $containerName | Out-Null

            Invoke-Docker run --rm `
                --network "container:$containerName" `
                --volume $RepositoryMount `
                $HurlImage `
                --test `
                --retry 30 `
                --retry-interval 500 `
                --variables-file /workspace/tests/.vars `
                --variable "job_id=$($restartFixture.job_id)" `
                --variable "first_lease_token=$($restartFixture.lease_token)" `
                /workspace/tests/restart-recovery.hurl
        }

        $suitePassed = $true
        Write-Output 'HTTP integration suite passed.'
    }
    finally {
        if (-not $suitePassed) {
            Write-Output 'Test server logs:'
            & docker logs $containerName 2>&1
        }
        & docker rm --force $containerName 2>&1 | Out-Null
    }
}

switch ($Suite) {
    'Lint' { Invoke-LintSuite }
    'Unit' { Invoke-UnitSuite }
    'Http' { Invoke-HttpSuite }
    'All' {
        Invoke-LintSuite
        Invoke-UnitSuite
        Invoke-HttpSuite
    }
}
