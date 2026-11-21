<#
.SYNOPSIS
    Background watcher for the permanent patch: starts the Steam P2P companion
    in full auto lobby-sync mode as soon as the game creates or joins a lobby.
#>
param(
    [Parameter(Mandatory = $true)][string]$ToolsRoot,
    [Parameter(Mandatory = $true)][string]$IsaacRoot,
    [int]$GamePid = 0,
    [string]$Version = '0.0.18',
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$script:LogPath = Join-Path $env:LOCALAPPDATA 'IsaacModSync\lobby-sync.log'
$script:GameLog = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\log.txt'
$script:SessionRoot = Join-Path $env:LOCALAPPDATA ('IsaacModSync\staging\lobby-sync-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
New-Item -ItemType Directory -Force -Path $script:SessionRoot | Out-Null

function Write-SyncLog([string]$Message) {
    try {
        $dir = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1}" -f [DateTime]::UtcNow.ToString('o'), $Message) -Encoding UTF8
    } catch { }
}

function Write-LobbyProgressJson([string]$Status, [int]$Percent, [string]$ModName) {
    $dir = Join-Path $env:LOCALAPPDATA 'IsaacModSync'
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $target = Join-Path $dir 'lobby_progress.json'
        $temp = $target + '.tmp'
        $visibleUntil = [DateTime]::UtcNow.AddSeconds(4).Ticks
        $payload = @{ status = $Status; percent = $Percent; mod = $ModName; visibleUntil = $visibleUntil; in_lobby = $true } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($temp, $payload, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $target -Force
        Write-SyncLog "PROGRESS $Percent% :: $Status :: $ModName"
    } catch { Write-SyncLog "PROGRESS-FEHLER: $($_.Exception.Message)" }
}

function Send-HotReloadTrigger {
    $dir = Join-Path $env:LOCALAPPDATA 'IsaacModSync'
    $target = Join-Path $dir 'reload_trigger.json'
    $temp = $target + '.tmp'
    $token = [DateTime]::UtcNow.Ticks
    [IO.File]::WriteAllText($temp, (@{ token = $token; issued_utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $target -Force
    Write-SyncLog "HOT-RELOAD-TRIGGER $token gesendet"
}

function Get-SteamCmd {
    $cmd = Get-Command 'steamcmd.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($candidate in @('C:\steamcmd\steamcmd.exe', (Join-Path $env:ProgramFiles 'SteamCMD\steamcmd.exe'), (Join-Path $env:LOCALAPPDATA 'SteamCMD\steamcmd.exe'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Wait-Lobby {
    # Read the whole log, including lobby lines written BEFORE this script
    # started (e.g. the host created the lobby while the game was launching).
    # A lobby is only accepted if no "Leaving current lobby" / shutdown line
    # follows it.
    $position = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $script:GameLog -PathType Leaf) {
            $stream = [IO.File]::Open($script:GameLog, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                if ($stream.Length -lt $position) { $position = 0 }
                $stream.Position = $position
                $reader = New-Object IO.StreamReader($stream)
                $text = $reader.ReadToEnd()
                $position = $stream.Position
                $reader.Dispose()
                $lines = @($text -split "`n")
                $lastLobby = $null
                $leftAfter = $false
                foreach ($line in $lines) {
                    if ($line -match 'Successfully created lobby\s+(\d+)') {
                        $lastLobby = @{ Role = 'host'; Id = $Matches[1] }
                        $leftAfter = $false
                    }
                    if ($line -match 'Successfully joined lobby\s+(\d+)') {
                        $lastLobby = @{ Role = 'client'; Id = $Matches[1] }
                        $leftAfter = $false
                    }
                    if ($lastLobby -and ($line -match 'Leaving current lobby' -or $line -match 'Isaac has shut down')) {
                        $leftAfter = $true
                    }
                }
                if ($lastLobby -and -not $leftAfter) { return $lastLobby }
            } catch { Write-SyncLog "Log-LeseFehler: $($_.Exception.Message)" }
            finally { $stream.Dispose() }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Get-ActiveProfilePath {
    # Requirement: when started via isaac-mod-launcher.exe with online sync,
    # exactly the active modpack must become the host profile.
    $settingsPath = Join-Path $env:APPDATA 'isaac-mod-launcher\settings.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $active = $settings.active_modpack_id
            if ($active) {
                $candidate = Join-Path $env:APPDATA ("isaac-mod-launcher\modpacks\$active\data\profile.json")
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $data = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($data.format -eq 'isaac-mod-profile' -and $data.mod_set) {
                        Write-SyncLog "Host-Profil aus Launcher-Modpack '$active': $candidate"
                        return $candidate
                    }
                }
            }
        } catch { Write-SyncLog "Launcher-Settings nicht lesbar: $($_.Exception.Message)" }
    }
    # Fallback: generate from the live game log / mods directory.
    $modsync = Join-Path $ToolsRoot 'modsync.py'
    $python = 'py'
    $manifest = Join-Path $script:SessionRoot 'local-manifest.json'
    & $python $modsync 'create' '--mods-dir' (Join-Path $IsaacRoot 'mods') '--log' $script:GameLog '--repentogon-dir' (Join-Path $IsaacRoot 'Repentogon') '--allow-empty' '--output' $manifest
    if ($LASTEXITCODE -ne 0) { throw "Manifest konnte nicht erstellt werden (Exit $LASTEXITCODE)." }
    $profile = Join-Path $script:SessionRoot 'host-profile.json'
    & $python $modsync 'profile' 'create' '--manifest' $manifest '--name' 'Friend co-op' '--output' $profile
    if ($LASTEXITCODE -ne 0) { throw "Host-Profil konnte nicht erstellt werden (Exit $LASTEXITCODE)." }
    Write-SyncLog "Host-Profil aus Spiel-Log generiert: $profile"
    return $profile
}

function New-LiveProfileFromMods {
    # Last-resort host profile: derived exclusively from the currently active
    # <Isaac>\mods folder, so the host ALWAYS has something to send.
    $modsDir = Join-Path $IsaacRoot 'mods'
    $entries = @()
    if (Test-Path -LiteralPath $modsDir -PathType Container) {
        Get-ChildItem -LiteralPath $modsDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike 'zz_modsync*' -and -not (Test-Path -LiteralPath (Join-Path $_.FullName 'disable.it')) } |
            Sort-Object Name |
            ForEach-Object {
                $name = $_.Name
                $workshopId = if ($name -match '^(\d+)') { $Matches[1] } else { $null }
                $entries += [ordered]@{
                    workshop_id = $workshopId
                    folder = $name
                    name = $name
                    version = $null
                    sha256 = $null
                }
            }
    }
    $modSetJson = ($entries | ConvertTo-Json -Compress -Depth 6)
    $setHash = [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($modSetJson)))).Replace('-', '')
    $profile = [ordered]@{
        format = 'isaac-mod-profile'
        schema_version = 1
        profile_name = 'Live Host Mods'
        tool_version = $Version
        mod_set = @($entries)
        load_order = @($entries | ForEach-Object { if ($_.workshop_id) { "workshop:$($_.workshop_id)" } else { "local:$($_.folder.ToLowerInvariant())" } })
        mod_set_sha256 = $setHash
    }
    $path = Join-Path $script:SessionRoot 'live-host-profile.json'
    [IO.File]::WriteAllText($path, ($profile | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-SyncLog "Live-Profil aus mods-Ordner erzeugt: $path ($($entries.Count) Mods, sha=$setHash)"
    return $path
}

function Write-LobbyProgress([string]$Activity, [string]$Status, [int]$Percent) {
    Write-Progress -Activity $Activity -Status $Status -PercentComplete ([Math]::Min(99, [Math]::Max(0, $Percent)))
    Write-SyncLog "$Activity :: $Status ($Percent%)"
}

try {
    Write-SyncLog "Auto-Lobby-Sync gestartet (Version $Version, Isaac PID $GamePid)."
    $lobby = Wait-Lobby
    if (-not $lobby) {
        Write-SyncLog "Keine Lobby innerhalb von $TimeoutSeconds s gefunden - Sync nicht gestartet."
        return
    }
    Write-SyncLog "Lobby erkannt: Rolle=$($lobby.Role) ID=$($lobby.Id)"
    Write-LobbyProgressJson 'Lobby erkannt' 5 ''
    $bridge = Join-Path $ToolsRoot 'SteamModProfileBridge.exe'
    $resync = Join-Path $ToolsRoot 'Resync-ProfileAndSaveData.ps1'
    if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) { throw "Bridge fehlt: $bridge" }

    Write-LobbyProgress 'Isaac ModSync Lobby' "Lobby $($lobby.Id) - SteamAPI wird initialisiert" 10

    if ($lobby.Role -eq 'host') {
        try { $profile = Get-ActiveProfilePath }
        catch {
            Write-SyncLog "Host-Profil-Fallback fehlgeschlagen: $($_.Exception.Message)"
            $profile = New-LiveProfileFromMods
        }
        if (-not (Test-Path -LiteralPath $profile -PathType Leaf)) { $profile = New-LiveProfileFromMods }
        $hostSession = Join-Path $script:SessionRoot 'host'
        New-Item -ItemType Directory -Force -Path $hostSession | Out-Null
        $bridgeArgs = @(
            '--mode', 'host', '--isaac-root', "`"$IsaacRoot`"",
            '--session', "`"$hostSession`"", '--profile', "`"$profile`"",
            '--lobby-id', $lobby.Id, '--expected-version', $Version,
            '--resync-script', "`"$resync`"", '--game-log', "`"$script:GameLog`"",
            '--timeout', '86400'
        )
        Start-Process -FilePath $bridge -ArgumentList $bridgeArgs -WindowStyle Hidden -WorkingDirectory $ToolsRoot | Out-Null
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $hostSession 'steam-bridge.ready'))) {
            Start-Sleep -Milliseconds 250
        }
        if (Test-Path -LiteralPath (Join-Path $hostSession 'steam-bridge.ready')) {
            Write-LobbyProgress 'Isaac ModSync Lobby' 'Host bereit - Profil wird an joinende Freunde gesendet' 100
        Write-LobbyProgressJson 'Mods aktiv!' 100 ''
            Write-SyncLog "Host-Sync aktiv. Profil: $profile"
        } else {
            Write-SyncLog 'Host-Sync: steam-bridge.ready nicht erschienen.'
        }
    } else {
        $clientSession = Join-Path $script:SessionRoot 'client'
        New-Item -ItemType Directory -Force -Path $clientSession | Out-Null
        $bridgeArgs = @(
            '--mode', 'client', '--isaac-root', "`"$IsaacRoot`"",
            '--session', "`"$clientSession`"", '--lobby-id', $lobby.Id,
            '--expected-version', $Version,
            '--resync-script', "`"$resync`"", '--game-log', "`"$script:GameLog`"",
            '--timeout', [string]$TimeoutSeconds
        )
        $proc = Start-Process -FilePath $bridge -ArgumentList $bridgeArgs -WindowStyle Hidden -PassThru -WorkingDirectory $ToolsRoot
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline -and -not $proc.HasExited) { Start-Sleep -Milliseconds 500 }
        $received = Join-Path $clientSession 'received-host-profile.json'
        if (-not (Test-Path -LiteralPath $received -PathType Leaf)) {
            Write-SyncLog 'Client-Sync: kein Host-Profil empfangen.'
            Write-LobbyProgressJson 'Fehler: kein Profil' 0 ''
            return
        }
        Write-LobbyProgressJson 'Profil empfangen' 20 ''
        Write-LobbyProgress 'Isaac ModSync Lobby' 'Host-Profil empfangen - Workshop-Mods werden geprueft' 20
        $profileData = Get-Content -LiteralPath $received -Raw -Encoding UTF8 | ConvertFrom-Json
        $mods = @($profileData.mod_set)
        for ($i = 0; $i -lt $mods.Count; $i++) {
            $modName = [string]$mods[$i].name
            $percent = 20 + [int](60 * ($i + 1) / [Math]::Max(1, $mods.Count))
            Write-LobbyProgressJson "Download $($i + 1)/$($mods.Count)" $percent $modName
            Write-LobbyProgress 'Isaac ModSync Lobby' "Download $($i + 1)/$($mods.Count): $modName" $percent
        }
        $modsync = Join-Path $ToolsRoot 'modsync.py'
        $manifest = Join-Path $script:SessionRoot 'client-manifest.json'
        & py $modsync 'create' '--mods-dir' (Join-Path $IsaacRoot 'mods') '--log' $script:GameLog '--repentogon-dir' (Join-Path $IsaacRoot 'Repentogon') '--allow-empty' '--output' $manifest
        if ($LASTEXITCODE -ne 0) { throw "Client-Manifest fehlgeschlagen (Exit $LASTEXITCODE)." }
        $stageRoot = Join-Path $script:SessionRoot 'stage'
        $stageArgs = @($modsync, 'profile', 'stage', '--profile', $received, '--local-manifest', $manifest,
            '--mods-dir', (Join-Path $IsaacRoot 'mods'), '--workshop-cache', (Join-Path (Split-Path (Split-Path $IsaacRoot)) 'workshop\content\250900'), '--output', $stageRoot)
        $steamCmd = Get-SteamCmd
        if ($steamCmd) { $stageArgs += @('--steamcmd', [IO.Path]::GetFullPath($steamCmd)) }
        & py @stageArgs
        if ($LASTEXITCODE -ne 0) { throw "Mod-Staging fehlgeschlagen (Exit $LASTEXITCODE)." }
        Write-LobbyProgressJson 'Staging fertig' 85 ''
        Write-LobbyProgress 'Isaac ModSync Lobby' 'Mods heruntergeladen und verifiziert' 85
        $stagedMods = Join-Path $stageRoot 'mods'
        if (Test-Path -LiteralPath $stagedMods -PathType Container) {
            $realMods = Join-Path $IsaacRoot 'mods'
            $held = $realMods + '.modsync-original-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
            if (-not (Test-Path -LiteralPath $held)) { [IO.Directory]::Move($realMods, $held) }
            New-Item -ItemType Junction -Path $realMods -Target $stagedMods | Out-Null
            Write-SyncLog "Client-Mod-Set aktiv (Junction). Original: $held"
        }
        Write-LobbyProgressJson 'Hot-Reload laeuft' 90 ''
        Write-LobbyProgress 'Isaac ModSync Lobby' 'Hot-Reload im laufenden Spiel' 90
        Send-HotReloadTrigger
        Write-SyncLog 'Hot-Reload-Signal gesendet; DLL schreibt 100% und "Mods aktiv!" in lobby_progress.json.'
    }
} catch {
    Write-SyncLog "FEHLER: $($_.Exception.Message)"
} finally {
    Write-Progress -Activity 'Isaac ModSync Lobby' -Completed
}
