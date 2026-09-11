param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'

$compilerPath = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
    throw 'کامپایلر داخلی .NET Framework ویندوز پیدا نشد.'
}

$buildDirectory = Join-Path $PSScriptRoot 'build'
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

$launcherPath = Join-Path $resolvedOutputDirectory 'ComfyUIDownloadMonitor.exe'
$setupPath = Join-Path $resolvedOutputDirectory 'ComfyUIDownloadMonitorSetup.exe'
$manifestPath = Join-Path $buildDirectory 'app.manifest'
$iconPath = Join-Path $buildDirectory 'ComfyUIDownloadMonitor.ico'

$launcherArguments = @(
    '/nologo'
    '/utf8output'
    '/target:winexe'
    '/platform:anycpu'
    '/optimize+'
    "/win32manifest:$manifestPath"
    "/win32icon:$iconPath"
    "/out:$launcherPath"
    '/reference:System.dll'
    '/reference:System.Windows.Forms.dll'
    (Join-Path $buildDirectory 'Launcher.cs')
)
& $compilerPath $launcherArguments
if ($LASTEXITCODE -ne 0) {
    throw "ساخت لانچر با کد $LASTEXITCODE ناموفق بود."
}

$setupArguments = @(
    '/nologo'
    '/utf8output'
    '/target:winexe'
    '/platform:anycpu'
    '/optimize+'
    "/win32manifest:$manifestPath"
    "/win32icon:$iconPath"
    "/out:$setupPath"
    '/reference:System.dll'
    '/reference:System.Management.dll'
    '/reference:System.Windows.Forms.dll'
    "/resource:$launcherPath,ComfyUIDownloadMonitor.Resources.LauncherExe"
    "/resource:$(Join-Path $PSScriptRoot 'ComfyDownloadMonitor.ps1'),ComfyUIDownloadMonitor.Resources.MonitorScript"
    "/resource:$(Join-Path $PSScriptRoot 'ComfyDownloadWatcher.ps1'),ComfyUIDownloadMonitor.Resources.WatcherScript"
    "/resource:$(Join-Path $PSScriptRoot 'ComfyResumeWorker.ps1'),ComfyUIDownloadMonitor.Resources.ResumeWorkerScript"
    "/resource:$(Join-Path $PSScriptRoot 'README.md'),ComfyUIDownloadMonitor.Resources.Readme"
    (Join-Path $buildDirectory 'Setup.cs')
)
& $compilerPath $setupArguments
if ($LASTEXITCODE -ne 0) {
    throw "ساخت نصب‌کننده با کد $LASTEXITCODE ناموفق بود."
}

Copy-Item -LiteralPath (
    Join-Path $PSScriptRoot 'ComfyDownloadMonitor.ps1'
) -Destination $resolvedOutputDirectory -Force
Copy-Item -LiteralPath (
    Join-Path $PSScriptRoot 'ComfyDownloadWatcher.ps1'
) -Destination $resolvedOutputDirectory -Force
Copy-Item -LiteralPath (
    Join-Path $PSScriptRoot 'ComfyResumeWorker.ps1'
) -Destination $resolvedOutputDirectory -Force
Copy-Item -LiteralPath (
    Join-Path $PSScriptRoot 'README.md'
) -Destination $resolvedOutputDirectory -Force

Get-Item -LiteralPath $launcherPath, $setupPath |
    Select-Object Name, Length, LastWriteTime

Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath |
    Select-Object Algorithm, Hash, Path
