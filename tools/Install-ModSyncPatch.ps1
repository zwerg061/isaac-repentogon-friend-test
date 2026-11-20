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
# Fixed staging root: antivirus users only need one exclusion instead of a new
# random %TEMP% folder on every run.
$script:StagingRoot = Join-Path $env:LOCALAPPDATA 'IsaacModSync\staging'
try { New-Item -ItemType Directory -Force -Path $script:StagingRoot | Out-Null } catch { }
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
    # No environment overrides: only an explicitly passed -IsaacRoot or real
    # Steam detection may decide the game path.
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

function Restore-RepentogonExe([string]$Root) {
    # A failed force update can rename <Root>\Repentogon\isaac-ng.exe to .bak.
    # Without that EXE the launcher cannot start and path detection falls back
    # to the game root, which is wrong.
    $folder = Join-Path $Root 'Repentogon'
    $exe = Join-Path $folder 'isaac-ng.exe'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return }
    $backup = Join-Path $folder 'Isaac-ng.exe.bak'
    if (Test-Path -LiteralPath $backup -PathType Leaf) {
        Copy-FileWithRetry $backup $exe
        Write-Log "Repentogon-EXE aus Backup wiederhergestellt: $exe"
        return
    }
    Write-Log "Warnung: Repentogon-EXE fehlt und kein Backup vorhanden: $exe"
}

