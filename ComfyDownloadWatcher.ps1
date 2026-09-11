param(
    [switch]$SelfTest,
    [ValidateRange(1, 30)]
    [int]$PollIntervalSeconds = 1,
    [string]$DownloadStateDirectory
)

$ErrorActionPreference = 'Stop'

$defaultDownloadStateDirectory = Join-Path (
    [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
) 'Comfy-Desktop\ComfyUI-Installs\Flint Studio\ComfyUI\.comfy-downloads'
$downloadStateDirectory = if ([string]::IsNullOrWhiteSpace($DownloadStateDirectory)) {
    $defaultDownloadStateDirectory
}
else {
    [System.IO.Path]::GetFullPath($DownloadStateDirectory)
}
$monitorScriptPath = Join-Path $PSScriptRoot 'ComfyDownloadMonitor.ps1'
$resumeWorkerScriptPath = Join-Path $PSScriptRoot 'ComfyResumeWorker.ps1'
$watcherLogPath = Join-Path $PSScriptRoot 'watcher.log'

function Read-DownloadState {
    param([System.IO.FileInfo]$File)

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $state = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $state | Add-Member -NotePropertyName '_state_file' -NotePropertyValue $File.FullName -Force
            return $state
        }
        catch {
            Start-Sleep -Milliseconds 40
        }
    }

    return $null
}

function Test-LiveDownloadProcess {
    param($State)

    if ([string]$State.status -notin @('starting', 'downloading')) {
        return $false
    }

    $processId = if ($null -eq $State.pid) { 0 } else { [int]$State.pid }
    $expectedCreateTime = if ($null -eq $State.pid_create_time) { 0.0 } else { [double]$State.pid_create_time }
    if ($processId -le 0 -or $expectedCreateTime -le 0) {
        return $false
    }

    $process = $null
    try {
        $process = Get-Process -Id $processId -ErrorAction Stop
        $actualCreateTime = ([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000.0
        $isExpectedProcess = $process.ProcessName -match '^python(w)?$' -or
            ([string]$State.managed_by -eq 'ComfyUI Download Monitor' -and $process.ProcessName -eq 'powershell')
        return $isExpectedProcess -and
            [math]::Abs($actualCreateTime - $expectedCreateTime) -le 2.5
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Get-DownloadStates {
    if (-not (Test-Path -LiteralPath $downloadStateDirectory)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $downloadStateDirectory -Filter '*.json' -File |
            ForEach-Object { Read-DownloadState -File $_ } |
            Where-Object { $null -ne $_ }
    )
}

function Test-RecentlyStartingDownload {
    param($State)

    if ([string]$State.status -ne 'starting' -or $null -ne $State.pid) {
        return $false
    }

    try {
        return ([datetime]::UtcNow - ([datetime]$State.updated_at).ToUniversalTime()).TotalSeconds -lt 60
    }
    catch {
        return $false
    }
}

function Test-ObservableActiveDownload {
    param($State)

    return [string]$State.status -in @('starting', 'downloading') -and
        ((Test-LiveDownloadProcess -State $State) -or (Test-RecentlyStartingDownload -State $State))
}

function Test-DownloadNeedsRecovery {
    param($State)

    if ([string]$State.status -notin @('starting', 'downloading')) {
        return $false
    }
    if (Test-LiveDownloadProcess -State $State) {
        return $false
    }
    if (Test-RecentlyStartingDownload -State $State) {
        return $false
    }

    $downloadId = [string]$State.id
    if ($downloadId -notmatch '^[A-Za-z0-9_-]{1,100}$' -or
        [string]::IsNullOrWhiteSpace([string]$State.url) -or
        [string]::IsNullOrWhiteSpace([string]$State.dest) -or
        [string]::IsNullOrWhiteSpace([string]$State._state_file)) {
        return $false
    }

    $cancelMarker = Join-Path $downloadStateDirectory ($downloadId + '.cancel')
    return -not (Test-Path -LiteralPath $cancelMarker -PathType Leaf)
}

function Start-DownloadRecovery {
    param($State)

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$resumeWorkerScriptPath`" -StateFilePath `"$($State._state_file)`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Start-MonitorWindow {
    $arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorScriptPath`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

if ($SelfTest) {
    $downloadStates = @(Get-DownloadStates)
    $liveDownloads = @($downloadStates | Where-Object { Test-LiveDownloadProcess -State $_ })
    $recoverableDownloads = @($downloadStates | Where-Object { Test-DownloadNeedsRecovery -State $_ })
    [pscustomobject]@{
        MonitorExists     = Test-Path -LiteralPath $monitorScriptPath -PathType Leaf
        ResumeWorkerExists = Test-Path -LiteralPath $resumeWorkerScriptPath -PathType Leaf
        StateFolderExists = Test-Path -LiteralPath $downloadStateDirectory -PathType Container
        ActiveCount       = $liveDownloads.Count
        ActiveIds         = @($liveDownloads | ForEach-Object { [string]$_.id })
        RecoverableCount  = $recoverableDownloads.Count
        PollInterval      = $PollIntervalSeconds
        UsesAi            = $false
    } | ConvertTo-Json -Depth 3
    exit 0
}

$watcherMutex = [System.Threading.Mutex]::new($false, 'Local\ComfyUIDownloadWatcherV2')
$ownsMutex = $false
try {
    try {
        $ownsMutex = $watcherMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }

    if (-not $ownsMutex) {
        exit 0
    }

    $previousActiveIds = @{}
    while ($true) {
        try {
            $downloadStates = @(Get-DownloadStates)
            foreach ($download in $downloadStates) {
                if (Test-DownloadNeedsRecovery -State $download) {
                    Start-DownloadRecovery -State $download
                }
            }

            $activeDownloads = @(
                $downloadStates |
                    Where-Object {
                        (Test-ObservableActiveDownload -State $_) -or
                        (Test-DownloadNeedsRecovery -State $_)
                    }
            )
            $currentActiveIds = @{}
            foreach ($download in $activeDownloads) {
                $downloadId = [string]$download.id
                if (-not [string]::IsNullOrWhiteSpace($downloadId)) {
                    $currentActiveIds[$downloadId] = $true
                }
            }

            $newActiveIds = @($currentActiveIds.Keys | Where-Object { -not $previousActiveIds.ContainsKey($_) })
            if ($newActiveIds.Count -gt 0) {
                Start-MonitorWindow
            }

            $previousActiveIds = $currentActiveIds
        }
        catch {
            $logLine = '{0:u} {1}' -f [datetime]::Now, $_.Exception.Message
            Add-Content -LiteralPath $watcherLogPath -Value $logLine -Encoding UTF8
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
finally {
    if ($ownsMutex) {
        try {
            $watcherMutex.ReleaseMutex()
        }
        catch {
        }
    }
    $watcherMutex.Dispose()
}
