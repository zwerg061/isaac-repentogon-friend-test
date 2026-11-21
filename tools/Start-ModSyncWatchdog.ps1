<#
.SYNOPSIS
    Login-time watchdog: waits for isaac-ng.exe, then starts the full lobby
    watcher. Installed as a Startup shortcut by Install-ModSyncPatch.ps1 so
    the host sync also runs when Isaac is launched directly via Steam.
#>
param(
    [Parameter(Mandatory = $true)][string]$ToolsRoot,
    [Parameter(Mandatory = $true)][string]$IsaacRoot,
    [string]$Version = '0.0.19'
)

$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $env:LOCALAPPDATA 'IsaacModSync\lobby-sync.log'
function Log([string]$m) {
    try {
        $dir = Split-Path -Parent $log
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $log -Value ("[{0}] WATCHDOG {1}" -f [DateTime]::UtcNow.ToString('o'), $m) -Encoding UTF8
    } catch { }
}

Log "gestartet (Warte auf isaac-ng)"
$deadline = (Get-Date).AddHours(12)
$seenPid = 0
while ((Get-Date) -lt $deadline) {
    $game = Get-Process -Name 'isaac-ng' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($game) { $seenPid = $game.Id; break }
    Start-Sleep -Seconds 2
}
if (-not $seenPid) { Log 'Zeitueberschreitung - kein Spiel gestartet'; return }
Log "Spiel erkannt (PID $seenPid)"
Start-Sleep -Seconds 8
$watcher = Join-Path $ToolsRoot 'Start-ModSyncLobbySync.ps1'
if (-not (Test-Path -LiteralPath $watcher -PathType Leaf)) { Log "Watcher fehlt: $watcher"; return }
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', "`"$watcher`"", '-ToolsRoot', "`"$ToolsRoot`"", '-IsaacRoot', "`"$IsaacRoot`"",
    '-GamePid', "$seenPid", '-Version', $Version) -WindowStyle Hidden
Log 'Lobby-Watcher gestartet'
