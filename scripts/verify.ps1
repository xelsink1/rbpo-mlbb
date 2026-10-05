param(
    [ValidateRange(1024, 65535)][int]$Port = 18080,
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$repo = Split-Path -Parent $PSScriptRoot
$project = 'wisedubs-ek1-check-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$envFile = [System.IO.Path]::GetTempFileName()
$password = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$probeToken = [guid]::NewGuid().ToString('N')
$oldPassword = $env:POSTGRES_PASSWORD
$oldPort = $env:API_PORT
$dbPaused = $false
$started = $false
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(10)
$cases = [System.Collections.Generic.List[object]]::new()
$script:ComposeArgs = @('compose', '--project-name', $project, '--env-file', $envFile,
    '--project-directory', $repo, '-f', (Join-Path $repo 'compose.yaml'))

function Invoke-Compose {
    param([string[]]$CommandArguments)
    & docker @script:ComposeArgs @CommandArguments
    if ($LASTEXITCODE -ne 0) { throw 'Compose command failed; see the preceding operation.' }
}

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Request-Health {
    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get, "http://127.0.0.1:$Port/health?probe=$probeToken")
    $request.Headers.TryAddWithoutValidation('Authorization', "Bearer $probeToken") | Out-Null
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $watch.Stop()
        return [pscustomobject]@{
            Code = [int]$response.StatusCode
            Body = $body
            Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        }
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
    }
}

function Wait-Ready {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 60) {
        try {
            $result = Request-Health
            if ($result.Code -eq 200 -and $result.Body -ceq '{"status":"ready"}') { return $result }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
    throw 'API did not become ready within 60 seconds.'
}

function Record-Case {
    param([string]$Name, $Result)
    $cases.Add([pscustomobject]@{ Name = $Name; Passed = $true; Result = $Result })
    Write-Host "PASS: $Name"
}

function Get-SourceFingerprint {
    $paths = @('.dockerignore', 'Dockerfile', 'compose.yaml', 'scripts/verify.ps1',
        'src/WiseDubs.Api/Program.cs', 'src/WiseDubs.Api/WiseDubs.Api.csproj',
        'src/WiseDubs.Api/packages.lock.json')
    $lines = foreach ($path in $paths) {
        $content = [System.IO.File]::ReadAllText((Join-Path $repo $path)).Replace([string][char]13 + [char]10, [string][char]10)
        $hasher = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = [BitConverter]::ToString($hasher.ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '').ToLowerInvariant()
        } finally { $hasher.Dispose() }
        "$path $hash"
    }
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($hasher.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes(($lines -join [string][char]10)))).Replace('-', '').ToLowerInvariant()
    } finally { $hasher.Dispose() }
}

