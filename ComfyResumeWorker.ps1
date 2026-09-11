param(
    [Parameter(Mandatory = $true)]
    [string]$StateFilePath,
    [switch]$ForceRetry,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$maximumAttempts = 8
$progressWriteIntervalSeconds = 1
$bufferSizeBytes = 1MB

function Set-StateProperty {
    param(
        $State,
        [string]$Name,
        $Value
    )

    if ($State.PSObject.Properties.Name -contains $Name) {
        $State.$Name = $Value
    }
    else {
        $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Write-DownloadState {
    param($State)

    Set-StateProperty -State $State -Name 'updated_at' -Value ([datetime]::UtcNow.ToString('o'))
    $temporaryPath = $script:resolvedStateFilePath + '.monitor.tmp'
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $script:resolvedStateFilePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ComfyCliToken {
    param(
        [string]$EnvironmentName,
        [string]$ConfigName
    )

    $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
        return $environmentValue.Trim()
    }

    $configPath = Join-Path (
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ) 'comfy-cli\config.ini'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ($line -match ('^\s*' + [regex]::Escape($ConfigName) + '\s*=\s*(.*?)\s*$')) {
            if (-not [string]::IsNullOrWhiteSpace($matches[1])) {
                return $matches[1]
            }
        }
    }

    return $null
}

function Get-PartialCandidates {
    param([string]$DestinationPath)

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($DestinationPath)
    $destinationName = [System.IO.Path]::GetFileName($DestinationPath)
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $destinationDirectory -Filter ($destinationName + '.*.part') -File -ErrorAction SilentlyContinue |
            Where-Object {
                $candidateName = $_.Name
                $tokenStart = $destinationName.Length + 1
                $tokenLength = $candidateName.Length - $tokenStart - '.part'.Length
                if ($tokenLength -ne 8) {
                    return $false
                }
                $token = $candidateName.Substring($tokenStart, $tokenLength)
                return $token -match '^[a-z0-9_]{8}$'
            } |
            Sort-Object -Property Length -Descending
    )
}

function Get-PartialPath {
    param(
        [string]$DestinationPath,
        [string]$DownloadId
    )

    $existing = @(Get-PartialCandidates -DestinationPath $DestinationPath)
    if ($existing.Count -gt 0) {
        return $existing[0].FullName
    }

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($DestinationPath)
    $destinationName = [System.IO.Path]::GetFileName($DestinationPath)
    $token = $DownloadId.Substring(0, [math]::Min(8, $DownloadId.Length)).PadRight(8, '0')
    return Join-Path $destinationDirectory ($destinationName + '.' + $token + '.part')
}

function Remove-DownloadPartials {
    param([string]$DestinationPath)

    foreach ($partial in @(Get-PartialCandidates -DestinationPath $DestinationPath)) {
        Remove-Item -LiteralPath $partial.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Test-CancelRequested {
    return Test-Path -LiteralPath $script:cancelMarkerPath -PathType Leaf
}

function Wait-WithCancellation {
    param([int]$Seconds)

    for ($index = 0; $index -lt $Seconds * 4; $index++) {
        if (Test-CancelRequested) {
            throw [System.OperationCanceledException]::new('Download cancelled by user.')
        }
        Start-Sleep -Milliseconds 250
    }
}

function Get-FriendlyFailure {
    param([System.Exception]$Exception)

    if ($Exception.Message -match 'HTTP\s+\d{3}') {
        return $Exception.Message
    }
    if ($Exception -is [System.Net.Http.HttpRequestException]) {
        return 'ارتباط شبکه قطع شد؛ فایل نیمه‌کاره نگه داشته شد.'
    }
    if ($Exception -is [System.Threading.Tasks.TaskCanceledException]) {
        return 'پاسخی از سرور دریافت نشد؛ فایل نیمه‌کاره نگه داشته شد.'
    }
    return $Exception.Message
}

function Invoke-ResumableTransfer {
    param($State)

    Add-Type -AssemblyName System.Net.Http
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $partialPath = Get-PartialPath -DestinationPath $script:destinationPath -DownloadId ([string]$State.id)
    $clientHandler = [System.Net.Http.HttpClientHandler]::new()
    $clientHandler.AllowAutoRedirect = $true
    $client = [System.Net.Http.HttpClient]::new($clientHandler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('ComfyUI-Download-Monitor/1.0')

    try {
        for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
            if (Test-CancelRequested) {
                throw [System.OperationCanceledException]::new('Download cancelled by user.')
            }

            $offset = if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
                [long](Get-Item -LiteralPath $partialPath).Length
            }
            else {
                0L
            }

            $request = [System.Net.Http.HttpRequestMessage]::new(
                [System.Net.Http.HttpMethod]::Get,
                [uri]$State.url
            )
            $response = $null
            $networkStream = $null
            $fileStream = $null

            try {
                if ($offset -gt 0) {
                    $request.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($offset, $null)
                }

                $hostName = ([uri]$State.url).DnsSafeHost.ToLowerInvariant()
                if ([bool]$State.needs_civitai_auth -and ($hostName -eq 'civitai.com' -or $hostName.EndsWith('.civitai.com'))) {
                    $token = Get-ComfyCliToken -EnvironmentName 'CIVITAI_API_TOKEN' -ConfigName 'civitai_api_token'
                    if (-not [string]::IsNullOrWhiteSpace($token)) {
                        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
                    }
                }
                elseif ([bool]$State.needs_hf_auth -and ($hostName -eq 'huggingface.co' -or $hostName.EndsWith('.huggingface.co'))) {
                    $token = Get-ComfyCliToken -EnvironmentName 'HF_API_TOKEN' -ConfigName 'hf_api_token'
                    if (-not [string]::IsNullOrWhiteSpace($token)) {
                        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
                    }
                }

                $response = $client.SendAsync(
                    $request,
                    [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
                ).GetAwaiter().GetResult()

                if ([int]$response.StatusCode -eq 416 -and $offset -gt 0) {
                    $knownLength = $response.Content.Headers.ContentRange.Length
                    if ($null -ne $knownLength -and $offset -ge [long]$knownLength) {
                        Move-Item -LiteralPath $partialPath -Destination $script:destinationPath -Force
                        return [long]$knownLength
                    }
                    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
                    throw [System.Net.Http.HttpRequestException]::new('Server rejected the saved byte range; restarting safely.')
                }

                if (-not $response.IsSuccessStatusCode) {
                    $statusCode = [int]$response.StatusCode
                    throw [System.Net.Http.HttpRequestException]::new("سرور دانلود خطای HTTP $statusCode برگرداند.")
                }

                $acceptedRange = [int]$response.StatusCode -eq 206
                if ($offset -gt 0 -and -not $acceptedRange) {
                    $offset = 0L
                }

                $contentLength = $response.Content.Headers.ContentLength
                $totalBytes = if ($null -ne $response.Content.Headers.ContentRange -and $null -ne $response.Content.Headers.ContentRange.Length) {
                    [long]$response.Content.Headers.ContentRange.Length
                }
                elseif ($null -ne $contentLength) {
                    if ($acceptedRange) { $offset + [long]$contentLength } else { [long]$contentLength }
                }
                else {
                    $null
                }

                Set-StateProperty -State $State -Name 'status' -Value 'downloading'
                Set-StateProperty -State $State -Name 'error' -Value $null
                Set-StateProperty -State $State -Name 'completed_bytes' -Value $offset
                Set-StateProperty -State $State -Name 'total_bytes' -Value $totalBytes
                Set-StateProperty -State $State -Name 'resume_available' -Value $true
                Write-DownloadState -State $State

                $fileMode = if ($acceptedRange -and $offset -gt 0) {
                    [System.IO.FileMode]::Append
                }
                else {
                    [System.IO.FileMode]::Create
                }

                $networkStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $fileStream = [System.IO.FileStream]::new(
                    $partialPath,
                    $fileMode,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::Read,
                    $bufferSizeBytes,
                    [System.IO.FileOptions]::SequentialScan
                )

                $buffer = [byte[]]::new($bufferSizeBytes)
                $completedBytes = $offset
                $lastProgressWrite = [datetime]::UtcNow
                while (($bytesRead = $networkStream.ReadAsync($buffer, 0, $buffer.Length).GetAwaiter().GetResult()) -gt 0) {
                    if (Test-CancelRequested) {
                        throw [System.OperationCanceledException]::new('Download cancelled by user.')
                    }

                    $fileStream.Write($buffer, 0, $bytesRead)
                    $completedBytes += $bytesRead
                    if (([datetime]::UtcNow - $lastProgressWrite).TotalSeconds -ge $progressWriteIntervalSeconds) {
                        $fileStream.Flush()
                        Set-StateProperty -State $State -Name 'completed_bytes' -Value $completedBytes
                        Write-DownloadState -State $State
                        $lastProgressWrite = [datetime]::UtcNow
                    }
                }

                $fileStream.Flush($true)
                $fileStream.Dispose()
                $fileStream = $null

                if ($null -ne $totalBytes -and $completedBytes -lt [long]$totalBytes) {
                    throw [System.IO.EndOfStreamException]::new(
                        "دانلود زودتر از مقدار اعلام‌شده پایان یافت ($completedBytes از $totalBytes بایت)."
                    )
                }

                Move-Item -LiteralPath $partialPath -Destination $script:destinationPath -Force
                Remove-DownloadPartials -DestinationPath $script:destinationPath
                return $completedBytes
            }
            catch [System.OperationCanceledException] {
                throw
            }
            catch {
                $failureText = Get-FriendlyFailure -Exception $_.Exception
                $partialBytes = if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
                    [long](Get-Item -LiteralPath $partialPath).Length
                }
                else {
                    0L
                }

                Set-StateProperty -State $State -Name 'completed_bytes' -Value $partialBytes
                Set-StateProperty -State $State -Name 'error' -Value $failureText
                Set-StateProperty -State $State -Name 'resume_available' -Value $true

                $statusCodeMatch = [regex]::Match($_.Exception.Message, 'HTTP\s+(\d{3})')
                $isPermanentHttpFailure = $statusCodeMatch.Success -and [int]$statusCodeMatch.Groups[1].Value -in @(400, 401, 403, 404, 405, 410, 451)
                if ($attempt -ge $maximumAttempts -or $isPermanentHttpFailure) {
                    Set-StateProperty -State $State -Name 'status' -Value 'failed'
                    Write-DownloadState -State $State
                    throw
                }

                Set-StateProperty -State $State -Name 'status' -Value 'starting'
                Write-DownloadState -State $State
                Wait-WithCancellation -Seconds ([math]::Min(60, [math]::Pow(2, $attempt)))
            }
            finally {
                if ($null -ne $fileStream) {
                    $fileStream.Dispose()
                }
                if ($null -ne $networkStream) {
                    $networkStream.Dispose()
                }
                if ($null -ne $response) {
                    $response.Dispose()
                }
                $request.Dispose()
            }
        }
    }
    finally {
        $client.Dispose()
        $clientHandler.Dispose()
    }
}

$script:resolvedStateFilePath = [System.IO.Path]::GetFullPath($StateFilePath)
if (-not (Test-Path -LiteralPath $script:resolvedStateFilePath -PathType Leaf)) {
    throw 'فایل وضعیت دانلود پیدا نشد.'
}

$stateDirectory = [System.IO.Path]::GetDirectoryName($script:resolvedStateFilePath)
if ([System.IO.Path]::GetFileName($stateDirectory) -ne '.comfy-downloads') {
    throw 'فایل وضعیت خارج از پوشه مجاز است.'
}

$state = Get-Content -LiteralPath $script:resolvedStateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
$downloadId = [string]$state.id
if ($downloadId -notmatch '^[A-Za-z0-9_-]{1,100}$') {
    throw 'شناسه دانلود معتبر نیست.'
}
if ([System.IO.Path]::GetFileNameWithoutExtension($script:resolvedStateFilePath) -ne $downloadId) {
    throw 'شناسه دانلود با فایل وضعیت یکسان نیست.'
}

$downloadUri = $null
if (-not [uri]::TryCreate([string]$state.url, [System.UriKind]::Absolute, [ref]$downloadUri) -or
    $downloadUri.Scheme -notin @('http', 'https')) {
    throw 'نشانی دانلود معتبر نیست.'
}

$workspaceRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetDirectoryName($stateDirectory))
$workspacePrefix = $workspaceRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$script:destinationPath = [System.IO.Path]::GetFullPath([string]$state.dest)
if (-not $script:destinationPath.StartsWith($workspacePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'مسیر مقصد خارج از پوشه ComfyUI است.'
}

$script:cancelMarkerPath = Join-Path $stateDirectory ($downloadId + '.cancel')
if ($ForceRetry -and (Test-Path -LiteralPath $script:cancelMarkerPath)) {
    Remove-Item -LiteralPath $script:cancelMarkerPath -Force
}

if ($SelfTest) {
    [pscustomobject]@{
        StateFileValid = $true
        DownloadId = $downloadId
        DestinationInsideWorkspace = $true
        PartialCount = @(Get-PartialCandidates -DestinationPath $script:destinationPath).Count
        UsesResumableRanges = $true
    } | ConvertTo-Json -Depth 3
    exit 0
}

$resumeMutex = [System.Threading.Mutex]::new($false, ('Local\ComfyUIResume_' + $downloadId))
$ownsMutex = $false
try {
    try {
        $ownsMutex = $resumeMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        exit 0
    }

    if (Test-CancelRequested) {
        Remove-DownloadPartials -DestinationPath $script:destinationPath
        Set-StateProperty -State $state -Name 'status' -Value 'cancelled'
        Set-StateProperty -State $state -Name 'completed_bytes' -Value 0L
        Set-StateProperty -State $state -Name 'error' -Value $null
        Set-StateProperty -State $state -Name 'resume_available' -Value $false
        Write-DownloadState -State $state
        exit 0
    }

    $currentProcess = Get-Process -Id $PID
    $processCreateTime = ([DateTimeOffset]$currentProcess.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000.0
    Set-StateProperty -State $state -Name 'pid' -Value $PID
    Set-StateProperty -State $state -Name 'pid_create_time' -Value $processCreateTime
    Set-StateProperty -State $state -Name 'kind' -Value 'background'
    Set-StateProperty -State $state -Name 'managed_by' -Value 'ComfyUI Download Monitor'
    Set-StateProperty -State $state -Name 'status' -Value 'starting'
    Set-StateProperty -State $state -Name 'error' -Value $null
    Set-StateProperty -State $state -Name 'resume_available' -Value $true
    Write-DownloadState -State $state

    try {
        $completedBytes = Invoke-ResumableTransfer -State $state
        Set-StateProperty -State $state -Name 'completed_bytes' -Value $completedBytes
        Set-StateProperty -State $state -Name 'total_bytes' -Value $completedBytes
        Set-StateProperty -State $state -Name 'status' -Value 'completed'
        Set-StateProperty -State $state -Name 'error' -Value $null
        Set-StateProperty -State $state -Name 'resume_available' -Value $false
        Write-DownloadState -State $state
    }
    catch [System.OperationCanceledException] {
        Remove-DownloadPartials -DestinationPath $script:destinationPath
        Set-StateProperty -State $state -Name 'completed_bytes' -Value 0L
        Set-StateProperty -State $state -Name 'status' -Value 'cancelled'
        Set-StateProperty -State $state -Name 'error' -Value $null
        Set-StateProperty -State $state -Name 'resume_available' -Value $false
        Write-DownloadState -State $state
    }
    catch {
        if ([string]$state.status -ne 'failed') {
            Set-StateProperty -State $state -Name 'status' -Value 'failed'
            Set-StateProperty -State $state -Name 'error' -Value (Get-FriendlyFailure -Exception $_.Exception)
            Set-StateProperty -State $state -Name 'resume_available' -Value $true
            Write-DownloadState -State $state
        }
        exit 1
    }
}
finally {
    if ($ownsMutex) {
        try {
            $resumeMutex.ReleaseMutex()
        }
        catch {
        }
    }
    $resumeMutex.Dispose()
}
