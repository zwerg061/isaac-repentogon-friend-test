<#
.SYNOPSIS
    One-click fix offered by the Isaac Desync Assistant: restore the previous
    temp session and immediately rebuild it from the same trusted host profile.

.NOTES
    Isaac must be closed. Only <Isaac>/mods and the isolated mod data folder are
    touched; real saves and MCM settings are never modified.
#>
param(
    [Parameter(Mandatory = $true)][string]$IsaacRoot,
    [Parameter(Mandatory = $true)][string]$Profile,
    [string]$Python = 'py',
    [string]$SteamCmd
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Run-TempModProfile.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Temp-Runner fehlt: $runner" }
if (-not (Test-Path -LiteralPath $Profile -PathType Leaf)) { throw "Host-Profil fehlt: $Profile" }
if (Get-Process -Name 'isaac-ng' -ErrorAction SilentlyContinue) {
    throw 'Isaac laeuft noch. Bitte zuerst das Spiel schliessen.'
}

Write-Host 'Isaac Desync Assistant: stelle urspruengliche Mods und SaveData wieder her ...' -ForegroundColor Cyan
& $runner -IsaacRoot $IsaacRoot -RestoreOnly
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "RestoreOnly fehlgeschlagen (Exit $LASTEXITCODE)." }

$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$runner`"",
          '-IsaacRoot', "`"$IsaacRoot`"", '-Profile', "`"$Profile`"", '-TrustProfile')
if ($SteamCmd) { $args += @('-SteamCmd', "`"$SteamCmd`"") }
Write-Host 'Isaac Desync Assistant: baue Temp-Profil und isoliertes SaveData neu auf ...' -ForegroundColor Cyan
& powershell @args
if ($LASTEXITCODE -ne 0) { throw "Neues Staging fehlgeschlagen (Exit $LASTEXITCODE)." }
Write-Host 'Profil und SaveData wurden neu synchronisiert. Das Spiel wurde nicht automatisch gestartet.' -ForegroundColor Green
