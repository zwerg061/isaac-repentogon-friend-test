<#
.SYNOPSIS
    Integrationstest fuer den nativen ISteamUGC-Download in
    SteamModProfileBridge.exe (v0.0.22). Kein SteamCMD, keine Zugangsdaten.
#>
param(
    [string]$ToolsRoot = 'G:\Coode\the binding of isaac\multyplayer modet\sandbox\release-v0.0.1\tools',
    [string]$IsaacRoot = 'G:\Steam\steamapps\common\The Binding of Isaac Rebirth',
    [string]$WorkshopId = '1348031964'
)

$ErrorActionPreference = 'Stop'
$bridge = Join-Path $ToolsRoot 'SteamModProfileBridge.exe'
if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) { throw "Bridge fehlt: $bridge" }
$session = Join-Path $env:TEMP 'isaac-ugc-integration-test'
Remove-Item -LiteralPath $session -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $session | Out-Null
$workshopRoot = Join-Path (Split-Path (Split-Path $IsaacRoot)) 'workshop\content\250900'

$args = @('--mode','download','--isaac-root',"`"$IsaacRoot`"",'--session',"`"$session`"",
    '--workshop-ids',$WorkshopId,'--workshop-root',"`"$workshopRoot`"",'--timeout','90')
Push-Location $ToolsRoot
try {
    $proc = Start-Process -FilePath $bridge -ArgumentList $args -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $session 'stdout.log') `
        -RedirectStandardError (Join-Path $session 'stderr.log')
} finally { Pop-Location }

$failures = @()
if ($proc.ExitCode -ne 0) { $failures += "Bridge Exit $($proc.ExitCode)" }
$complete = Join-Path $session 'workshop-download-complete.json'
if (-not (Test-Path -LiteralPath $complete -PathType Leaf)) { $failures += 'workshop-download-complete.json fehlt' }
$stdout = Get-Content (Join-Path $session 'stdout.log') -Raw -ErrorAction SilentlyContinue
if ($stdout -notmatch '100%') { $failures += 'Kein 100%-Fortschritt im Bridge-Log' }
$progress = Get-Content (Join-Path $env:LOCALAPPDATA 'IsaacModSync\lobby_progress.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
if ($progress.percent -ne 100 -or -not $progress.done) { $failures += 'lobby_progress.json nicht 100%/done=true' }
$modDir = Join-Path $workshopRoot $WorkshopId
if (-not (Test-Path -LiteralPath $modDir -PathType Container)) { $failures += "Mod-Ordner fehlt: $modDir" }

if ($failures.Count) {
    Write-Host ("UGC-Download Test FEHLGESCHLAGEN:`n  " + ($failures -join "`n  ")) -ForegroundColor Red
    exit 1
}
Write-Host "UGC-Download Test BESTANDEN: Mod $WorkshopId via ISteamUGC, 0->100%, lobby_progress done=true" -ForegroundColor Green
exit 0
