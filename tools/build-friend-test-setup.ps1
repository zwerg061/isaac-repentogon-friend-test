<#
.SYNOPSIS
    Builds a single-file setup EXE containing only Patch.exe and the friend-test guide.
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'sandbox\friend-test-setup-package'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path (Get-Location) $OutDir }
$OutDir = [IO.Path]::GetFullPath($OutDir)
$stage = Join-Path $OutDir 'payload'
$setupExe = Join-Path $OutDir 'Isaac-Freund-Test-Setup.exe'
. (Join-Path $PSScriptRoot 'find-vcvars.ps1')
$vcvars = Find-VcVars32
$patcherSource = Join-Path $repo 'tool\RgonOnlineUnlock.cpp'
$installerSource = Join-Path $repo 'tool\FriendTestSetup.cpp'
$guideSource = Join-Path $repo 'setup-freundestest-de.txt'
$modsyncSource = Join-Path $repo 'tools\modsync.py'

if ([string]::IsNullOrWhiteSpace($vcvars)) { throw 'vcvars32.bat nicht gefunden (Visual Studio C++-Toolchain fehlt).' }
if (-not (Test-Path -LiteralPath $vcvars)) { throw "vcvars32.bat nicht gefunden: $vcvars" }
if (-not (Test-Path -LiteralPath $patcherSource)) { throw "Patch-Quelle fehlt: $patcherSource" }
if (-not (Test-Path -LiteralPath $installerSource)) { throw "Setup-Quelle fehlt: $installerSource" }
if (-not (Test-Path -LiteralPath $guideSource)) { throw "Anleitung fehlt: $guideSource" }
if (-not (Test-Path -LiteralPath $modsyncSource)) { throw "Mod-PrÃ¼fer fehlt: $modsyncSource" }
if ((Test-Path -LiteralPath $setupExe) -and -not $Force) {
    throw "Ausgabedatei existiert bereits; wird nicht Ã¼berschrieben: $setupExe (mit -Force ausdrÃ¼cklich ersetzen)"
}

New-Item -ItemType Directory -Force -Path $stage | Out-Null
& (Join-Path $PSScriptRoot 'build-gui.ps1') -Out $stage -Src $patcherSource
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Patch.exe-Build fehlgeschlagen ($LASTEXITCODE)." }

$patcher = Join-Path $stage 'RgonOnlineUnlock.exe'
if (-not (Test-Path -LiteralPath $patcher)) { throw "Gebauter Patch-Manager fehlt: $patcher" }
Copy-Item -LiteralPath $patcher -Destination (Join-Path $stage 'Patch.exe')
Copy-Item -LiteralPath $guideSource -Destination (Join-Path $stage 'setup-freundestest-de.txt')
Copy-Item -LiteralPath $modsyncSource -Destination (Join-Path $stage 'modsync.py')

$resourceFile = Join-Path $stage 'FriendTestSetup.rc'
@'
#include <windows.h>
#define IDR_PATCHER 101
#define IDR_GUIDE 102
#define IDR_MODSYNC 103
IDR_PATCHER RCDATA "Patch.exe"
IDR_GUIDE RCDATA "setup-freundestest-de.txt"
IDR_MODSYNC RCDATA "modsync.py"

VS_VERSION_INFO VERSIONINFO
 FILEVERSION 0,0,2,0
 PRODUCTVERSION 0,0,2,0
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0
 FILEOS 0x40004L
 FILETYPE 0x1L
 FILESUBTYPE 0
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "040904B0"
        BEGIN
            VALUE "CompanyName", "Experimental community tool\0"
            VALUE "FileDescription", "Isaac REPENTOGON Friend Test Setup\0"
            VALUE "FileVersion", "0.0.2.0\0"
            VALUE "InternalName", "Isaac-Freund-Test-Setup\0"
            VALUE "OriginalFilename", "Isaac-Freund-Test-Setup.exe\0"
            VALUE "ProductName", "Isaac REPENTOGON Friend Test\0"
            VALUE "ProductVersion", "0.0.2\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
'@ | Set-Content -LiteralPath $resourceFile -Encoding ASCII

$cmd = @(
    "call `"$vcvars`" >nul",
    "cd /d `"$stage`"",
    'rc /nologo FriendTestSetup.rc',
    "cl /nologo /W4 /O2 /MT /EHsc /utf-8 /DUNICODE /D_UNICODE `"$installerSource`" FriendTestSetup.res /Fo:`"$stage\FriendTestSetup.obj`" /Fe:`"$setupExe`" /link /SUBSYSTEM:WINDOWS /MANIFEST:EMBED /MANIFESTUAC:`"level='asInvoker' uiAccess='false'`" user32.lib gdi32.lib shell32.lib ole32.lib comctl32.lib"
) -join ' && '
cmd.exe /c $cmd
if ($LASTEXITCODE -ne 0) { throw "Setup-EXE-Build fehlgeschlagen (Exit $LASTEXITCODE)." }

$setup = Get-Item -LiteralPath $setupExe
$hash = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash
Write-Host "Fertig: $($setup.FullName) ($([Math]::Round($setup.Length / 1KB)) KB)"
Write-Host "SHA256: $hash"
Write-Host 'Paketinhalt: Patch.exe + modsync.py + Test-Anleitung. Keine Isaac-/REPENTOGON-Binaries oder Mods eingebettet.'
