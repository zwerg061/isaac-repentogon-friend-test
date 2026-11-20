<#
.SYNOPSIS
    Permanent, one-click activation and complete removal of the Isaac ModSync
    REPENTOGON patch. Used by Isaac-Freund-Test-Setup.exe and the mod launcher.

.DESCRIPTION
    Apply    - ensure REPENTOGON is installed, back up zhlREPENTOGON.dll once as
               zhlREPENTOGON.dll.orig (SHA-256 verified), install our patched DLL,
               start a hidden companion and launch Isaac without a launcher window.
    Uninstall- stop the companion, restore the exact original DLL (or remove a
               REPENTOGON installation created by us), remove helper mods, registry
               entry, Start menu shortcut and the state file.
    Status   - report the current state as JSON.

    No game is touched unless -Action Apply or -Action Uninstall is used.
    Save files (save*.dat) are never copied, moved or deleted.
#>
param(
    [ValidateSet('Apply', 'Uninstall', 'Status')]
    [string]$Action = 'Status',
    [string]$IsaacRoot,
    [string]$ToolsRoot = $PSScriptRoot,
    [string]$PatchedDll,
    [string]$CompanionExe,
    [string]$LauncherExe,
    [switch]$NoLaunch,
    [switch]$NoCompanion,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
# Hidden automation hooks (used by the GUI fixture tests).
if ($env:ISAAC_MODSYNC_NO_LAUNCH -eq '1') { $NoLaunch = $true; $NoCompanion = $true }
$script:LogPath = if ($env:ISAAC_MODSYNC_LOG_PATH) { $env:ISAAC_MODSYNC_LOG_PATH } else { Join-Path $env:LOCALAPPDATA 'IsaacModSync\install.log' }
function Write-InstallLog([string]$Text) {
    try {
        $dir = Split-Path -Parent $script:LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1}" -f [DateTime]::UtcNow.ToString('o'), $Text) -Encoding UTF8
    } catch { }
}
$script:StatePath = Join-Path $env:LOCALAPPDATA 'IsaacModSync\permanent-patch.json'
$script:UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\IsaacModSyncFriendTest'
$script:StartMenuFolder = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Isaac ModSync Friend Test'
$script:CompanionName = 'SteamModProfileBridge.exe'
$script:RepentogonApi = 'https://api.github.com/repos/TeamREPENTOGON/REPENTOGON/releases/latest'

function Write-Log([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
    Write-InstallLog $Message
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Stop-GameProcesses {
    # A running game or its launcher holds zhlREPENTOGON.dll open. Stop them
    # before any file is replaced so Windows cannot deny the write.
    foreach ($name in @('isaac-ng', 'REPENTOGONLauncher')) {
        $running = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($process in $running) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Write-Log "$name (PID $($process.Id)) beendet."
            } catch {
                Write-Log "$name (PID $($process.Id)) konnte nicht beendet werden: $($_.Exception.Message)"
            }
        }
    }
}

function Clear-ReadOnly([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
            [IO.File]::SetAttributes($Path, ($attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            Write-Log "ReadOnly entfernt: $Path"
        }
    } catch {
        Write-Log "ReadOnly konnte nicht entfernt werden: $Path - $($_.Exception.Message)"
    }
}

function Invoke-WithRetry([scriptblock]$Action, [string]$Description) {
    # Defender/Sophos can hold a freshly written DLL for a few hundred ms.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            & $Action
            return
        } catch {
            if ($attempt -eq 5) {
                throw "FEHLER nach 5 Versuchen bei $Description : $($_.Exception.Message)"
            }
            Write-Log "Retry $attempt/5 bei $Description : $($_.Exception.Message)"
            Start-Sleep -Milliseconds 250
        }
    }
}

function New-OldPath([string]$Path) {
    return "$Path.old.$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))"
}

function Remove-StaleOldFiles([string]$Directory) {
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.old.*' } |
        ForEach-Object {
            try {
                Clear-ReadOnly $_.FullName
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                Write-Log "Veraltete .old-Datei entfernt: $($_.FullName)"
            } catch {
                Write-Log "Veraltete .old-Datei bleibt bis zum naechsten Lauf: $($_.FullName)"
            }
        }
}

function Rename-ExistingFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $old = New-OldPath $Path
    # A rename is permitted on files a scanner currently holds open, unlike an
    # in-place overwrite - this is the core fix for the remaining access denied.
    Invoke-WithRetry {
        Clear-ReadOnly $Path
        [IO.File]::Move($Path, $old)
        if (-not (Test-Path -LiteralPath $old -PathType Leaf)) { throw "Umbenennung nicht sichtbar: $old" }
    } "Umbenennen von $Path"
    Write-Log "Bestehende Datei umbenannt: $old"
    return $old
}

