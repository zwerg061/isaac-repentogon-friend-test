# UI automation fixture test for Isaac-Freund-Test-Setup.exe v0.0.9.
# Clicks real Win32 buttons with BM_CLICK - no screenshots, no real game files.
$ErrorActionPreference = 'Stop'

$setup = 'G:\Coode\the binding of isaac\multyplayer modet\sandbox\release-v0.0.1\artifacts-v0.0.10\Isaac-Freund-Test-Setup.exe'
if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { throw "Setup fehlt: $setup" }

if (-not ('SetupUi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class SetupUi {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr h, int id);
    [DllImport("user32.dll", EntryPoint="SendMessageW", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessageText(IntPtr h, uint msg, IntPtr w, string text);
    [DllImport("user32.dll", EntryPoint="SendMessageW")]
    public static extern IntPtr SendMessagePtr(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="GetWindowTextW")]
    public static extern int GetWindowText(IntPtr h, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    public delegate bool EnumProc(IntPtr h, IntPtr lParam);
}
'@
}

$BM_CLICK = 0x00F5
$WM_SETTEXT = 0x000C
$WM_GETTEXT = 0x000D
$WM_CLOSE = 0x0010
$IDC_PATH = 1001
$IDC_INSTALL = 1003
$IDC_ACTIVATE = 1007
$IDC_STATUS = 1006

function Wait-Window($Process, [int]$TimeoutSeconds = 20) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $Process.Refresh()
        if ($Process.MainWindowHandle -ne [IntPtr]::Zero) { return $Process.MainWindowHandle }
        Start-Sleep -Milliseconds 150
    }
    throw 'Setup-Fenster nicht erschienen.'
}

function Get-StatusText([IntPtr]$Window) {
    $status = [SetupUi]::GetDlgItem($Window, $IDC_STATUS)
    $buffer = New-Object System.Text.StringBuilder 4096
    [void][SetupUi]::GetWindowText($status, $buffer, $buffer.Capacity)
    return $buffer.ToString()
}

function Set-ToolsPath([IntPtr]$Window, [string]$Path) {
    $edit = [SetupUi]::GetDlgItem($Window, $IDC_PATH)
    [void][SetupUi]::SendMessageText($edit, $WM_SETTEXT, [IntPtr]::Zero, $Path)
}

