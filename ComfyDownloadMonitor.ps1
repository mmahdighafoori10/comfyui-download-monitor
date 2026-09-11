param(
    [switch]$SelfTest,
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
$refreshIntervalSeconds = 1
$monitorPauseStatePath = Join-Path $PSScriptRoot '.comfy-monitor-paused.json'
$resumeWorkerScriptPath = Join-Path $PSScriptRoot 'ComfyResumeWorker.ps1'
$script:downloadSamples = @{}
$script:pausedDownloads = @{}
$script:lastSnapshot = $null

function Get-FriendlyModelName {
    param([string]$Destination)

    $fileName = [System.IO.Path]::GetFileName($Destination)
    $knownNames = @{
        'qwen_image_edit_2509_fp8_e4m3fn.safetensors' = 'Qwen Image Edit — مدل اصلی'
        'qwen_2.5_vl_7b_fp8_scaled.safetensors'       = 'Qwen 2.5 VL — متن‌خوان تصویر'
        't5xxl_fp16.safetensors'                      = 'T5 XXL — متن‌خوان Flux'
        'clip_l.safetensors'                          = 'CLIP-L — متن‌خوان Flux'
        'ae.safetensors'                              = 'Flux VAE'
        '4x_NMKD-Siax_200k.pth'                       = 'NMKD Upscaler'
        'fluxmania_kreamania.safetensors'             = 'Fluxmania Kreamania'
    }

    if ($knownNames.ContainsKey($fileName)) {
        return $knownNames[$fileName]
    }

    return $fileName
}

function Format-ByteSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return ('{0:N2} GB' -f ($Bytes / 1GB))
    }
    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }
    if ($Bytes -ge 1KB) {
        return ('{0:N1} KB' -f ($Bytes / 1KB))
    }
    return "$Bytes B"
}

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -le 0 -or [double]::IsInfinity($Seconds) -or [double]::IsNaN($Seconds)) {
        return '—'
    }

    $duration = [TimeSpan]::FromSeconds($Seconds)
    if ($duration.TotalHours -ge 1) {
        return ('{0} ساعت و {1} دقیقه' -f [math]::Floor($duration.TotalHours), $duration.Minutes)
    }
    if ($duration.TotalMinutes -ge 1) {
        return ('{0} دقیقه' -f [math]::Ceiling($duration.TotalMinutes))
    }
    return ('{0} ثانیه' -f [math]::Ceiling($duration.TotalSeconds))
}

function Read-DownloadStateFile {
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

function Test-SafeDownloadId {
    param([string]$DownloadId)

    return -not [string]::IsNullOrWhiteSpace($DownloadId) -and $DownloadId -match '^[A-Za-z0-9_-]{1,100}$'
}

function Get-PartialDownloadBytes {
    param([string]$Destination)

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        return 0L
    }

    $destinationDirectory = [System.IO.Path]::GetDirectoryName($Destination)
    $destinationName = [System.IO.Path]::GetFileName($Destination)
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        return 0L
    }

    $largestPartial = Get-ChildItem -LiteralPath $destinationDirectory -Filter ($destinationName + '.*.part') -File -ErrorAction SilentlyContinue |
        Where-Object {
            $tokenStart = $destinationName.Length + 1
            $tokenLength = $_.Name.Length - $tokenStart - '.part'.Length
            if ($tokenLength -ne 8) {
                return $false
            }
            $_.Name.Substring($tokenStart, $tokenLength) -match '^[a-z0-9_]{8}$'
        } |
        Sort-Object -Property Length -Descending |
        Select-Object -First 1

    if ($null -eq $largestPartial) {
        return 0L
    }
    return [long]$largestPartial.Length
}

