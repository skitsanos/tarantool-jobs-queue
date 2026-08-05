param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$testId = [guid]::NewGuid().ToString('N')
$projectName = "tjq-persistence-$testId"
$imageName = "tarantool-jobs-queue-persistence-test:$testId"
$composeFile = Join-Path $RepositoryRoot 'docker-compose.yaml'
$bearerToken = 'test-only-persistence-token-32-chars'
$headers = @{ Authorization = "Bearer $bearerToken" }
$suitePassed = $false

$previousEnvironment = @{}
foreach ($name in @('API_BEARER_TOKEN', 'HTTP_PUBLISH_PORT', 'TARANTOOL_JOBS_IMAGE')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$env:API_BEARER_TOKEN = $bearerToken
$env:HTTP_PUBLISH_PORT = '0'
$env:TARANTOOL_JOBS_IMAGE = $imageName

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    & docker compose --project-name $projectName --file $composeFile @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose command failed with exit code $LASTEXITCODE."
    }
}

function Get-ContainerId {
    $containerId = & docker compose `
        --project-name $projectName `
        --file $composeFile `
        ps --quiet tarantool1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($containerId)) {
        throw 'Unable to resolve the persistence test container.'
    }
    return $containerId.Trim()
}

function Wait-UntilHealthy {
    param([string]$ContainerId)

    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $state = & docker inspect --format '{{.State.Status}}:{{.State.Health.Status}}' $ContainerId
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to inspect the persistence test container.'
        }
        if ($state -eq 'running:healthy') {
            return
        }
        if ($state -notlike 'running:*') {
            throw "The persistence test container stopped with state $state."
        }
        Start-Sleep -Seconds 1
    }
    throw 'The persistence test container did not become healthy within three minutes.'
}

function Get-BaseUri {
    $portOutput = & docker compose `
        --project-name $projectName `
        --file $composeFile `
        port tarantool1 3000
    if ($LASTEXITCODE -ne 0 -or $portOutput -notmatch ':(\d+)$') {
        throw 'Unable to resolve the persistence test server port.'
    }
    return "http://127.0.0.1:$($Matches[1])"
}

try {
    Write-Output "Starting isolated Compose project $projectName..."
    Invoke-Compose up --detach --build

    $firstContainerId = Get-ContainerId
    Wait-UntilHealthy -ContainerId $firstContainerId
    $baseUri = Get-BaseUri

    $runtimeUser = & docker exec $firstContainerId id -u
    if ($LASTEXITCODE -ne 0 -or $runtimeUser -ne '999') {
        throw 'The production container must run as the non-root tarantool user.'
    }

    $created = Invoke-RestMethod `
        -Method Post `
        -Uri "$baseUri/jobs" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body '{"kind":"container-recreation-test"}'
    if ($created.status -ne 'pending') {
        throw 'The persistence fixture was not created.'
    }

    $dataFiles = & docker exec $firstContainerId sh -c `
        'find /var/lib/tarantool -maxdepth 1 -type f \( -name "*.snap" -o -name "*.xlog" \) -print'
    if ($LASTEXITCODE -ne 0 -or @($dataFiles).Count -eq 0) {
        throw 'The container did not write snapshot or WAL files to the mounted volume.'
    }

    Invoke-Compose up --detach --force-recreate --no-deps tarantool1
    $secondContainerId = Get-ContainerId
    if ($secondContainerId -eq $firstContainerId) {
        throw 'Compose did not replace the original container.'
    }
    Wait-UntilHealthy -ContainerId $secondContainerId
    $baseUri = Get-BaseUri

    $recovered = Invoke-RestMethod `
        -Method Get `
        -Uri "$baseUri/jobs/$($created.job_id)" `
        -Headers $headers
    if ($recovered.status -ne 'pending' `
        -or $recovered.payload.kind -ne 'container-recreation-test') {
        throw 'The job was not recovered after recreating the container.'
    }

    Invoke-RestMethod `
        -Method Delete `
        -Uri "$baseUri/jobs/$($created.job_id)" `
        -Headers $headers | Out-Null

    $suitePassed = $true
    Write-Output 'Persistence recreation passed: Compose replaced the container and recovered its job.'
}
finally {
    if (-not $suitePassed) {
        & docker compose `
            --project-name $projectName `
            --file $composeFile `
            logs --no-color 2>&1
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        if ($projectName.StartsWith('tjq-persistence-')) {
            & docker compose `
                --project-name $projectName `
                --file $composeFile `
                down --volumes --remove-orphans *> $null
        }
        if ($imageName.StartsWith('tarantool-jobs-queue-persistence-test:')) {
            & docker image rm $imageName *> $null
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    }
}