function Restore-OldFile([string]$Old, [string]$Destination) {
    if (-not $Old -or -not (Test-Path -LiteralPath $Old -PathType Leaf)) { return }
    Invoke-WithRetry {
        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            Clear-ReadOnly $Destination
            Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop
        }
        [IO.File]::Move($Old, $Destination)
    } "Wiederherstellen von $Destination"
}

function Remove-OldFile([string]$Old) {
    if ($Old -and (Test-Path -LiteralPath $Old -PathType Leaf)) {
        try {
            Clear-ReadOnly $Old
            Remove-Item -LiteralPath $Old -Force -ErrorAction Stop
        } catch {
            Write-Log "Alte Datei bleibt fuer den naechsten Lauf: $Old"
        }
    }
}

function Copy-FileWithRetry([string]$Source, [string]$Destination) {
    $old = Rename-ExistingFile $Destination
    try {
        Invoke-WithRetry {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            if ((Get-Sha256 $Destination) -ne (Get-Sha256 $Source)) {
                throw "Hash-Mismatch nach dem Kopieren: $Destination"
            }
        } "Kopieren nach $Destination"
    } catch {
        Restore-OldFile $old $Destination
        throw
    }
    Remove-OldFile $old
}

function Get-NormalizedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Find-IsaacRoot {
    param([string]$Override)
    if (-not $Override -and $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT) {
        $Override = $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT
    }
    if ($Override) {
        $candidate = Get-NormalizedPath $Override
        if (Test-Path -LiteralPath (Join-Path $candidate 'isaac-ng.exe') -PathType Leaf) { return $candidate }
        throw "Kein isaac-ng.exe unter $candidate gefunden."
    }
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
    } catch { $steam = $null }
    if (-not $steam) {
        try { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch { $steam = $null }
    }
    $roots = @()
    if ($steam) {
        $roots += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            foreach ($line in (Get-Content -LiteralPath $vdf)) {
                if ($line -match '^\s*"path"\s+"([^"]+)"') {
                    $roots += ($Matches[1] -replace '\\\\', '\')
                }
            }
        }
    }
    foreach ($root in $roots) {
        foreach ($name in @('The Binding of Isaac Rebirth', 'The Binding of Isaac Afterbirth+', 'The Binding of Isaac Repentance', 'The Binding of Isaac Repentance+')) {
            $candidate = Join-Path (Join-Path (Join-Path $root 'steamapps') 'common') $name
            if (Test-Path -LiteralPath (Join-Path $candidate 'isaac-ng.exe') -PathType Leaf) { return (Get-NormalizedPath $candidate) }
        }
    }
    throw 'Steam-Isaac-Installation nicht gefunden. Bitte -IsaacRoot angeben.'
}