function Save-PausedDownloadState {
    try {
        $records = @($script:pausedDownloads.Values)
        if ($records.Count -eq 0) {
            if (Test-Path -LiteralPath $monitorPauseStatePath) {
                Remove-Item -LiteralPath $monitorPauseStatePath -Force
            }
            return
        }

        $records | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $monitorPauseStatePath -Encoding UTF8
    }
    catch {
        # A persistence failure must not interrupt the live download monitor.
    }
}

function Load-PausedDownloadState {
    if (-not (Test-Path -LiteralPath $monitorPauseStatePath)) {
        return
    }

    try {
        $records = @(Get-Content -LiteralPath $monitorPauseStatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
        foreach ($record in $records) {
            $downloadId = [string]$record.DownloadId
            if (Test-SafeDownloadId -DownloadId $downloadId) {
                $script:pausedDownloads[$downloadId] = [pscustomobject]@{
                    DownloadId       = $downloadId
                    ProcessId        = [int]$record.ProcessId
                    ProcessCreateTime = [double]$record.ProcessCreateTime
                }
            }
        }
    }
    catch {
        $script:pausedDownloads = @{}
    }
}

Load-PausedDownloadState

function Get-LatestDownloadStates {
    if (-not (Test-Path -LiteralPath $downloadStateDirectory)) {
        return @()
    }

    $allStates = @(
        Get-ChildItem -LiteralPath $downloadStateDirectory -Filter '*.json' -File |
            ForEach-Object { Read-DownloadStateFile -File $_ } |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.dest) }
    )

    $latestStates = foreach ($destinationGroup in ($allStates | Group-Object -Property dest)) {
        $destinationGroup.Group |
            Sort-Object -Property @{ Expression = { [datetime]$_.updated_at }; Descending = $true } |
            Select-Object -First 1
    }

    return @($latestStates)
}

function Get-StatusPresentation {
    param([string]$Status)

    switch ($Status) {
        'starting'    { return @{ Text = 'در حال شروع'; Brush = '#F59E0B'; Priority = 1 } }
        'downloading' { return @{ Text = 'در حال دانلود'; Brush = '#60A5FA'; Priority = 0 } }
        'completed'   { return @{ Text = 'کامل شده'; Brush = '#34D399'; Priority = 3 } }
        'failed'      { return @{ Text = 'خطا'; Brush = '#FB7185'; Priority = 2 } }
        'cancelled'   { return @{ Text = 'متوقف شده'; Brush = '#F59E0B'; Priority = 2 } }
        default       { return @{ Text = 'نامشخص'; Brush = '#94A3B8'; Priority = 2 } }
    }
}

function Get-SpeedPresentation {
    param(
        $State,
        [long]$CompletedBytes
    )

    $now = [datetime]::UtcNow
    $sampleKey = [string]$State.id
    $previousSample = $script:downloadSamples[$sampleKey]
    $speedBytesPerSecond = 0.0

    if ($null -ne $previousSample) {
        $elapsedSeconds = ($now - $previousSample.Time).TotalSeconds
        if ($elapsedSeconds -gt 0) {
            $instantSpeed = ($CompletedBytes - $previousSample.Bytes) / $elapsedSeconds
            if ($instantSpeed -gt 0) {
                $priorSpeed = [double]$previousSample.Speed
                $speedBytesPerSecond = if ($priorSpeed -gt 0) {
                    ($priorSpeed * 0.65) + ($instantSpeed * 0.35)
                }
                else {
                    $instantSpeed
                }
            }
        }
    }

    $script:downloadSamples[$sampleKey] = @{
        Time  = $now
        Bytes = $CompletedBytes
        Speed = $speedBytesPerSecond
    }

    if ($speedBytesPerSecond -le 0 -or $State.status -ne 'downloading') {
        return 'سرعت: در حال اندازه‌گیری'
    }

    $speedText = Format-ByteSize -Bytes ([long]$speedBytesPerSecond)
    $etaText = '—'
    if ($null -ne $State.total_bytes -and [long]$State.total_bytes -gt $CompletedBytes) {
        $etaText = Format-Duration -Seconds (([long]$State.total_bytes - $CompletedBytes) / $speedBytesPerSecond)
    }

    return "سرعت: $speedText/s  •  زمان باقی‌مانده: $etaText"
}