try {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } finally { $listener.Stop() }
    $env:POSTGRES_PASSWORD = $null
    $env:API_PORT = $null
    [System.IO.File]::WriteAllText($envFile,
        "POSTGRES_PASSWORD=$password" + [Environment]::NewLine + "API_PORT=$Port" + [Environment]::NewLine)

    $config = ((Invoke-Compose -CommandArguments @('config', '--format', 'json')) -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-Check ($config.services.api.ports.Count -eq 1) 'Unexpected API port configuration.'
    Assert-Check ($config.services.api.ports[0].host_ip -eq '127.0.0.1') 'API must bind to loopback.'
    Assert-Check (-not $config.services.db.ports) 'Database ports must not be published.'
    $fingerprint = Get-SourceFingerprint
    Push-Location $repo
    try {
        $baseCommit = (& git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Unable to identify the repository version.' }
        $workingTreeClean = -not (& git status --porcelain)
    } finally { Pop-Location }
    $started = $true
    Invoke-Compose -CommandArguments @('up', '--build', '-d', '--wait', '--wait-timeout', '120')
    Record-Case 'first-start' (Wait-Ready)

    $apiId = ((Invoke-Compose -CommandArguments @('ps', '-q', 'api')) -join '').Trim()
    $inspection = ((& docker inspect $apiId) -join [Environment]::NewLine) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the API container.' }
    $binding = $inspection[0].HostConfig.PortBindings.'8080/tcp'[0]
    Assert-Check ($binding.HostIp -eq '127.0.0.1' -and [int]$binding.HostPort -eq $Port) 'Unexpected actual API binding.'
    $dbId = ((Invoke-Compose -CommandArguments @('ps', '-q', 'db')) -join '').Trim()
    $dbInspection = ((& docker inspect $dbId) -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-Check (-not $dbInspection[0].HostConfig.PortBindings.'5432/tcp') 'Database has a published port.'
    Record-Case 'port-bindings' "127.0.0.1:$Port; no database host port"

    $unknown = $client.GetAsync("http://127.0.0.1:$Port/rooms").GetAwaiter().GetResult()
    try { Assert-Check ([int]$unknown.StatusCode -eq 404) 'Unexpected subject endpoint.' } finally { $unknown.Dispose() }
    Record-Case 'unimplemented-route' '404 (not an authorization test)'

    Invoke-Compose -CommandArguments @('exec', '-T', 'db', 'psql', '-U', 'wisedubs', '-d', 'wisedubs',
        '-v', 'ON_ERROR_STOP=1', '-c', 'CREATE TABLE ek1_verification_marker (value integer PRIMARY KEY); INSERT INTO ek1_verification_marker VALUES (1);')
    Invoke-Compose -CommandArguments @('stop', 'db')
    $failure = Request-Health
    Assert-Check ($failure.Code -eq 503 -and $failure.Body -ceq '{"status":"unavailable"}') 'Database stop must produce the fixed 503 response.'
    Assert-Check ($failure.Seconds -lt 3.5) 'Database failure exceeded the deadline with transport tolerance.'
    Record-Case 'database-stop' $failure
    Invoke-Compose -CommandArguments @('start', 'db')
    Record-Case 'database-recovery' (Wait-Ready)

    $dbPaused = $true
    Invoke-Compose -CommandArguments @('pause', 'db')
    try {
        $timeout = Request-Health
        Assert-Check ($timeout.Code -eq 503 -and $timeout.Body -ceq '{"status":"unavailable"}') 'Unresponsive database must produce 503.'
        Assert-Check ($timeout.Seconds -lt 3.5) 'Unresponsive database exceeded the deadline with transport tolerance.'
        Record-Case 'database-timeout' $timeout
    } finally {
        Invoke-Compose -CommandArguments @('unpause', 'db')
        $dbPaused = $false
    }
    Record-Case 'timeout-recovery' (Wait-Ready)

    $logsBeforeRestart = (Invoke-Compose -CommandArguments @('logs', '--no-color', 'api')) -join [Environment]::NewLine
    Invoke-Compose -CommandArguments @('down')
    Invoke-Compose -CommandArguments @('up', '-d', '--no-build', '--pull', 'never', '--wait', '--wait-timeout', '120')
    Record-Case 'restart-without-download' (Wait-Ready)
    $marker = ((Invoke-Compose -CommandArguments @('exec', '-T', 'db', 'psql', '-U', 'wisedubs',
        '-d', 'wisedubs', '-v', 'ON_ERROR_STOP=1', '-tAc', 'SELECT value FROM ek1_verification_marker')) -join '').Trim()
    Assert-Check ($marker -eq '1') 'Database marker did not survive recreation.'
    Record-Case 'persistent-volume' 'technical marker preserved'

    $logs = $logsBeforeRestart + [Environment]::NewLine + ((Invoke-Compose -CommandArguments @('logs', '--no-color', 'api')) -join [Environment]::NewLine)
    Assert-Check (-not $logs.Contains($password) -and -not $logs.Contains($probeToken)) 'Secrets or client input appeared in API logs.'
    Assert-Check ($logs -notmatch 'SELECT\s+1|NpgsqlException|StackTrace|Password=') 'Internal diagnostics appeared in API logs.'
    Record-Case 'safe-api-logs' 'no password, probe token, SQL or exception text'
    $dbVersion = ((Invoke-Compose -CommandArguments @('exec', '-T', 'db', 'postgres', '--version')) -join '').Trim()
    $report = [pscustomobject]@{
        VerifiedAtUtc = [DateTime]::UtcNow.ToString('o')
        BaseCommit = $baseCommit
        WorkingTreeClean = $workingTreeClean
        SourceFingerprint = $fingerprint
        ApiImageId = $inspection[0].Image
        DatabaseVersion = $dbVersion
        Project = $project
        Port = $Port
        VolumePreserved = ($project + '_db-data')
        ExternalComputerTested = $false
        Cases = $cases.ToArray()
    }
    $json = $report | ConvertTo-Json -Depth 6
    if ($ReportPath) {
        [System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ReportPath), $json, [System.Text.UTF8Encoding]::new($false))
    }
    $json
} finally {
    if ($dbPaused) { & docker @script:ComposeArgs unpause db | Out-Null }
    if ($started) {
        & docker @script:ComposeArgs down | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "Cleanup failed for $project; run compose down for this project." }
    }
    $client.Dispose()
    $env:POSTGRES_PASSWORD = $oldPassword
    $env:API_PORT = $oldPort
    Remove-Item -LiteralPath $envFile -ErrorAction SilentlyContinue
}
