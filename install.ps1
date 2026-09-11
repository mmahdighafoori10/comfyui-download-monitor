[CmdletBinding()]
param(
    [string]$Repository = 'mmahdighafoori10/comfyui-download-monitor',
    [switch]$NoLaunch,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$productName = 'ComfyUI Download Monitor'
$setupAssetName = 'ComfyUIDownloadMonitorSetup.exe'
$checksumAssetName = 'ComfyUIDownloadMonitorSetup.exe.sha256'
$minimumDotNetRelease = 528040
$dotNetWebInstallerUrl = 'https://go.microsoft.com/fwlink/?LinkId=2085155'

function Write-Step {
    param([string]$Message)

    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Test-DotNetFramework48 {
    try {
        $framework = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
        return [int]$framework.Release -ge $minimumDotNetRelease
    }
    catch {
        return $false
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $maximumAttempts = 3
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -Headers @{
                'User-Agent' = 'ComfyUI-Download-Monitor-Installer'
            }
            return
        }
        catch {
            if ($attempt -eq $maximumAttempts) {
                throw
            }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}

function Install-DotNetFramework48 {
    param([string]$TemporaryDirectory)

    Write-Step '.NET Framework 4.8 was not found; installing the official Microsoft package'
    $installerPath = Join-Path $TemporaryDirectory 'ndp48-web.exe'
    Invoke-DownloadFile -Uri $dotNetWebInstallerUrl -Destination $installerPath

    $signature = Get-AuthenticodeSignature -LiteralPath $installerPath
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid -or
        $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw 'The .NET Framework installer does not have a valid Microsoft digital signature.'
    }

    $process = Start-Process -FilePath $installerPath -ArgumentList '/q', '/norestart' -Verb RunAs -Wait -PassThru
    if ($process.ExitCode -eq 3010) {
        throw '.NET Framework was installed, but Windows must restart. Run this command again after restarting.'
    }
    if ($process.ExitCode -ne 0) {
        throw ".NET Framework setup exited with code $($process.ExitCode)."
    }
    if (-not (Test-DotNetFramework48)) {
        throw '.NET Framework 4.8 was not detected after setup completed.'
    }
}

if ($env:OS -ne 'Windows_NT') {
    throw "$productName is supported only on Windows."
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'Windows PowerShell 5.1 or newer is required.'
}
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Repository must use the owner/repository format.'
}
if ($SelfTest) {
    [pscustomobject]@{
        Repository = $Repository
        Windows = $env:OS -eq 'Windows_NT'
        PowerShellMajor = $PSVersionTable.PSVersion.Major
        DotNetFramework48Present = Test-DotNetFramework48
        SetupAssetName = $setupAssetName
        ChecksumAssetName = $checksumAssetName
        VerifiesSha256 = $true
        CanInstallDotNetFramework = $true
    } | ConvertTo-Json
    return
}

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$temporaryParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$temporaryDirectory = Join-Path $temporaryParent ('ComfyUIDownloadMonitor-Install-' + [guid]::NewGuid().ToString('N'))
$resolvedTemporaryDirectory = [System.IO.Path]::GetFullPath($temporaryDirectory)
$expectedPrefix = $temporaryParent.TrimEnd('\') + '\ComfyUIDownloadMonitor-Install-'
if (-not $resolvedTemporaryDirectory.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The temporary installation path is invalid.'
}

try {
    New-Item -ItemType Directory -Path $resolvedTemporaryDirectory -Force | Out-Null

    if (-not (Test-DotNetFramework48)) {
        Install-DotNetFramework48 -TemporaryDirectory $resolvedTemporaryDirectory
    }
    else {
        Write-Step '.NET Framework is ready'
    }

    $releaseBaseUrl = "https://github.com/$Repository/releases/latest/download"
    $setupPath = Join-Path $resolvedTemporaryDirectory $setupAssetName
    $checksumPath = Join-Path $resolvedTemporaryDirectory $checksumAssetName

    Write-Step 'Downloading the latest GitHub Release'
    Invoke-DownloadFile -Uri "$releaseBaseUrl/$setupAssetName" -Destination $setupPath
    Invoke-DownloadFile -Uri "$releaseBaseUrl/$checksumAssetName" -Destination $checksumPath

    $checksumText = Get-Content -LiteralPath $checksumPath -Raw
    if ($checksumText -notmatch '(?i)\b([0-9a-f]{64})\b') {
        throw 'The published checksum file is invalid.'
    }
    $expectedHash = $matches[1].ToUpperInvariant()
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash
    if ($actualHash -ne $expectedHash) {
        throw 'The Setup SHA-256 does not match the checksum published on GitHub.'
    }
    Write-Step 'SHA-256 verified; starting setup'

    $setupProcess = Start-Process -FilePath $setupPath -ArgumentList '--silent' -Wait -PassThru
    if ($setupProcess.ExitCode -ne 0) {
        throw "Setup exited with code $($setupProcess.ExitCode)."
    }

    $installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\ComfyUI Download Monitor'
    $launcherPath = Join-Path $installDirectory 'ComfyUIDownloadMonitor.exe'
    $receiptPath = Join-Path $installDirectory 'install-state.txt'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Setup completed, but the application files were not found at the expected path.'
    }

    Write-Host "$productName was installed successfully." -ForegroundColor Green
    Write-Host "Path: $installDirectory"
    if (-not $NoLaunch) {
        Start-Process -FilePath $launcherPath | Out-Null
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedTemporaryDirectory) {
        Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