function ConvertTo-DownloadViewModel {
    param($State)

    $statusPresentation = Get-StatusPresentation -Status ([string]$State.status)
    $stateCompletedBytes = if ($null -eq $State.completed_bytes) { 0L } else { [long]$State.completed_bytes }
    $partialBytes = Get-PartialDownloadBytes -Destination ([string]$State.dest)
    $completedBytes = [math]::Max($stateCompletedBytes, $partialBytes)
    $totalBytes = if ($null -eq $State.total_bytes) { 0L } else { [long]$State.total_bytes }
    $percent = if ($totalBytes -gt 0) {
        [math]::Min(100, [math]::Round(($completedBytes / $totalBytes) * 100, 2))
    }
    else {
        0
    }

    $transferText = if ($totalBytes -gt 0) {
        '{0} از {1}' -f (Format-ByteSize -Bytes $completedBytes), (Format-ByteSize -Bytes $totalBytes)
    }
    else {
        Format-ByteSize -Bytes $completedBytes
    }

    $cleanError = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$State.error)) {
        $cleanError = ([string]$State.error -replace '\s+', ' ').Trim()
        if ($cleanError.Length -gt 220) {
            $cleanError = $cleanError.Substring(0, 217) + '...'
        }
    }

    $downloadId = [string]$State.id
    $isActive = [string]$State.status -in @('starting', 'downloading')
    $isPaused = $isActive -and $script:pausedDownloads.ContainsKey($downloadId)
    if ($isPaused) {
        $statusPresentation = @{ Text = 'مکث شده'; Brush = '#FBBF24'; Priority = 0 }
    }

    [pscustomobject]@{
        DownloadId      = $downloadId
        ProcessId       = if ($null -eq $State.pid) { 0 } else { [int]$State.pid }
        ProcessCreateTime = if ($null -eq $State.pid_create_time) { 0.0 } else { [double]$State.pid_create_time }
        FriendlyName    = Get-FriendlyModelName -Destination ([string]$State.dest)
        FileName        = [System.IO.Path]::GetFileName([string]$State.dest)
        Percent         = [double]$percent
        PercentText     = if ($totalBytes -gt 0) { ('{0:N2}٪' -f $percent) } else { '—' }
        TransferText    = $transferText
        SpeedText       = if ($isPaused) {
            'دانلود موقتاً متوقف است'
        }
        elseif ([string]$State.status -eq 'failed' -and $partialBytes -gt 0) {
            (Format-ByteSize -Bytes $partialBytes) + ' برای ادامه امن ذخیره شده است'
        }
        else {
            Get-SpeedPresentation -State $State -CompletedBytes $completedBytes
        }
        StatusText      = $statusPresentation.Text
        StatusBrush     = $statusPresentation.Brush
        StatusPriority  = $statusPresentation.Priority
        ErrorText       = $cleanError
        ErrorVisibility = if ($cleanError) { 'Visible' } else { 'Collapsed' }
        UpdatedAt       = [datetime]$State.updated_at
        CompletedBytes  = $completedBytes
        TotalBytes      = $totalBytes
        StateStatus     = [string]$State.status
        StateFilePath   = [string]$State._state_file
        Destination     = [string]$State.dest
        Kind            = if ($null -eq $State.kind) { 'background' } else { [string]$State.kind }
        ManagedBy       = [string]$State.managed_by
        IsPaused        = $isPaused
        ActionText      = if ($isPaused) { 'ادامه' } else { 'مکث' }
        ActionVisibility = if ($isActive) { 'Visible' } else { 'Collapsed' }
        CancelVisibility = if ($isActive) { 'Visible' } else { 'Collapsed' }
        RetryVisibility = if ([string]$State.status -eq 'failed') { 'Visible' } else { 'Collapsed' }
    }
}

