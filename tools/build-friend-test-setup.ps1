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
$sessionSource = Join-Path $PSScriptRoot 'Run-TempModProfile.ps1'
$resyncSource = Join-Path $PSScriptRoot 'Resync-ProfileAndSaveData.ps1'
$bridgeSource = Join-Path $repo 'tool\SteamModProfileBridge.cpp'
$versionSource = Join-Path $repo 'VERSION'
$patchedDllSource = Join-Path $repo 'artifacts-v0.0.16\zhlREPENTOGON.dll'
$loaderSource = Join-Path $repo 'artifacts-v0.0.16\zhlLoader.dll'
$libZhlSource = Join-Path $repo 'artifacts-v0.0.16\libzhl.dll'
$installScriptSource = Join-Path $PSScriptRoot 'Install-ModSyncPatch.ps1'

$version = '0.0.6'
if (Test-Path -LiteralPath $versionSource -PathType Leaf) {
    $candidate = (Get-Content -LiteralPath $versionSource -Raw).Trim()
    if ($candidate -match '^\d+\.\d+\.\d+$') { $version = $candidate }
}
$versionParts = $version.Split('.')
$versionComma = ($versionParts -join ',')

if ([string]::IsNullOrWhiteSpace($vcvars)) { throw 'vcvars32.bat nicht gefunden (Visual Studio C++-Toolchain fehlt).' }
if (-not (Test-Path -LiteralPath $vcvars)) { throw "vcvars32.bat nicht gefunden: $vcvars" }
if (-not (Test-Path -LiteralPath $patcherSource)) { throw "Patch-Quelle fehlt: $patcherSource" }
if (-not (Test-Path -LiteralPath $installerSource)) { throw "Setup-Quelle fehlt: $installerSource" }
if (-not (Test-Path -LiteralPath $guideSource)) { throw "Anleitung fehlt: $guideSource" }
if (-not (Test-Path -LiteralPath $modsyncSource)) { throw "Mod-PrÃ¼fer fehlt: $modsyncSource" }
if (-not (Test-Path -LiteralPath $sessionSource)) { throw "Temp-Mod-Session-Runner fehlt: $sessionSource" }
if (-not (Test-Path -LiteralPath $resyncSource)) { throw "Desync-Resync-Skript fehlt: $resyncSource" }
if (-not (Test-Path -LiteralPath $bridgeSource)) { throw "Steam-P2P-Companion-Quelle fehlt: $bridgeSource" }
if (-not (Test-Path -LiteralPath $versionSource)) { throw "VERSION fehlt: $versionSource" }
if (-not (Test-Path -LiteralPath $patchedDllSource -PathType Leaf)) { throw "Gepatchte REPENTOGON-DLL fehlt: $patchedDllSource" }
if (-not (Test-Path -LiteralPath $loaderSource -PathType Leaf)) { throw "zhlLoader.dll fehlt: $loaderSource" }
if (-not (Test-Path -LiteralPath $libZhlSource -PathType Leaf)) { throw "libzhl.dll fehlt: $libZhlSource" }
if (-not (Test-Path -LiteralPath $installScriptSource -PathType Leaf)) { throw "Installationsskript fehlt: $installScriptSource" }
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
Copy-Item -LiteralPath $sessionSource -Destination (Join-Path $stage 'Run-TempModProfile.ps1')
Copy-Item -LiteralPath $resyncSource -Destination (Join-Path $stage 'Resync-ProfileAndSaveData.ps1')
Copy-Item -LiteralPath $versionSource -Destination (Join-Path $stage 'VERSION')
Copy-Item -LiteralPath $patchedDllSource -Destination (Join-Path $stage 'zhlREPENTOGON.dll')
Copy-Item -LiteralPath $loaderSource -Destination (Join-Path $stage 'zhlLoader.dll')
Copy-Item -LiteralPath $libZhlSource -Destination (Join-Path $stage 'libzhl.dll')
Copy-Item -LiteralPath $installScriptSource -Destination (Join-Path $stage 'Install-ModSyncPatch.ps1')
$bridgeExe = Join-Path $stage 'SteamModProfileBridge.exe'
$bridgeObj = Join-Path $stage 'SteamModProfileBridge.obj'
$bridgeRc = Join-Path $stage 'SteamModProfileBridge.rc'
@"
#include <windows.h>
#define IDD_DESYNC_ASSISTANT 200
#define IDC_DESYNC_REASON 1001
#define IDC_DESYNC_DETAIL 1002
#define IDC_DESYNC_AFFECTED 1003
#define IDC_RESYNC 1004
#define IDC_DISMISS 1005
IDD_DESYNC_ASSISTANT DIALOGEX 0, 0, 360, 210
STYLE DS_MODALFRAME | WS_POPUP | WS_CAPTION | WS_SYSMENU
CAPTION "Isaac Desync Assistant"
FONT 9, "Segoe UI"
BEGIN
    LTEXT "Grund:", -1, 10, 10, 80, 12
    LTEXT "", IDC_DESYNC_REASON, 95, 10, 250, 24
    LTEXT "Details:", -1, 10, 40, 80, 12
    LTEXT "", IDC_DESYNC_DETAIL, 95, 40, 250, 50
    LTEXT "Betroffen:", -1, 10, 96, 80, 12
    LTEXT "", IDC_DESYNC_AFFECTED, 95, 96, 250, 20
    LTEXT "Fix: Profil und isoliertes SaveData neu aufbauen.", -1, 10, 126, 335, 20
    DEFPUSHBUTTON "Profil & SaveData neu synchronisieren", IDC_RESYNC, 10, 160, 205, 24
    PUSHBUTTON "Abbrechen", IDC_DISMISS, 225, 160, 120, 24
