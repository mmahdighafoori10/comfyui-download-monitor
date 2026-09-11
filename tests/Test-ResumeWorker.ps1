$ErrorActionPreference = 'Stop'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ComfyResumeTest-' + [guid]::NewGuid().ToString('N'))
$expectedPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\ComfyResumeTest-'
$resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
if (-not $resolvedTestRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe test directory.'
}

$workspace = Join-Path $resolvedTestRoot 'ComfyUI'
$stateDirectory = Join-Path $workspace '.comfy-downloads'
$modelDirectory = Join-Path $workspace 'models\checkpoints'
$sourcePath = Join-Path $resolvedTestRoot 'source.bin'
$destinationPath = Join-Path $modelDirectory 'model.bin'
$partialPath = $destinationPath + '.a1b2c3d4.part'
$rangeLogPath = Join-Path $resolvedTestRoot 'range.log'
$serverOutputPath = Join-Path $resolvedTestRoot 'server.out.log'
$serverErrorPath = Join-Path $resolvedTestRoot 'server.err.log'
$statePath = Join-Path $stateDirectory 'a1b2c3d4e5f6.json'
$serverProcess = $null

try {
    New-Item -ItemType Directory -Path $stateDirectory, $modelDirectory -Force | Out-Null

    $sourceBytes = [byte[]]::new(4MB)
    for ($index = 0; $index -lt $sourceBytes.Length; $index++) {
        $sourceBytes[$index] = [byte](($index * 31 + 17) % 251)
    }
    [System.IO.File]::WriteAllBytes($sourcePath, $sourceBytes)

    $partialBytes = [byte[]]::new(1MB)
    [System.Array]::Copy($sourceBytes, $partialBytes, $partialBytes.Length)
    [System.IO.File]::WriteAllBytes($partialPath, $partialBytes)

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()

    $serverScript = Join-Path $PSScriptRoot 'range_server.py'
    $serverArguments = "`"$serverScript`" --port $port --source `"$sourcePath`" --log `"$rangeLogPath`""
    $serverProcess = Start-Process -FilePath 'python.exe' -ArgumentList $serverArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $serverOutputPath -RedirectStandardError $serverErrorPath

    $serverReady = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect('127.0.0.1', $port)
            $client.Dispose()
            $serverReady = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $serverReady) {
        throw 'Range test server did not start.'
    }

    $state = [ordered]@{
        id = 'a1b2c3d4e5f6'
        url = "http://127.0.0.1:$port/model.bin"
        dest = $destinationPath
        schema = 'download-state/1'
        pid = 999999
        pid_create_time = 1.0
        total_bytes = $sourceBytes.Length
        completed_bytes = $partialBytes.Length
        status = 'failed'
        error = 'simulated restart'
        started_at = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
        updated_at = [datetime]::UtcNow.ToString('o')
        downloader = 'httpx'
        kind = 'background'
        needs_civitai_auth = $false
        needs_hf_auth = $false
    }
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8

    $workerPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ComfyResumeWorker.ps1'
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $workerPath -StateFilePath $statePath -ForceRetry
    if ($LASTEXITCODE -ne 0) {
        throw "Resume worker exited with code $LASTEXITCODE."
    }

    $finalState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($finalState.status -ne 'completed') {
        throw "Unexpected final status: $($finalState.status)"
    }
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
        throw 'Final destination was not created.'
    }

    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePath).Hash
    $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destinationPath).Hash
    if ($sourceHash -ne $destinationHash) {
        throw 'Resumed file hash does not match the source.'
    }

    $rangeHeaders = @(Get-Content -LiteralPath $rangeLogPath)
    if ($rangeHeaders -notcontains 'bytes=1048576-') {
        throw 'Expected HTTP Range header was not observed.'
    }

    [pscustomobject]@{
        Passed = $true
        ResumedFromBytes = $partialBytes.Length
        FinalBytes = (Get-Item -LiteralPath $destinationPath).Length
        Sha256 = $destinationHash
        RangeHeader = 'bytes=1048576-'
    }
}
finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
        $serverProcess.WaitForExit()
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