function Click([IntPtr]$Window, [int]$Id) {
    $control = [SetupUi]::GetDlgItem($Window, $Id)
    if ($control -eq [IntPtr]::Zero) { throw "Control $Id fehlt." }
    [void][SetupUi]::SendMessagePtr($control, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Close-Setup([IntPtr]$Window, $Process) {
    if ($Window -ne [IntPtr]::Zero) { [void][SetupUi]::SendMessagePtr($Window, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
    Start-Sleep -Milliseconds 300
    if ($Process -and -not $Process.HasExited) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue }
}

function New-Fixture([string]$Tag) {
    $fixture = Join-Path ([IO.Path]::GetTempPath()) ("setup-ui-$Tag-" + [Guid]::NewGuid().ToString('N'))
    $isaac = Join-Path $fixture 'isaac'
    $tools = Join-Path $fixture 'tools'
    New-Item -ItemType Directory -Force -Path (Join-Path $isaac 'resources\scripts') | Out-Null
    New-Item -ItemType Directory -Force -Path $tools | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $isaac 'isaac-ng.exe'), [Text.Encoding]::ASCII.GetBytes('fake'))
    [IO.File]::WriteAllBytes((Join-Path $isaac 'zhlLoader.dll'), [Text.Encoding]::ASCII.GetBytes('loader'))
    [IO.File]::WriteAllBytes((Join-Path $isaac 'libzhl.dll'), [Text.Encoding]::ASCII.GetBytes('libzhl'))
    [IO.File]::WriteAllBytes((Join-Path $isaac 'resources\scripts\main_ex.lua'), [Text.Encoding]::ASCII.GetBytes('lua'))
    $original = [Text.Encoding]::ASCII.GetBytes('ORIGINAL-DLL')
    $dll = Join-Path $isaac 'zhlREPENTOGON.dll'
    [IO.File]::WriteAllBytes($dll, $original)
    return @{ Root = $fixture; Isaac = $isaac; Tools = $tools; Dll = $dll; Original = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash }
}

function Start-SetupWithFixture($Fixture) {
    $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT = $Fixture.Isaac
    $env:ISAAC_MODSYNC_NO_LAUNCH = '1'
    $env:LOCALAPPDATA = Join-Path $Fixture.Root 'localappdata'
    $env:APPDATA = Join-Path $Fixture.Root 'appdata'
    $process = Start-Process -FilePath $setup -PassThru
    $window = Wait-Window $process
    return @{ Process = $process; Window = $window }
}

$oldLocal = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
$oldTestRoot = $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT
$oldNoLaunch = $env:ISAAC_MODSYNC_NO_LAUNCH

try {
    # Sequence A: click "Patch aktivieren" directly, without installing first.
    $a = New-Fixture 'direct'
    $run = Start-SetupWithFixture $a
    try {
        Set-ToolsPath $run.Window $a.Tools
        Click $run.Window $IDC_ACTIVATE
        $required = @('Patch.exe','modsync.py','Run-TempModProfile.ps1','SteamModProfileBridge.exe','setup-freundestest-de.txt','zhlREPENTOGON.dll','Install-ModSyncPatch.ps1')
        foreach ($name in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $a.Tools $name) -PathType Leaf)) {
                throw "Direkt-Aktivierung hat Tools nicht installiert: $name"
            }
        }
        $patchedHash = (Get-FileHash -LiteralPath (Join-Path $a.Tools 'zhlREPENTOGON.dll') -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $a.Dll -Algorithm SHA256).Hash -ne $patchedHash) {
            throw 'Direkt-Aktivierung hat die gepatchte DLL nicht eingesetzt.'
        }
        $log = Join-Path $oldLocal 'IsaacModSync\install.log'
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { throw 'install.log fehlt.' }
        Write-Output 'PASS: direkter Klick auf Patch aktivieren installiert Tools und patched'
    } finally { Close-Setup $run.Window $run.Process }

    # Sequence B: click "Installieren" first, then "Patch aktivieren".
    $b = New-Fixture 'install-first'
    $run = Start-SetupWithFixture $b
    try {
        Set-ToolsPath $run.Window $b.Tools
        # "Installieren" shows a success MessageBox; dismiss it from a background job.
        $job = Start-Job -ScriptBlock {
            param($Seconds)
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) {
                Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Dlg { [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c,string n);
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h,uint m,IntPtr w,IntPtr l); }
'@
                $dialog = [Dlg]::FindWindow('#32770', 'Fertig')
                if ($dialog -ne [IntPtr]::Zero) { [void][Dlg]::SendMessage($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero); break }
                Start-Sleep -Milliseconds 100
            }
        } -ArgumentList 25
        Click $run.Window $IDC_INSTALL
        Wait-Job $job -Timeout 30 | Out-Null
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath (Join-Path $b.Tools 'Install-ModSyncPatch.ps1') -PathType Leaf)) {
            throw 'Installieren hat das Patch-Skript nicht abgelegt.'
        }
        Click $run.Window $IDC_ACTIVATE
        $patchedHash = (Get-FileHash -LiteralPath (Join-Path $b.Tools 'zhlREPENTOGON.dll') -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $b.Dll -Algorithm SHA256).Hash -ne $patchedHash) {
            throw 'Klickfolge Installieren -> Aktivieren hat die DLL nicht gepatcht.'
        }
        Write-Output 'PASS: Installieren -> Patch aktivieren funktioniert'
    } finally { Close-Setup $run.Window $run.Process }

    # Error case: a directory where zhlREPENTOGON.dll should be forces a real
    # PowerShell error; the GUI must show the cause and write install.log.
    $c = New-Fixture 'error'
    Remove-Item -LiteralPath $c.Dll -Force
    New-Item -ItemType Directory -Path $c.Dll | Out-Null
    $run = Start-SetupWithFixture $c
    try {
        Set-ToolsPath $run.Window $c.Tools
        Click $run.Window $IDC_ACTIVATE
        $status = Get-StatusText $run.Window
        if ($status -notmatch 'Patch-Aktivierung fehlgeschlagen' -or $status.Length -lt 60) {
            throw "Status zeigt keine echte Fehlerursache: '$status'"
        }
        $log = Join-Path $oldLocal 'IsaacModSync\install.log'
        if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
            Write-Output "DEBUG STATUS=$status"; throw 'install.log fehlt im Fehlerfall.'
        }
        Write-Output "PASS: echte Fehlerursache im Status ($($status.Substring(0, [Math]::Min(120, $status.Length))))"
    } finally { Close-Setup $run.Window $run.Process }

    Write-Output 'ALL setup click-order UI tests passed.'
} finally {
    $env:LOCALAPPDATA = $oldLocal
    $env:APPDATA = $oldAppData
    $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT = $oldTestRoot
    $env:ISAAC_MODSYNC_NO_LAUNCH = $oldNoLaunch
}