END
VS_VERSION_INFO VERSIONINFO
  FILEVERSION $versionComma,0
  PRODUCTVERSION $versionComma,0
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
            VALUE "FileVersion", "$version.0\0"
            VALUE "InternalName", "SteamModProfileBridge\0"
            VALUE "OriginalFilename", "SteamModProfileBridge.exe\0"
            VALUE "ProductName", "Isaac REPENTOGON ModSync Companion\0"
            VALUE "ProductVersion", "$version\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@ | Set-Content -LiteralPath $bridgeRc -Encoding ASCII
$bridgeCmd = @(
    "call `"$vcvars`" >nul",
    "cd /d `"$stage`"",
    'rc /nologo SteamModProfileBridge.rc',
    "cl /nologo /W4 /O2 /MT /EHsc /std:c++17 /utf-8 /DUNICODE /D_UNICODE `"$bridgeSource`" SteamModProfileBridge.res /Fo:`"$bridgeObj`" /Fe:`"$bridgeExe`" /link /SUBSYSTEM:CONSOLE /MANIFEST:EMBED /MANIFESTUAC:`"level='asInvoker' uiAccess='false'`""
) -join ' && '
cmd.exe /c $bridgeCmd
if ($LASTEXITCODE -ne 0) { throw "Steam-P2P-Companion-Build fehlgeschlagen (Exit $LASTEXITCODE)." }
foreach ($selftest in @('--selftest', '--desync-selftest')) {
    & $bridgeExe $selftest
    if ($LASTEXITCODE -ne 0) { throw "Companion-Selftest $selftest fehlgeschlagen (Exit $LASTEXITCODE)." }
}
$appIdFile = Join-Path $stage 'steam_appid.txt'
[IO.File]::WriteAllText($appIdFile, "250900`r`n", [Text.Encoding]::ASCII)

$resourceFile = Join-Path $stage 'FriendTestSetup.rc'
@"
#include <windows.h>
#define IDR_PATCHER 101
#define IDR_GUIDE 102
#define IDR_MODSYNC 103
#define IDR_SESSION 104
#define IDR_STEAMBRIDGE 105
#define IDR_APPID 106
#define IDR_VERSION 107
#define IDR_RESYNC 108
#define IDR_PATCHED_DLL 109
#define IDR_INSTALL_SCRIPT 110
#define IDR_ZHL_LOADER 111
#define IDR_LIBZHL 112
IDR_PATCHER RCDATA "Patch.exe"
IDR_GUIDE RCDATA "setup-freundestest-de.txt"
IDR_MODSYNC RCDATA "modsync.py"
IDR_SESSION RCDATA "Run-TempModProfile.ps1"
IDR_STEAMBRIDGE RCDATA "SteamModProfileBridge.exe"
IDR_APPID RCDATA "steam_appid.txt"
IDR_VERSION RCDATA "VERSION"
IDR_RESYNC RCDATA "Resync-ProfileAndSaveData.ps1"
IDR_PATCHED_DLL RCDATA "zhlREPENTOGON.dll"
IDR_INSTALL_SCRIPT RCDATA "Install-ModSyncPatch.ps1"
IDR_ZHL_LOADER RCDATA "zhlLoader.dll"
IDR_LIBZHL RCDATA "libzhl.dll"

VS_VERSION_INFO VERSIONINFO
  FILEVERSION $versionComma,0
  PRODUCTVERSION $versionComma,0
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
            VALUE "FileVersion", "$version.0\0"
            VALUE "InternalName", "Isaac-Freund-Test-Setup\0"
            VALUE "OriginalFilename", "Isaac-Freund-Test-Setup.exe\0"
            VALUE "ProductName", "Isaac REPENTOGON Friend Test\0"
            VALUE "ProductVersion", "$version\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x409, 1200
    END
END
"@ | Set-Content -LiteralPath $resourceFile -Encoding ASCII

$cmd = @(
    "call `"$vcvars`" >nul",
    "cd /d `"$stage`"",
    'rc /nologo FriendTestSetup.rc',
    "cl /nologo /W4 /O2 /MT /EHsc /utf-8 /DUNICODE /D_UNICODE `"$installerSource`" FriendTestSetup.res /Fo:`"$stage\FriendTestSetup.obj`" /Fe:`"$setupExe`" /link /SUBSYSTEM:WINDOWS /MANIFEST:EMBED /MANIFESTUAC:`"level='asInvoker' uiAccess='false'`" user32.lib gdi32.lib shell32.lib ole32.lib comctl32.lib"
) -join ' && '
cmd.exe /c $cmd
if ($LASTEXITCODE -ne 0) { throw "Setup-EXE-Build fehlgeschlagen (Exit $LASTEXITCODE)." }

