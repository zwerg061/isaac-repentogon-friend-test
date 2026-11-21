<#
.SYNOPSIS
    Baut den standardkonformen Inno-Setup-Installer (kein RCDATA-Dropper).
#>
param(
    [string]$Version = '0.0.25',
    [string]$SourceDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts-v0.0.25'),
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'sandbox\inno-setup-output'),
    [string]$Iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Iscc)) { throw "ISCC.exe nicht gefunden: $Iscc" }
if (-not (Test-Path -LiteralPath $SourceDir)) { throw "Quellordner fehlt: $SourceDir" }
$script = Join-Path $PSScriptRoot 'installer\isaac-mod-launcher.iss'
if (-not (Test-Path -LiteralPath $script)) { throw "Installer-Skript fehlt: $script" }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

& $Iscc "/DAppVersion=$Version" "/DSourceDir=$SourceDir" "/DOutputDir=$OutputDir" $script
if ($LASTEXITCODE -ne 0) { throw "Inno Setup Build fehlgeschlagen (Exit $LASTEXITCODE)" }
Get-ChildItem -LiteralPath $OutputDir -Filter '*.exe' | ForEach-Object {
    Write-Host ("Fertig: {0} ({1:N0} KB) SHA256={2}" -f $_.FullName, ($_.Length / 1KB), (Get-FileHash $_.FullName -Algorithm SHA256).Hash)
}
