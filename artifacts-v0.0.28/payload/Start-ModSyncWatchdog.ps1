<#
.SYNOPSIS
    Login-time watchdog: waits for isaac-ng.exe, then starts the full lobby
    watcher. Installed as a Startup shortcut by Install-ModSyncPatch.ps1 so
    the host sync also runs when Isaac is launched directly via Steam.

    v0.0.23: machine-wide named mutex + lockfile prevent duplicate watchers.
    The watchdog keeps running and restarts the watcher if it dies while
    Isaac is still alive. All bridge output is redirected to lobby-sync.log.
#>
param(
    [Parameter(Mandatory = $true)][string]$ToolsRoot,
    [Parameter(Mandatory = $true)][string]$IsaacRoot,
    [string]$Version = '0.0.23',
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'SilentlyContinue'
$log = Join-Path $env:LOCALAPPDATA 'IsaacModSync\lobby-sync.log'
$lockDir = Join-Path $env:LOCALAPPDATA 'IsaacModSync'
$lockFile = Join-Path $lockDir 'watchdog.lock'

function Log([string]$m) {
    try {
        $dir = Split-Path -Parent $log
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $log -Value ("[{0}] WATCHDOG {1}" -f [DateTime]::UtcNow.ToString('o'), $m) -Encoding UTF8
    } catch { }
}

# --- Duplikat-Sperre: Mutex + Lockfile -----------------------------------
$createdNew = $false
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($true, 'Global\IsaacModSync-LobbyWatchdog', [ref]$createdNew)
} catch { Log "Mutex-Fehler: $($_.Exception.Message)" }
if (-not $createdNew) { Log 'bereits aktiv (Mutex) - beende Duplikat'; if ($mutex) { $mutex.Dispose() }; return }

try {
    New-Item -ItemType Directory -Force -Path $lockDir | Out-Null
    [IO.File]::WriteAllText($lockFile, ("{0}|{1}" -f $PID, [DateTime]::UtcNow.ToString('o')))
    Log "gestartet (PID $PID, Warte auf isaac-ng, Version $Version)"

    $watcher = Join-Path $ToolsRoot 'Start-ModSyncLobbySync.ps1'
    if (-not (Test-Path -LiteralPath $watcher -PathType Leaf)) { Log "Watcher fehlt: $watcher"; return }

    $deadline = (Get-Date).AddHours(12)
    $watcherProc = $null
    $lastStart = [DateTime]::MinValue
    $expectedExe = [IO.Path]::GetFullPath((Join-Path $IsaacRoot 'isaac-ng.exe'))

    while ((Get-Date) -lt $deadline) {
        $game = Get-Process -Name 'isaac-ng' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($game) {
            $gamePid = $game.Id
            # Pfad pruefen, damit ein fremdes isaac-ng.exe den Watcher nicht startet.
            try {
                $actual = [IO.Path]::GetFullPath($game.Path)
                if ($actual -and $actual -ne $expectedExe) {
                    Log "isaac-ng PID $gamePid hat fremden Pfad $actual - ignoriert"
                    $game = $null
                }
            } catch { }
        }

        if ($game) {
            if (-not $watcherProc -or $watcherProc.HasExited) {
                if ($watcherProc -and $watcherProc.HasExited) { Log "Watcher (PID $($watcherProc.Id)) beendet - starte neu" }
                # Mindestens 10 s zwischen zwei Starts, sonst abbrechen.
                if (((Get-Date) - $lastStart).TotalSeconds -ge 10) {
                    Start-Sleep -Seconds 8
                    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                        '-File', "`"$watcher`"", '-ToolsRoot', "`"$ToolsRoot`"",
                        '-IsaacRoot', "`"$IsaacRoot`"", '-GamePid', "$gamePid",
                        '-Version', $Version, '-TimeoutSeconds', "$TimeoutSeconds")
                    try {
                        $watcherProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru -ErrorAction Stop
                        $lastStart = Get-Date
                        Log "Lobby-Watcher gestartet (PID $($watcherProc.Id), Spiel-PID $gamePid)"
                    } catch { Log "Watcher-Start fehlgeschlagen: $($_.Exception.Message)" }
                }
            }
        } elseif ($watcherProc) {
            # Spiel beendet -> Watcher darf ausgehen.
            Log 'isaac-ng nicht mehr aktiv - Watcher wird nicht neu gestartet'
            $watcherProc = $null
        }
        Start-Sleep -Seconds 3
    }
    Log 'Zeitueberschreitung (12 h) - Watchdog beendet'
} finally {
    try { if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force } } catch { }
    if ($mutex) { $mutex.Dispose() }
}