function Get-MonitorSnapshot {
    $unsortedViewModels = foreach ($state in @(Get-LatestDownloadStates)) {
        ConvertTo-DownloadViewModel -State $state
    }
    $viewModels = @($unsortedViewModels | Sort-Object -Property StatusPriority, FriendlyName)

    $countActive = @($viewModels | Where-Object { $_.StateStatus -in @('starting', 'downloading') }).Count
    $countCompleted = @($viewModels | Where-Object { $_.StateStatus -eq 'completed' }).Count
    $countProblem = @($viewModels | Where-Object { $_.StateStatus -in @('failed', 'cancelled') }).Count
    $measurable = @($viewModels | Where-Object { $_.TotalBytes -gt 0 -and $_.StateStatus -notin @('failed', 'cancelled') })
    $totalBytes = [long](($measurable | Measure-Object -Property TotalBytes -Sum).Sum)
    $completedBytes = [long](($measurable | Measure-Object -Property CompletedBytes -Sum).Sum)
    $overallPercent = if ($totalBytes -gt 0) {
        [math]::Round(($completedBytes / $totalBytes) * 100, 1)
    }
    else {
        0
    }

    return [pscustomobject]@{
        Downloads      = $viewModels
        ActiveCount    = $countActive
        CompletedCount = $countCompleted
        ProblemCount   = $countProblem
        OverallPercent = $overallPercent
    }
}

if ($SelfTest) {
    $snapshot = Get-MonitorSnapshot
    $snapshot | Add-Member -NotePropertyName 'ResumeWorkerExists' -NotePropertyValue (
        Test-Path -LiteralPath $resumeWorkerScriptPath -PathType Leaf
    )
    $snapshot | ConvertTo-Json -Depth 5
    exit 0
}

