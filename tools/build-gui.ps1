<#
.SYNOPSIS
    Baut das eigenstaendige Tool "RgonOnlineUnlock.exe" (Win32, statische CRT).
#>
param(
    [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [string]$Src = (Join-Path (Split-Path -Parent $PSScriptRoot) 'tool\RgonOnlineUnlock.cpp')
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'find-vcvars.ps1')
$vcvars = Find-VcVars32
if ([string]::IsNullOrWhiteSpace($vcvars)) { throw 'vcvars32.bat nicht gefunden (Visual Studio C++-Toolchain fehlt).' }
if (-not (Test-Path $Src))    { throw "Quelle nicht gefunden: $Src" }

New-Item -ItemType Directory -Force -Path $Out | Out-Null
$obj = Join-Path $env:TEMP 'RgonOnlineUnlock.obj'
$exe = Join-Path $Out 'RgonOnlineUnlock.exe'

$cmd = @(
    "call `"$vcvars`" >nul",
    "cl /nologo /W4 /O2 /MT /EHsc /utf-8 /DUNICODE /D_UNICODE `"$Src`" /Fo:`"$obj`" /Fe:`"$exe`" /link /SUBSYSTEM:WINDOWS /MANIFEST:EMBED /MANIFESTUAC:`"level='asInvoker' uiAccess='false'`" user32.lib gdi32.lib shell32.lib ole32.lib comctl32.lib advapi32.lib"
) -join ' && '

Write-Host 'Kompiliere ...'
cmd.exe /c $cmd
if ($LASTEXITCODE -ne 0) { throw "Build fehlgeschlagen (Exit $LASTEXITCODE)" }

$f = Get-Item $exe
Write-Host ("Fertig: {0} ({1:N0} KB)" -f $f.FullName, ($f.Length / 1KB))