if (-not ('IsaacSetupVerifier' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class IsaacSetupVerifier {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LoadResource(IntPtr module, IntPtr info);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr LockResource(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SizeofResource(IntPtr module, IntPtr info);
}
'@
}

function Read-EmbeddedResource([IntPtr]$Module, [int]$Type, [int]$Id) {
    $info = [IsaacSetupVerifier]::FindResource($Module, [IntPtr]$Id, [IntPtr]$Type)
    if ($info -eq [IntPtr]::Zero) { return $null }
    $handle = [IsaacSetupVerifier]::LoadResource($Module, $info)
    if ($handle -eq [IntPtr]::Zero) { return $null }
    $pointer = [IsaacSetupVerifier]::LockResource($handle)
    $size = [IsaacSetupVerifier]::SizeofResource($Module, $info)
    if ($pointer -eq [IntPtr]::Zero -or $size -eq 0) { return $null }
    $bytes = New-Object byte[] ([int]$size)
    [Runtime.InteropServices.Marshal]::Copy($pointer, $bytes, 0, [int]$size)
    return $bytes
}

function Assert-AsInvoker([string]$ExePath) {
    $module = [IsaacSetupVerifier]::LoadLibraryEx($ExePath, [IntPtr]::Zero, 0x2)
    if ($module -eq [IntPtr]::Zero) { throw "EXE konnte nicht als Datenmodul geladen werden: $ExePath" }
    try {
        $manifest = Read-EmbeddedResource $module 24 1
        if (-not $manifest) { $manifest = Read-EmbeddedResource $module 24 2 }
        if (-not $manifest) { throw "Kein eingebettetes Manifest gefunden: $ExePath" }
        $text = [Text.Encoding]::UTF8.GetString($manifest)
        if ($text -notmatch 'level\s*=\s*["'']asInvoker["'']') { throw "asInvoker fehlt im Manifest: $ExePath" }
    } finally {
        [IsaacSetupVerifier]::FreeLibrary($module) | Out-Null
    }
}

Assert-AsInvoker $setupExe
Assert-AsInvoker $bridgeExe

$sha = [Security.Cryptography.SHA256]::Create()
$module = [IsaacSetupVerifier]::LoadLibraryEx($setupExe, [IntPtr]::Zero, 0x2)
if ($module -eq [IntPtr]::Zero) { throw "Setup-EXE konnte nicht verifiziert werden: $setupExe" }
try {
    $payload = @(
        @(101, 'Patch.exe'),
        @(102, 'setup-freundestest-de.txt'),
        @(103, 'modsync.py'),
        @(104, 'Run-TempModProfile.ps1'),
        @(105, 'SteamModProfileBridge.exe'),
        @(106, 'steam_appid.txt'),
        @(107, 'VERSION'),
        @(108, 'Resync-ProfileAndSaveData.ps1'),
        @(109, 'zhlREPENTOGON.dll'),
        @(110, 'Install-ModSyncPatch.ps1'),
        @(111, 'zhlLoader.dll'),
        @(112, 'libzhl.dll')
    )
    foreach ($item in $payload) {
        $embedded = Read-EmbeddedResource $module 10 ([int]$item[0])
        if (-not $embedded) { throw "Eingebettete Ressource fehlt: $($item[1])" }
        $embeddedHash = [BitConverter]::ToString($sha.ComputeHash($embedded)).Replace('-', '')
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $stage $item[1]) -Algorithm SHA256).Hash
        if ($embeddedHash -ne $sourceHash) { throw "Hash-Mismatch fuer $($item[1]): $embeddedHash != $sourceHash" }
        Write-Host "  Hash OK: $($item[1]) ($embeddedHash)"
    }
} finally {
    [IsaacSetupVerifier]::FreeLibrary($module) | Out-Null
}

$setup = Get-Item -LiteralPath $setupExe
$hash = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash
Write-Host "Fertig: $($setup.FullName) ($([Math]::Round($setup.Length / 1KB)) KB)"
Write-Host "SHA256 (Setup): $hash"
Write-Host "Version: $version | asInvoker: verifiziert | eingebettete Hashes: verifiziert"
Write-Host 'Paketinhalt: Patch.exe + modsync.py + Temp-Runner + Resync-Skript + Steam-P2P-Companion/Desync-Assistant + VERSION + verifizierte gepatchte zhlREPENTOGON.dll. Keine Spiel-EXE, keine Mods, keine Saves, keine Steam API DLLs.'