$monitorMutexCreated = $false
$script:monitorMutex = [System.Threading.Mutex]::new(
    $true,
    'Local\ComfyUIDownloadMonitorWindowV3',
    [ref]$monitorMutexCreated
)
if (-not $monitorMutexCreated) {
    $script:monitorMutex.Dispose()
    exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DownloadProcessControl
{
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtSuspendProcess(IntPtr processHandle);

    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtResumeProcess(IntPtr processHandle);
}
'@

function Get-VerifiedDownloadProcess {
    param($Download)

    if ($null -eq $Download -or -not (Test-SafeDownloadId -DownloadId ([string]$Download.DownloadId))) {
        throw 'شناسه دانلود معتبر نیست.'
    }

    $processId = [int]$Download.ProcessId
    $expectedCreateTime = [double]$Download.ProcessCreateTime
    if ($processId -le 0 -or $expectedCreateTime -le 0) {
        throw 'اطلاعات پردازش این دانلود کامل نیست.'
    }

    $process = Get-Process -Id $processId -ErrorAction Stop
    $actualCreateTime = ([DateTimeOffset]$process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000.0
    if ([math]::Abs($actualCreateTime - $expectedCreateTime) -gt 2.5) {
        $process.Dispose()
        throw 'پردازش دانلود عوض شده است؛ برای ایمنی فرمان اجرا نشد.'
    }

    $isExpectedProcess = $process.ProcessName -match '^python(w)?$' -or
        ($Download.ManagedBy -eq 'ComfyUI Download Monitor' -and $process.ProcessName -eq 'powershell')
    if (-not $isExpectedProcess) {
        $process.Dispose()
        throw 'پردازش پیدا شده متعلق به دانلودکننده ComfyUI نیست.'
    }

    return $process
}

function Set-DownloadPaused {
    param(
        $Download,
        [bool]$Pause
    )

    $process = $null
    try {
        $process = Get-VerifiedDownloadProcess -Download $Download
        $nativeResult = if ($Pause) {
            [DownloadProcessControl]::NtSuspendProcess($process.Handle)
        }
        else {
            [DownloadProcessControl]::NtResumeProcess($process.Handle)
        }

        if ($nativeResult -ne 0) {
            throw "ویندوز فرمان را نپذیرفت (کد $nativeResult)."
        }

        $downloadId = [string]$Download.DownloadId
        if ($Pause) {
            $script:pausedDownloads[$downloadId] = [pscustomobject]@{
                DownloadId        = $downloadId
                ProcessId         = [int]$Download.ProcessId
                ProcessCreateTime = [double]$Download.ProcessCreateTime
            }
        }
        else {
            [void]$script:pausedDownloads.Remove($downloadId)
        }
        Save-PausedDownloadState
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Request-DownloadCancel {
    param($Download)

    $downloadId = [string]$Download.DownloadId
    if (-not (Test-SafeDownloadId -DownloadId $downloadId)) {
        throw 'شناسه دانلود معتبر نیست.'
    }

    if ($script:pausedDownloads.ContainsKey($downloadId)) {
        Set-DownloadPaused -Download $Download -Pause $false
    }

    $cancelPath = Join-Path $downloadStateDirectory ($downloadId + '.cancel')
    [System.IO.File]::WriteAllBytes($cancelPath, [byte[]]@())

    if ($Download.Kind -eq 'foreground') {
        $process = $null
        try {
            $process = Get-VerifiedDownloadProcess -Download $Download
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        finally {
            if ($null -ne $process) {
                $process.Dispose()
            }
        }

        $destinationDirectory = [System.IO.Path]::GetDirectoryName($Download.Destination)
        $destinationName = [System.IO.Path]::GetFileName($Download.Destination)
        Get-ChildItem -LiteralPath $destinationDirectory -Filter ($destinationName + '.*.part') -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $state = Get-Content -LiteralPath $Download.StateFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $state.status = 'cancelled'
        $state.completed_bytes = 0
        $state.error = $null
        $state.updated_at = [datetime]::UtcNow.ToString('o')
        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Download.StateFilePath -Encoding UTF8
    }
}

function Start-DownloadRetry {
    param($Download)

    if (-not (Test-SafeDownloadId -DownloadId ([string]$Download.DownloadId))) {
        throw 'شناسه دانلود معتبر نیست.'
    }
    if (-not (Test-Path -LiteralPath $resumeWorkerScriptPath -PathType Leaf)) {
        throw 'بخش ادامه امن دانلود پیدا نشد.'
    }

    $resolvedStatePath = [System.IO.Path]::GetFullPath([string]$Download.StateFilePath)
    $resolvedStateDirectory = [System.IO.Path]::GetFullPath($downloadStateDirectory).TrimEnd('\')
    if (-not $resolvedStatePath.StartsWith(
            $resolvedStateDirectory + '\',
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw 'مسیر فایل وضعیت معتبر نیست.'
    }

    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$resumeWorkerScriptPath`" -StateFilePath `"$resolvedStatePath`" -ForceRetry"
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Resume-AllTrackedDownloads {
    foreach ($record in @($script:pausedDownloads.Values)) {
        try {
            Set-DownloadPaused -Download $record -Pause $false
        }
        catch {
            # A finished or replaced process cannot be resumed and is safe to forget.
            [void]$script:pausedDownloads.Remove([string]$record.DownloadId)
        }
    }
    Save-PausedDownloadState
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ComfyUI Download Monitor"
        Width="860" Height="700" MinWidth="660" MinHeight="500"
        WindowStartupLocation="CenterScreen"
        AutomationProperties.Name="پایش دانلود مدل‌های ComfyUI"
        Background="#0B1020" Foreground="#E5E7EB"
        FontFamily="Segoe UI" FlowDirection="RightToLeft">
    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="TextWrapping" Value="Wrap" />
        </Style>
        <Style x:Key="ProgressStyle" TargetType="ProgressBar">
            <Setter Property="Height" Value="12" />
            <Setter Property="Foreground" Value="#3B82F6" />
            <Setter Property="Background" Value="#263047" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="FlowDirection" Value="LeftToRight" />
        </Style>
        <Style x:Key="ActionButtonStyle" TargetType="Button">
            <Setter Property="Padding" Value="14,7" />
            <Setter Property="MinHeight" Value="38" />
            <Setter Property="Margin" Value="8,0,0,0" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="Background" Value="#334155" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Cursor" Value="Hand" />
        </Style>
    </Window.Resources>

    <Grid Margin="24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,18">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0">
                <TextBlock Text="دانلود مدل‌های ComfyUI" FontSize="27" FontWeight="SemiBold" />
                <TextBlock Text="مدیریت دانلودهای عادی و MCP — ادامه امن بعد از قطع یا ری‌استارت" Foreground="#94A3B8" Margin="0,5,0,0" />
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" FlowDirection="RightToLeft" Margin="16,0,0,0">
                <Button x:Name="RefreshButton" Content="تازه‌سازی" Padding="18,9"
                        AutomationProperties.Name="تازه‌سازی وضعیت دانلودها"
                        Background="#2563EB" Foreground="White" BorderThickness="0" Cursor="Hand" />
                <Button x:Name="PauseAllButton" Content="مکث همه" Padding="18,9" Margin="8,0,0,0"
                        AutomationProperties.Name="مکث یا ادامه همه دانلودهای فعال"
                        Background="#334155" Foreground="White" BorderThickness="0" Cursor="Hand" />
            </StackPanel>
        </Grid>

        <Border Grid.Row="1" Background="#151C2F" CornerRadius="12" Padding="18" Margin="0,0,0,16">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                    <TextBlock Text="پیشرفت کل" Foreground="#94A3B8" />
                    <TextBlock x:Name="OverallPercentText" Text="۰٪" FontSize="30" FontWeight="SemiBold" />
                </StackPanel>
                <StackPanel Grid.Column="1">
                    <TextBlock Text="فعال" Foreground="#94A3B8" />
                    <TextBlock x:Name="ActiveCountText" Text="۰" FontSize="24" FontWeight="SemiBold" Foreground="#60A5FA" />
                </StackPanel>
                <StackPanel Grid.Column="2">
                    <TextBlock Text="کامل" Foreground="#94A3B8" />
                    <TextBlock x:Name="CompletedCountText" Text="۰" FontSize="24" FontWeight="SemiBold" Foreground="#34D399" />
                </StackPanel>
                <StackPanel Grid.Column="3">
                    <TextBlock Text="نیازمند بررسی" Foreground="#94A3B8" />
                    <TextBlock x:Name="ProblemCountText" Text="۰" FontSize="24" FontWeight="SemiBold" Foreground="#FB7185" />
                </StackPanel>
            </Grid>
        </Border>

        <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <ItemsControl x:Name="DownloadsList">
                <ItemsControl.ItemTemplate>
                    <DataTemplate>
                        <Border Background="#12192A" BorderBrush="#263047" BorderThickness="1" CornerRadius="10" Padding="16" Margin="0,0,0,12">
                            <StackPanel>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*" />
                                        <ColumnDefinition Width="Auto" />
                                    </Grid.ColumnDefinitions>
                                    <StackPanel Grid.Column="0">
                                        <TextBlock Text="{Binding FriendlyName}" FontSize="17" FontWeight="SemiBold" />
                                        <TextBlock Text="{Binding FileName}" FontSize="11" Foreground="#7F8CA8" FlowDirection="LeftToRight" HorizontalAlignment="Right" Margin="0,3,0,0" />
                                    </StackPanel>
                                    <StackPanel Grid.Column="1" Margin="18,0,0,0" HorizontalAlignment="Left">
                                        <TextBlock Text="{Binding PercentText}" FontSize="20" FontWeight="SemiBold" HorizontalAlignment="Left" />
                                        <TextBlock Text="{Binding StatusText}" Foreground="{Binding StatusBrush}" HorizontalAlignment="Left" />
                                    </StackPanel>
                                </Grid>
                                <ProgressBar Value="{Binding Percent}" Maximum="100" Style="{StaticResource ProgressStyle}" Margin="0,13,0,8"
                                             AutomationProperties.Name="{Binding FriendlyName}"
                                             AutomationProperties.HelpText="{Binding PercentText}" />
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="Auto" />
                                        <ColumnDefinition Width="*" />
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" Text="{Binding TransferText}" Foreground="#C3CAD8" FlowDirection="LeftToRight" />
                                    <TextBlock Grid.Column="1" Text="{Binding SpeedText}" Foreground="#94A3B8" HorizontalAlignment="Left" Margin="18,0,0,0" />
                                </Grid>
                                <TextBlock Text="{Binding ErrorText}" Visibility="{Binding ErrorVisibility}" Foreground="#FB7185" Margin="0,9,0,0" />
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" FlowDirection="RightToLeft" Margin="0,12,0,0">
                                    <Button x:Name="PauseResumeButton" Content="{Binding ActionText}" Tag="{Binding}"
                                            AutomationProperties.Name="{Binding ActionText}"
                                            Visibility="{Binding ActionVisibility}" Style="{StaticResource ActionButtonStyle}" />
                                    <Button x:Name="CancelDownloadButton" Content="لغو دانلود" Tag="{Binding}"
                                            AutomationProperties.Name="لغو دانلود"
                                            Visibility="{Binding CancelVisibility}" Style="{StaticResource ActionButtonStyle}"
                                            Background="#9F1239" />
                                    <Button x:Name="RetryDownloadButton" Content="ادامه / تلاش مجدد" Tag="{Binding}"
                                            AutomationProperties.Name="ادامه دانلود از فایل ذخیره‌شده"
                                            Visibility="{Binding RetryVisibility}" Style="{StaticResource ActionButtonStyle}"
                                            Background="#047857" />
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </DataTemplate>
                </ItemsControl.ItemTemplate>
            </ItemsControl>
        </ScrollViewer>

        <Grid Grid.Row="3" Margin="0,10,0,0">
            <TextBlock x:Name="LastUpdatedText" Foreground="#7F8CA8" />
            <TextBlock Text="بستن پنجره دانلود را قطع نمی‌کند؛ فایل نیمه‌کاره برای ادامه نگه داشته می‌شود" Foreground="#7F8CA8" HorizontalAlignment="Left" />
        </Grid>
    </Grid>
</Window>
'@

$xmlReader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$downloadsList = $window.FindName('DownloadsList')
$overallPercentText = $window.FindName('OverallPercentText')
$activeCountText = $window.FindName('ActiveCountText')
$completedCountText = $window.FindName('CompletedCountText')
$problemCountText = $window.FindName('ProblemCountText')
$lastUpdatedText = $window.FindName('LastUpdatedText')
$refreshButton = $window.FindName('RefreshButton')
$pauseAllButton = $window.FindName('PauseAllButton')

function Update-MonitorWindow {
    try {
        $snapshot = Get-MonitorSnapshot
        $script:lastSnapshot = $snapshot
        $downloadsList.ItemsSource = @($snapshot.Downloads)
        $overallPercentText.Text = ('{0:N1}٪' -f $snapshot.OverallPercent)
        $activeCountText.Text = [string]$snapshot.ActiveCount
        $completedCountText.Text = [string]$snapshot.CompletedCount
        $problemCountText.Text = [string]$snapshot.ProblemCount
        $lastUpdatedText.Text = 'آخرین به‌روزرسانی: ' + (Get-Date -Format 'HH:mm:ss')

        $activeDownloads = @($snapshot.Downloads | Where-Object { $_.StateStatus -in @('starting', 'downloading') })
        $unpausedDownloads = @($activeDownloads | Where-Object { -not $_.IsPaused })
        $pauseAllButton.IsEnabled = $activeDownloads.Count -gt 0
        $pauseAllButton.Content = if ($activeDownloads.Count -gt 0 -and $unpausedDownloads.Count -eq 0) {
            'ادامه همه'
        }
        else {
            'مکث همه'
        }
    }
    catch {
        $lastUpdatedText.Text = 'خطا در خواندن وضعیت؛ دوباره تلاش می‌شود'
    }
}

$refreshButton.Add_Click({ Update-MonitorWindow })

$pauseAllButton.Add_Click({
    if ($null -eq $script:lastSnapshot) {
        return
    }

    $activeDownloads = @($script:lastSnapshot.Downloads | Where-Object { $_.StateStatus -in @('starting', 'downloading') })
    $shouldPause = @($activeDownloads | Where-Object { -not $_.IsPaused }).Count -gt 0
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($download in $activeDownloads) {
        if ($download.IsPaused -ne $shouldPause) {
            try {
                Set-DownloadPaused -Download $download -Pause $shouldPause
            }
            catch {
                $errors.Add("$($download.FriendlyName): $($_.Exception.Message)")
            }
        }
    }

    Update-MonitorWindow
    if ($errors.Count -gt 0) {
        [void][System.Windows.MessageBox]::Show(
            ($errors -join [Environment]::NewLine),
            'برخی فرمان‌ها اجرا نشد',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
    }
})

$window.AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)

        $button = $eventArgs.OriginalSource
        while ($null -ne $button -and $button -isnot [System.Windows.Controls.Button]) {
            $button = [System.Windows.Media.VisualTreeHelper]::GetParent($button)
        }
        if ($null -eq $button -or $button.Name -notin @('PauseResumeButton', 'CancelDownloadButton', 'RetryDownloadButton')) {
            return
        }

        $download = $button.Tag
        try {
            switch ($button.Name) {
                'PauseResumeButton' {
                    Set-DownloadPaused -Download $download -Pause (-not [bool]$download.IsPaused)
                }
                'RetryDownloadButton' {
                    Start-DownloadRetry -Download $download
                    $lastUpdatedText.Text = 'ادامه امن دانلود شروع شد'
                }
                'CancelDownloadButton' {
                $confirmation = [System.Windows.MessageBox]::Show(
                    "دانلود «$($download.FriendlyName)» لغو شود؟`n`nفایل نیمه‌دانلودشده پاک می‌شود. بستن پنجره نیازی به لغو ندارد و دانلود را قطع نمی‌کند.",
                    'تأیید لغو دانلود',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning,
                    [System.Windows.MessageBoxResult]::No
                )
                if ($confirmation -eq [System.Windows.MessageBoxResult]::Yes) {
                    Request-DownloadCancel -Download $download
                    $lastUpdatedText.Text = 'درخواست لغو ارسال شد؛ منتظر توقف امن ComfyUI هستیم'
                }
                }
            }
        }
        catch {
            [void][System.Windows.MessageBox]::Show(
                $_.Exception.Message,
                'فرمان اجرا نشد',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }

        $eventArgs.Handled = $true
        Update-MonitorWindow
    }
)

$window.Add_Closing({
    $timer.Stop()
    Resume-AllTrackedDownloads
})

$window.Add_ContentRendered({
    $window.Topmost = $true
    [void]$window.Activate()
    $window.Topmost = $false
})

$window.Add_Closed({
    if ($null -ne $script:monitorMutex) {
        try {
            $script:monitorMutex.ReleaseMutex()
        }
        catch {
        }
        $script:monitorMutex.Dispose()
        $script:monitorMutex = $null
    }
})

$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds($refreshIntervalSeconds)
$timer.Add_Tick({ Update-MonitorWindow })
$timer.Start()

Update-MonitorWindow
[void]$window.ShowDialog()