function Get-RepentogonDllPath([string]$Root) {
    foreach ($candidate in @((Join-Path $Root 'zhlREPENTOGON.dll'), (Join-Path $Root 'Repentogon\zhlREPENTOGON.dll'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Test-RepentogonInstalled([string]$Root) {
    $dll = Get-RepentogonDllPath $Root
    if (-not $dll) { return $false }
    $folder = Split-Path -Parent $dll
    foreach ($required in @('zhlLoader.dll', 'libzhl.dll', 'resources\scripts\main_ex.lua')) {
        if (-not (Test-Path -LiteralPath (Join-Path $folder $required) -PathType Leaf)) { return $false }
    }
    return $true
}

function Save-State($State) {
    $dir = Split-Path -Parent $script:StatePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Clear-ReadOnly $script:StatePath
    [IO.File]::WriteAllText($script:StatePath, ($State | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Read-State {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { throw "Statusdatei unlesbar: $script:StatePath" }
}

function Get-SafeZipPath([string]$Name) {
    $normalized = $Name.Replace('\', '/')
    if ($normalized.StartsWith('/')) { return $null }
    $parts = @()
    foreach ($part in $normalized.Split('/')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') { continue }
        if ($part -eq '..' -or $part.Contains(':')) { return $null }
        $parts += $part
    }
    if ($parts.Count -eq 0) { return $null }
    return (Join-Path $Root ($parts -join '\'))
}

function Install-Repentogon([string]$Root) {
    $fixtureZip = $env:ISAAC_MODSYNC_TEST_REPENTOGON_ZIP
    $skipDownload = $false
    if ($fixtureZip -and (Test-Path -LiteralPath $fixtureZip -PathType Leaf)) {
        # Hidden automation hook: fixture tests provide a local REPENTOGON.zip.
        $zipPath = $fixtureZip
        $release = [pscustomobject]@{ tag_name = 'fixture' }
        $skipDownload = $true
    } else {
        Write-Log 'REPENTOGON fehlt - lade offizielles Release ...'
        $ProgressPreference = 'SilentlyContinue'
        $release = Invoke-RestMethod -Uri $script:RepentogonApi -Headers @{ 'User-Agent' = 'isaac-mod-launcher' }
        $asset = $release.assets | Where-Object { $_.name -eq 'REPENTOGON.zip' } | Select-Object -First 1
        if (-not $asset) { $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1 }
        if (-not $asset) { throw 'REPENTOGON-Release enthaelt kein ZIP.' }
        $zipPath = Join-Path ([IO.Path]::GetTempPath()) ('isaac-rgon-' + [Guid]::NewGuid().ToString('N') + '.zip')
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $installed = @()
    try {
        foreach ($entry in $archive.Entries) {
            $relative = Get-SafeZipPath $entry.FullName
            if (-not $relative) { continue }
            if ($entry.FullName.EndsWith('/')) {
                New-Item -ItemType Directory -Force -Path $relative | Out-Null
                continue
            }
            $parent = Split-Path -Parent $relative
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $target = $relative
            $old = Rename-ExistingFile $target
            try {
                Invoke-WithRetry {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
                } "Entpacken von $target"
            } catch {
                Restore-OldFile $old $target
                throw
            }
            Remove-OldFile $old
            $installed += ($relative.Substring($Root.Length).TrimStart('\'))
        }
    } finally {
        $archive.Dispose()
        if (-not $skipDownload) { Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue }
    }
    if (-not (Test-RepentogonInstalled $Root)) { throw 'REPENTOGON-Installation nach dem Entpacken unvollstaendig.' }
    Write-Log "REPENTOGON $($release.tag_name) installiert."
    return ,$installed
}

function Stop-Companion {
    $processes = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq $script:CompanionName -or
        ($_.CommandLine -and $_.CommandLine -like "*$script:CompanionName*")
    })
    foreach ($proc in $processes) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Log "Companion beendet (PID $($proc.ProcessId))."
        } catch { Write-Log "Companion PID $($proc.ProcessId) konnte nicht beendet werden: $($_.Exception.Message)" }
    }
}

function Start-CompanionHidden([string]$Root, [int]$GamePid) {
    if ($NoCompanion -or $GamePid -le 0) { return }
    $exe = if ($CompanionExe) { $CompanionExe } else { Join-Path $ToolsRoot $script:CompanionName }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Write-Log "Companion fehlt: $exe"; return }
    $log = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\log.txt'
    $args = @('--mode', 'inspect', '--isaac-root', "`"$Root`"", '--game-pid', "$GamePid", '--log', "`"$log`"", '--timeout', '86400')
    Start-Process -FilePath $exe -ArgumentList $args -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    Write-Log 'Companion im Hintergrund gestartet.'
}

function Show-GameWindow([int]$GamePid) {
    if ($GamePid -le 0) { return }
    if (-not ('Win32Window' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Win32Window {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
}
'@
    }
    [Win32Window]::EnumWindows({ param($hWnd, $lParam)
        $pid = 0
        [void][Win32Window]::GetWindowThreadProcessId($hWnd, [ref]$pid)
        if ($pid -eq $GamePid) { [void][Win32Window]::ShowWindow($hWnd, 5) }
        return $true
    }, [IntPtr]::Zero) | Out-Null
}

function Start-IsaacDirect([string]$Root, [string]$Launcher) {
    if ($NoLaunch) { return 0 }
    $gameExe = Join-Path $Root 'isaac-ng.exe'
    $launcherExe = if ($Launcher) { $Launcher } elseif (Test-Path -LiteralPath 'E:\REPENTOGONLauncher\REPENTOGONLauncher.exe') { 'E:\REPENTOGONLauncher\REPENTOGONLauncher.exe' } else { $null }
    if (-not $launcherExe -or -not (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
        Write-Log 'Kein REPENTOGON-Launcher gefunden - starte isaac-ng.exe direkt.'
        $proc = Start-Process -FilePath $gameExe -WorkingDirectory $Root -PassThru
        return $proc.Id
    }
    # Der Launcher injiziert zhlLoader.dll in einen suspendierten Prozess.
    # --stealth-mode verhindert sein Zwischenfenster; das Spiel wird danach sichtbar gemacht.
    $config = Join-Path $env:TEMP ('isaac-modsync-launcher-' + [Guid]::NewGuid().ToString('N') + '.ini')
    @"
[General]
IsaacExecutable = $gameExe
RanWizard = 1
HideWindow = 1
StealthMode = 1
[Repentogon]
Console = 0
Update = 0
UnstableUpdates = 0
[Vanilla]
LuaDebug = 0
[Shared]
LaunchMode = 0
"@ | Set-Content -LiteralPath $config -Encoding ASCII
    $arguments = @('--isaac', "`"$gameExe`"", '--launch-mode', 'repentogon', '--stealth-mode',
        '--skip-wizard', '--skip-repentogon-update', '--skip-unique', '--configuration-file', "`"$config`"")
    $proc = Start-Process -FilePath $launcherExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $game = @(Get-Process -Name 'isaac-ng' -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($game) { Start-Sleep -Milliseconds 1200; Show-GameWindow $game.Id; return $game.Id }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 400
    }
    throw 'Spielstart ueber den versteckten Launcher fehlgeschlagen.'
}

function Register-Uninstall([string]$SetupExe) {
    if (-not (Test-Path -LiteralPath $SetupExe -PathType Leaf)) { return }
    New-Item -Path $script:UninstallKey -Force | Out-Null
    Set-ItemProperty -Path $script:UninstallKey -Name DisplayName -Value 'Isaac ModSync Friend Test (REPENTOGON patch)'
    Set-ItemProperty -Path $script:UninstallKey -Name DisplayVersion -Value '0.0.8'
    Set-ItemProperty -Path $script:UninstallKey -Name Publisher -Value 'Experimental community tool'
    Set-ItemProperty -Path $script:UninstallKey -Name UninstallString -Value "`"$SetupExe`" --uninstall"
    Set-ItemProperty -Path $script:UninstallKey -Name QuietUninstallString -Value "`"$SetupExe`" --uninstall"
    Set-ItemProperty -Path $script:UninstallKey -Name DisplayIcon -Value $SetupExe
    try {
        New-Item -ItemType Directory -Force -Path $script:StartMenuFolder | Out-Null
        $shortcut = Join-Path $script:StartMenuFolder 'ModSync abschalten & deinstallieren.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut($shortcut)
        $link.TargetPath = $SetupExe
        $link.Arguments = '--uninstall'
        $link.Description = 'Isaac ModSync Patch deaktivieren und Originaldateien wiederherstellen'
        $link.Save()
    } catch { Write-Log "Startmenue-Verknuepfung nicht erstellt: $($_.Exception.Message)" }
}

function Unregister-Uninstall {
    if (Test-Path -LiteralPath $script:UninstallKey) { Remove-Item -LiteralPath $script:UninstallKey -Recurse -Force }
    if (Test-Path -LiteralPath $script:StartMenuFolder) { Remove-Item -LiteralPath $script:StartMenuFolder -Recurse -Force }
}

function Remove-HelperMods([string]$Root) {
    foreach ($base in @((Join-Path $Root 'mods'), (Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\data'))) {
        if (-not (Test-Path -LiteralPath $base -PathType Container)) { continue }
        if ((Get-Item -LiteralPath $base -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'zz_modsync*' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; Write-Log "Helper-Mod entfernt: $($_.FullName)" }
    }
}

function Invoke-Apply {
    $root = Get-NormalizedPath (Find-IsaacRoot $IsaacRoot)
    Remove-StaleOldFiles $root
    Stop-GameProcesses
    $patched = if ($PatchedDll) { [IO.Path]::GetFullPath($PatchedDll) } else { Join-Path $ToolsRoot 'zhlREPENTOGON.dll' }
    if (-not (Test-Path -LiteralPath $patched -PathType Leaf)) { throw "Gepatchte DLL fehlt: $patched" }
    $patchedHash = Get-Sha256 $patched
    $installedByUs = @()
    if (-not (Test-RepentogonInstalled $root)) { $installedByUs = @(Install-Repentogon $root) }
    $dll = Get-RepentogonDllPath $root
    if (-not $dll) { throw 'zhlREPENTOGON.dll fehlt nach der REPENTOGON-Installation.' }
    $backup = "$dll.orig"
    $currentHash = Get-Sha256 $dll
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        Copy-FileWithRetry $dll $backup
        if ((Get-Sha256 $backup) -ne $currentHash) { throw 'Sicherung der Original-DLL fehlgeschlagen (Hash-Mismatch).' }
        Write-Log "Original-DLL gesichert: $backup"
    }
    $originalHash = Get-Sha256 $backup
    if ($currentHash -ne $patchedHash) {
        Copy-FileWithRetry $patched $dll
        if ((Get-Sha256 $dll) -ne $patchedHash) { throw 'Gepatchte DLL konnte nicht verifiziert werden.' }
    }
    $state = [ordered]@{
        schema_version = 1
        applied = $true
        isaac_root = $root
        dll_path = $dll
        backup_path = $backup
        original_dll_sha256 = $originalHash
        patched_dll_sha256 = $patchedHash
        repentogon_installed_by_us = ($installedByUs.Count -gt 0)
        installed_files = @($installedByUs)
        companion_path = if ($CompanionExe) { $CompanionExe } else { Join-Path $ToolsRoot $script:CompanionName }
        applied_utc = [DateTime]::UtcNow.ToString('o')
    }
    Save-State $state
    Register-Uninstall (Join-Path $ToolsRoot 'Isaac-Freund-Test-Setup.exe')
    Write-Log 'Online-Patch dauerhaft aktiviert.'
    $gamePid = Start-IsaacDirect $root $LauncherExe
    Start-CompanionHidden $root $gamePid
    $state | ConvertTo-Json -Depth 8
}

function Invoke-Uninstall {
    $state = Read-State
    $root = if ($state -and $state.isaac_root) { $state.isaac_root } else { try { Find-IsaacRoot $IsaacRoot } catch { $null } }
    Remove-StaleOldFiles $root
    Stop-GameProcesses
    Stop-Companion
    if ($state -and $state.repentogon_installed_by_us -and $root) {
        # REPENTOGON war vorher nicht vorhanden: exakter Urzustand = keine RGON-Dateien.
        foreach ($relative in @($state.installed_files)) {
            if (-not $relative -or $relative -like 'save*.dat') { continue }
            $path = Join-Path $root $relative
            if (Test-Path -LiteralPath $path -PathType Leaf) { Clear-ReadOnly $path; Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        }
        if ($state.backup_path -and (Test-Path -LiteralPath $state.backup_path -PathType Leaf)) {
            Clear-ReadOnly $state.backup_path
            Remove-Item -LiteralPath $state.backup_path -Force -ErrorAction SilentlyContinue
        }
        Write-Log 'Von uns installierte REPENTOGON-Dateien entfernt (Urzustand wiederhergestellt).'
    } elseif ($state -and $state.dll_path -and $state.backup_path -and (Test-Path -LiteralPath $state.backup_path -PathType Leaf)) {
        $backupHash = Get-Sha256 $state.backup_path
        if ($backupHash -ne $state.original_dll_sha256) { throw 'Gesicherte Original-DLL hat unerwarteten Hash - Abbruch.' }
        $target = $state.dll_path
        $currentHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-Sha256 $target } else { $null }
        if ($currentHash -ne $backupHash) {
            Copy-FileWithRetry $state.backup_path $target
            if ((Get-Sha256 $target) -ne $backupHash) { throw 'Original-DLL konnte nicht wiederhergestellt werden.' }
        }
        Clear-ReadOnly $state.backup_path
        Remove-Item -LiteralPath $state.backup_path -Force
        Write-Log 'Original-DLL exakt wiederhergestellt.'
    }
    if ($root) { Remove-HelperMods $root }
    Unregister-Uninstall
    if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    Write-Log 'Online-Patch deaktiviert und deinstalliert.'
    @{ applied = $false; isaac_root = $root } | ConvertTo-Json
}

function Invoke-Status {
    $state = Read-State
    if (-not $state) { return @{ applied = $false; state_path = $script:StatePath } }
    return @{
        applied = [bool]$state.applied
        isaac_root = $state.isaac_root
        original_dll_sha256 = $state.original_dll_sha256
        patched_dll_sha256 = $state.patched_dll_sha256
        state_path = $script:StatePath
    }
}

try {
    switch ($Action) {
        'Apply' { Invoke-Apply }
        'Uninstall' { Invoke-Uninstall }
        'Status' { Invoke-Status | ConvertTo-Json -Compress -Depth 8 }
    }
} catch {
    $message = ($_ | Out-String).Trim()
    Write-InstallLog ("FEHLER [{0}]: {1}" -f $Action, $message)
    [Console]::Error.WriteLine($message)
    throw
}