function Get-RepentogonDllPath([string]$Root) {
    # The launcher starts <Root>\Repentogon\isaac-ng.exe when that folder exists,
    # so THAT is the DLL which is actually loaded. The sandbox works because its
    # patched DLL sits in this folder - patching only the game root is not enough.
    $folder = Join-Path $Root 'Repentogon'
    $active = Join-Path $folder 'zhlREPENTOGON.dll'
    if (Test-Path -LiteralPath $active -PathType Leaf) { return $active }
    foreach ($candidate in @((Join-Path $Root 'zhlREPENTOGON.dll'), $active)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Get-LauncherIniPath {
    return Join-Path $env:USERPROFILE 'Documents\My Games\repentogon_launcher.ini'
}

function Set-LauncherSandboxConfig([string]$IsaacRoot) {
    # Exact values from the working sandbox launcher config: no auto update,
    # correct <IsaacRoot>\isaac-ng.exe path, stealth/no-window and LaunchMode 0.
    $ini = Get-LauncherIniPath
    $backup = "$ini.orig"
    if (Test-Path -LiteralPath $ini -PathType Leaf) {
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            Copy-FileWithRetry $ini $backup
            Write-Log "Launcher-INI gesichert: $backup"
        }
        $originalHash = Get-Sha256 $backup
    } else {
        $originalHash = $null
    }
    $root = Get-NormalizedPath $IsaacRoot
    $text = @"
[General]
IsaacExecutable = $root\isaac-ng.exe
RanWizard = 1
HideWindow = 1
StealthMode = 1
[Repentogon]
Console = 1
Update = 0
UnstableUpdates = 0
SkipUpdateMods = 1
SkipWaitModDownloads = 1
AutoUpdate = 0
[Vanilla]
LuaHeapSize = 1024M
LuaDebug = 0
[Shared]
LaunchMode = 0
"@
    Invoke-WithRetry {
        Clear-ReadOnly $ini
        [IO.File]::WriteAllText($ini, ($text -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
    } "Schreiben von $ini"
    Write-Log 'Launcher-INI auf Sandbox-Werte gesetzt (AutoUpdate=0, korrekter Isaac-Pfad, LaunchMode=0).'
    return @{ path = $ini; backup = $backup; original_sha256 = $originalHash }
}

function Restore-LauncherIni($State) {
    if (-not $State -or -not $State.launcher_ini_backup) { return }
    $backup = $State.launcher_ini_backup
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { return }
    if ((Get-Sha256 $backup) -ne $State.launcher_ini_original_sha256) {
        throw 'Gesicherte Launcher-INI hat unerwarteten Hash - Abbruch.'
    }
    Copy-FileWithRetry $backup $State.launcher_ini_path
    Clear-ReadOnly $backup
    Remove-Item -LiteralPath $backup -Force
    Write-Log 'Launcher-INI exakt wiederhergestellt.'
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

function Get-SafeZipPath([string]$Name, [string]$Base) {
    $normalized = $Name.Replace('\', '/')
    if ($normalized.StartsWith('/')) { return $null }
    $parts = @()
    foreach ($part in $normalized.Split('/')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') { continue }
        if ($part -eq '..' -or $part.Contains(':')) { return $null }
        $parts += $part
    }
    if ($parts.Count -eq 0) { return $null }
    return (Join-Path $Base ($parts -join '\'))
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
        $zipPath = Join-Path $script:StagingRoot 'REPENTOGON.zip'
        $stagingOld = Rename-ExistingFile $zipPath
        try {
            Invoke-WithRetry {
                Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            } "Download nach $zipPath"
        } catch {
            Restore-OldFile $stagingOld $zipPath
            throw
        }
        Remove-OldFile $stagingOld
        Write-Log "Staging-ZIP: $zipPath"
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Extract into a fresh staging subfolder first. The game directory is only
    # ever written via Copy-FileWithRetry, which renames an existing DLL aside
    # before copying - an antivirus lock on the old file cannot block that.
    $extractRoot = Join-Path $script:StagingRoot ('extract-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $installed = @()
    try {
        foreach ($entry in $archive.Entries) {
            $source = Get-SafeZipPath $entry.FullName $extractRoot
            if (-not $source) { continue }
            if ($entry.FullName.EndsWith('/')) {
                New-Item -ItemType Directory -Force -Path $source | Out-Null
                continue
            }
            $parent = Split-Path -Parent $source
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Invoke-WithRetry {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $source, $true)
            } "Entpacken nach $source"

            $relative = $source.Substring($extractRoot.Length).TrimStart('\')
            $target = Join-Path $Root $relative
            $targetParent = Split-Path -Parent $target
            if ($targetParent) { New-Item -ItemType Directory -Force -Path $targetParent | Out-Null }
            try {
                Copy-FileWithRetry $source $target
            } catch {
                if ([IO.Path]::GetFileName($target) -eq 'zhlREPENTOGON.dll') {
                    throw 'Antivirus (z. B. Sophos) blockiert zhlREPENTOGON.dll – bitte den Isaac-Ordner als Ausnahme hinzufügen.'
                }
                throw
            }
            $installed += $relative
        }
    } finally {
        $archive.Dispose()
        try { Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction Stop }
        catch { Write-Log "Staging-Ordner bleibt bis zum naechsten Lauf: $extractRoot" }
        # Keep the downloaded ZIP in the fixed staging folder for reuse / one AV exclusion.
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
        $procId = 0
        [void][Win32Window]::GetWindowThreadProcessId($hWnd, [ref]$procId)
        if ($procId -eq $GamePid) { [void][Win32Window]::ShowWindow($hWnd, 5) }
        return $true
    }, [IntPtr]::Zero) | Out-Null
}

function Start-IsaacDirect([string]$Root, [string]$Launcher) {
    if ($NoLaunch) { return 0 }
    $gameExe = Join-Path $Root 'isaac-ng.exe'
    $launcherExe = if ($Launcher) { $Launcher } elseif (Test-Path -LiteralPath 'E:\REPENTOGONLauncher\REPENTOGONLauncher.exe') { 'E:\REPENTOGONLauncher\REPENTOGONLauncher.exe' } else { $null }

    # Fixed staging folder instead of a random %TEMP% path (single AV exclusion).
    $config = Join-Path $script:StagingRoot 'repentogon_launcher.ini'
    try { New-Item -ItemType Directory -Force -Path $script:StagingRoot | Out-Null } catch { }
    @"
[General]
IsaacExecutable = $gameExe
RanWizard = 1
HideWindow = 1
StealthMode = 1
[Repentogon]
Console = 1
Update = 0
UnstableUpdates = 0
SkipUpdateMods = 1
SkipWaitModDownloads = 1
AutoUpdate = 0
[Vanilla]
LuaDebug = 0
[Shared]
LaunchMode = 0
"@ | Set-Content -LiteralPath $config -Encoding ASCII

    # Variant 1: stealth launch (no launcher window). Variant 2: minimal flags
    # without --stealth-mode / --skip-unique if the first attempt is rejected.
    $attempts = @(
        @('--isaac', "`"$gameExe`"", '--launch-mode', 'repentogon', '--stealth-mode',
          '--skip-wizard', '--skip-repentogon-update', '--configuration-file', "`"$config`""),
        @('--isaac', "`"$gameExe`"", '--launch-mode', 'repentogon',
          '--skip-wizard', '--configuration-file', "`"$config`"")
    )

    if ($launcherExe -and (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
        foreach ($arguments in $attempts) {
            try {
                Start-Process -FilePath $launcherExe -ArgumentList $arguments -WindowStyle Hidden -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "Launcher-Start nicht moeglich: $($_.Exception.Message)"
                continue
            }
            # Do not abort just because the launcher process exits: it may hand
            # off to Steam or finish after spawning the game.
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline) {
                $game = @(Get-Process -Name 'isaac-ng' -ErrorAction SilentlyContinue) | Select-Object -First 1
                if ($game) {
                    Start-Sleep -Milliseconds 1200
                    try { Show-GameWindow $game.Id } catch { Write-Log "Fenster nicht sichtbar gemacht: $($_.Exception.Message)" }
                    Write-Log "Spiel ueber REPENTOGON-Launcher gestartet (PID $($game.Id))."
                    return $game.Id
                }
                Start-Sleep -Milliseconds 400
            }
            Write-Log 'Launcher-Versuch ohne sichtbaren Spielprozess beendet - naechster Versuch.'
        }
    }

    # Fallback: let Steam handle the launch. This is a valid outcome, not an error.
    try {
        Start-Process 'steam://rungameid/250900' -ErrorAction Stop
        Write-Log 'Steam-Start (steam://rungameid/250900) angestossen - Patch bleibt aktiv.'
    } catch {
        Write-Log "Steam-Start nicht moeglich: $($_.Exception.Message). Patch bleibt aktiv; bitte Isaac manuell starten."
    }
    return 0
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
    # Set the launcher config FIRST: Update=0 prevents the next launcher start
    # from overwriting our patched DLL with the official 1.1.3a build.
    $launcherIni = Set-LauncherSandboxConfig $root
    $installedByUs = @()
    if (-not (Test-RepentogonInstalled $root)) { $installedByUs = @(Install-Repentogon $root) }
    Restore-RepentogonExe $root
    $dll = Get-RepentogonDllPath $root
    if (-not $dll) { throw 'zhlREPENTOGON.dll fehlt nach der REPENTOGON-Installation.' }
    $dllFolder = Split-Path -Parent $dll
    # The launcher validates that zhlLoader, libzhl and zhlREPENTOGON come from
    # the SAME build. Replace all three with the matching sandbox trio.
    $trio = @('zhlREPENTOGON.dll', 'zhlLoader.dll', 'libzhl.dll')
    $patchedFiles = @()
    foreach ($name in $trio) {
        $target = Join-Path $dllFolder $name
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "REPENTOGON-Datei fehlt: $target" }
        $source = if ($name -eq 'zhlREPENTOGON.dll') { $patched } else { Join-Path $ToolsRoot $name }
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Passende REPENTOGON-Datei fehlt: $source" }
        $sourceHash = Get-Sha256 $source
        $backup = "$target.orig"
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
            $current = Get-Sha256 $target
            Copy-FileWithRetry $target $backup
            if ((Get-Sha256 $backup) -ne $current) { throw "Sicherung von $name fehlgeschlagen (Hash-Mismatch)." }
            Write-Log "Original gesichert: $backup"
        }
        $originalHash = Get-Sha256 $backup
        if ((Get-Sha256 $target) -ne $sourceHash) {
            Copy-FileWithRetry $source $target
            if ((Get-Sha256 $target) -ne $sourceHash) { throw "Kopie von $name konnte nicht verifiziert werden." }
        }
        $attributes = [IO.File]::GetAttributes($target)
        if (($attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) {
            [IO.File]::SetAttributes($target, ($attributes -bor [IO.FileAttributes]::ReadOnly))
        }
        $patchedFiles += [ordered]@{
            name = $name
            target = $target
            backup = $backup
            original_sha256 = $originalHash
            patched_sha256 = $sourceHash
        }
        Write-Log "REPENTOGON-Datei aktiviert: $name ($sourceHash)"
    }
    $backup = ($patchedFiles | Where-Object { $_.name -eq 'zhlREPENTOGON.dll' } | Select-Object -First 1).backup
    $originalHash = ($patchedFiles | Where-Object { $_.name -eq 'zhlREPENTOGON.dll' } | Select-Object -First 1).original_sha256
    $state = [ordered]@{
        schema_version = 1
        applied = $true
        isaac_root = $root
        dll_path = $dll
        backup_path = $backup
        original_dll_sha256 = $originalHash
        patched_dll_sha256 = $patchedHash
        patched_files = @($patchedFiles)
        repentogon_installed_by_us = ($installedByUs.Count -gt 0)
        installed_files = @($installedByUs)
        companion_path = if ($CompanionExe) { $CompanionExe } else { Join-Path $ToolsRoot $script:CompanionName }
        launcher_ini_path = if ($launcherIni) { $launcherIni.path } else { $null }
        launcher_ini_backup = if ($launcherIni) { $launcherIni.backup } else { $null }
        launcher_ini_original_sha256 = if ($launcherIni) { $launcherIni.original_sha256 } else { $null }
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
        foreach ($entry in @($state.patched_files)) {
            if ($entry.backup -and (Test-Path -LiteralPath $entry.backup -PathType Leaf)) {
                Clear-ReadOnly $entry.backup
                Remove-Item -LiteralPath $entry.backup -Force -ErrorAction SilentlyContinue
            }
        }
        if ($state.backup_path -and (Test-Path -LiteralPath $state.backup_path -PathType Leaf)) {
            Clear-ReadOnly $state.backup_path
            Remove-Item -LiteralPath $state.backup_path -Force -ErrorAction SilentlyContinue
        }
        Write-Log 'Von uns installierte REPENTOGON-Dateien entfernt (Urzustand wiederhergestellt).'
    } elseif ($state -and $state.patched_files -and @($state.patched_files).Count -gt 0) {
        foreach ($entry in @($state.patched_files)) {
            if (-not $entry.backup -or -not (Test-Path -LiteralPath $entry.backup -PathType Leaf)) { continue }
            if ((Get-Sha256 $entry.backup) -ne $entry.original_sha256) {
                throw "Gesicherte Datei hat unerwarteten Hash - Abbruch: $($entry.name)"
            }
            Clear-ReadOnly $entry.target
            if ((Get-Sha256 $entry.target) -ne $entry.original_sha256) {
                Copy-FileWithRetry $entry.backup $entry.target
                if ((Get-Sha256 $entry.target) -ne $entry.original_sha256) {
                    throw "Original konnte nicht wiederhergestellt werden: $($entry.name)"
                }
            }
            Clear-ReadOnly $entry.backup
            Remove-Item -LiteralPath $entry.backup -Force
            Write-Log "Original wiederhergestellt: $($entry.name)"
        }
    } elseif ($state -and $state.dll_path -and $state.backup_path -and (Test-Path -LiteralPath $state.backup_path -PathType Leaf)) {
        $backupHash = Get-Sha256 $state.backup_path
        if ($backupHash -ne $state.original_dll_sha256) { throw 'Gesicherte Original-DLL hat unerwarteten Hash - Abbruch.' }
        $target = $state.dll_path
        Clear-ReadOnly $target
        $currentHash = if (Test-Path -LiteralPath $target -PathType Leaf) { Get-Sha256 $target } else { $null }
        if ($currentHash -ne $backupHash) {
            Copy-FileWithRetry $state.backup_path $target
            if ((Get-Sha256 $target) -ne $backupHash) { throw 'Original-DLL konnte nicht wiederhergestellt werden.' }
        }
        Clear-ReadOnly $state.backup_path
        Remove-Item -LiteralPath $state.backup_path -Force
        Write-Log 'Original-DLL exakt wiederhergestellt.'
    }
    Restore-LauncherIni $state
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
