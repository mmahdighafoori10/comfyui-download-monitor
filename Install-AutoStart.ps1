param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$shortcutPath = Join-Path $startupDirectory 'ComfyUI Download Monitor Watcher.lnk'

if ($Remove) {
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
    }
    return
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$launcherPath = Join-Path $PSScriptRoot 'ComfyUIDownloadMonitor.exe'
if (Test-Path -LiteralPath $launcherPath -PathType Leaf) {
    $shortcut.TargetPath = $launcherPath
    $shortcut.Arguments = '--watcher'
    $shortcut.IconLocation = "$launcherPath,0"
}
else {
    $watcherPath = Join-Path $PSScriptRoot 'ComfyDownloadWatcher.ps1'
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellPath)) {
        $powerShellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    }

    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherPath`""
    $shortcut.IconLocation = 'C:\Windows\System32\shell32.dll,167'
}
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Automatically opens the ComfyUI download monitor when a model download starts.'
$shortcut.Save()
