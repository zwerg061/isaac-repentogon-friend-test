<#
.SYNOPSIS
    Solo two-player live verification: prueft den echten Steam-Lobby-Transfer
    komplett allein auf einem PC. Es wird KEIN zweiter Spieler und KEIN
    zweiter Steam-Account benoetigt: Der Host schreibt das Profil via
    SetLobbyData in die echte Steam-Lobby, der Solo-Client liest es via
    GetLobbyData zurueck (Steam repliziert die Daten an alle Mitglieder).

    Voraussetzung: Isaac laeuft mit einer offenen privaten Lobby und der
    HOST-Sync (Start-ModSyncLobbySync.ps1) ist aktiv.

    Ergebnis: %LOCALAPPDATA%\IsaacModSync\solo-verification-result.json
#>
param(
    [string]$ToolsRoot = 'G:\Coode\the binding of isaac\multyplayer modet\sandbox\release-v0.0.1\tools',
    [string]$IsaacRoot = 'E:\SteamLibrary\steamapps\common\The Binding of Isaac Rebirth',
    [string]$Version = '0.0.23',
    [int]$TimeoutSeconds = 180,
    [string]$SteamCmd = '',
    [string]$LobbyId = '',
    [string]$HostProfile = ''
)

$ErrorActionPreference = 'Stop'
$local = Join-Path $env:LOCALAPPDATA 'IsaacModSync'
$testRoot = Join-Path $local 'solo-client-test'
$resultPath = Join-Path $local 'solo-verification-result.json'
$progressPath = Join-Path $local 'lobby_progress.json'
$gameLog = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\log.txt'
$started = [DateTime]::UtcNow

$steps = @()
function Step([string]$name, [string]$status, [string]$detail) {
    $entry = [ordered]@{ name = $name; status = $status; detail = $detail; at = [DateTime]::UtcNow.ToString('o') }
    $script:steps += $entry
    $color = if ($status -eq 'PASS') { 'Green' } elseif ($status -eq 'SKIP') { 'Yellow' } else { 'Red' }
    Write-Host ("[{0}] {1}: {2}" -f $status, $name, $detail) -ForegroundColor $color
}
function Progress([string]$status, [int]$percent) {
    try {
        New-Item -ItemType Directory -Force -Path $local | Out-Null
        $tmp = $progressPath + '.tmp'
        $payload = @{ status = $status; percent = $percent; mod = ''; visibleUntil = [DateTime]::UtcNow.AddSeconds(8).Ticks; in_lobby = $true; done = ($percent -ge 100) } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($tmp, $payload, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $progressPath -Force
    } catch { }
}
function Finish([string]$overall) {
    $result = [ordered]@{
        overall = $overall
        version = $Version
        started_utc = $started.ToString('o')
        finished_utc = [DateTime]::UtcNow.ToString('o')
        steps = @($steps)
    }
    New-Item -ItemType Directory -Force -Path $local | Out-Null
    [IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Host ("`nErgebnis: {0} -> {1}" -f $overall, $resultPath)
    if ($overall -eq 'PASS') { Progress 'Solo-Live-Test erfolgreich' 100 } else { Progress "Solo-Live-Test: $overall" 0 }
}

try {
    Write-Host '=== Isaac ModSync - SOLO Live-Verifikation (ohne Freund) ===' -ForegroundColor Cyan

    # 1) Preflight
    $bridge = Join-Path $ToolsRoot 'SteamModProfileBridge.exe'
    if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) { Step 'Preflight' 'FAIL' "Bridge fehlt: $bridge"; Finish 'FAIL'; exit 1 }
    $bridgeVersion = (Get-Item -LiteralPath $bridge).VersionInfo.ProductVersion
    if ($bridgeVersion -and $bridgeVersion -ne $Version -and $bridgeVersion -ne "$Version.0") {
        Step 'Preflight' 'FAIL' "Bridge ist v$bridgeVersion, erwartet v$Version"; Finish 'FAIL'; exit 1
    }
    Step 'Preflight' 'PASS' "Bridge v$bridgeVersion, IsaacRoot $IsaacRoot"

    # 2) Lobby-ID: entweder uebergeben (autonomer Modus) oder aus dem Spiel-Log
    if ($LobbyId) {
        Step 'Lobby' 'PASS' "ID $LobbyId (uebergeben)"
        Progress 'Lobby erkannt' 5
    } else {
    if (-not (Test-Path -LiteralPath $gameLog -PathType Leaf)) { Step 'Lobby' 'FAIL' "log.txt fehlt: $gameLog"; Finish 'FAIL'; exit 1 }
    $lines = @(Get-Content -LiteralPath $gameLog -Encoding UTF8)
    $lobbyId = $null; $role = $null; $valid = $false
    foreach ($line in $lines) {
        if ($line -match 'Successfully created lobby\s+(\d+)') { $lobbyId = $Matches[1]; $role = 'host'; $valid = $true }
        if ($line -match 'Successfully joined lobby\s+(\d+)') {
            if (-not $valid) { $lobbyId = $Matches[1]; $role = 'client' }
            $valid = $true
        }
        if ($valid -and $lobbyId -and ($line -match 'Leaving current lobby' -or $line -match 'Isaac has shut down')) { $valid = $false; $lobbyId = $null }
    }
    if (-not $valid -or -not $lobbyId) { Step 'Lobby' 'FAIL' 'Keine aktive Lobby in log.txt - bitte private Lobby in Isaac oeffnen'; Finish 'FAIL'; exit 1 }
    Step 'Lobby' 'PASS' "ID $lobbyId (Rolle $role)"
    Progress 'Lobby erkannt' 5
    }

    # 3) Leeren Solo-Test-Ordner anlegen
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
    Step 'Testordner' 'PASS' $testRoot

    # 3b) Host-Bridge: schreibt das Profil per SetLobbyData in die echte Lobby
    $hostProfilePath = $HostProfile
    if (-not $hostProfilePath) {
        $settingsPath = Join-Path $env:APPDATA 'isaac-mod-launcher\settings.json'
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            $active = (Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json).active_modpack_id
            if ($active) {
                $hostProfilePath = Join-Path $env:APPDATA "isaac-mod-launcher\modpacks\$active\data\profile.json"
            }
        }
    }
    if (-not $hostProfilePath -or -not (Test-Path -LiteralPath $hostProfilePath -PathType Leaf)) {
        Step 'Host-Bridge' 'FAIL' "Host-Profil fehlt: $hostProfilePath"; Finish 'FAIL'; exit 1
    }
    $hostSession = Join-Path $testRoot 'host'
    New-Item -ItemType Directory -Force -Path $hostSession | Out-Null

    # Steam repliziert nur ~8 KB Lobby-Data. Das volle Launcher-Profil hat
    # ~14 KB; fuer den Transfer wird es auf die von modsync benoetigten Felder
    # verschlankt (ohte `name`), damit alle Chunks ankommen.
    $fullProfile = Get-Content -LiteralPath $hostProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $slim = [ordered]@{
        format = $fullProfile.format
        schema_version = $fullProfile.schema_version
        profile_name = $fullProfile.profile_name
        tool_version = $fullProfile.tool_version
        game_version = $fullProfile.game_version
        repentogon_version = $fullProfile.repentogon_version
    }
    $slim['load_order'] = @($fullProfile.load_order)
    $slim['load_order_sha256'] = $fullProfile.load_order_sha256
    $slim['game_build_sha256'] = $fullProfile.game_build_sha256
    $slim['repentogon_build_sha256'] = $fullProfile.repentogon_build_sha256
    $slim['mod_set'] = @($fullProfile.mod_set | ForEach-Object {
        [ordered]@{
            folder = $_.folder
            workshop_id = $_.workshop_id
            version = $_.version
            sha256 = $_.sha256
        }
    })
    # Steam repliziert max. ~8000 Bytes Lobby-Data (10 Chunks à 800 Bytes).
    # Das verschlankte Profil wird deshalb gzip-komprimiert und base64-kodiert
    # in einem kleinen Envelope uebertragen - vollstaendig und verlustfrei.
    $slimJson = $slim | ConvertTo-Json -Compress -Depth 8
    $memory = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GzipStream]::new($memory, [IO.Compression.CompressionMode]::Compress, $true)
    $jsonBytes = [Text.UTF8Encoding]::new($false).GetBytes($slimJson)
    $gzip.Write($jsonBytes, 0, $jsonBytes.Length)
    $gzip.Dispose()
    $envelope = [ordered]@{
        format = 'isaac-mod-profile'
        encoding = 'gzip-base64'
        schema_version = 1
        profile_name = $fullProfile.profile_name
        data = [Convert]::ToBase64String($memory.ToArray())
    }
    $memory.Dispose()
    $slimPath = Join-Path $hostSession 'transfer-profile.json'
    [IO.File]::WriteAllText($slimPath, ($envelope | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
    Step 'Transfer-Profil' 'PASS' ("{0} Bytes (gzip), {1} Mods" -f (Get-Item $slimPath).Length, @($slim.mod_set).Count)

    $hostArgs = @('--mode','host','--isaac-root',"`"$IsaacRoot`"",'--session',"`"$hostSession`"",
        '--profile',"`"$slimPath`"",'--lobby-id',$LobbyId,
        '--expected-version',$Version,'--timeout',"$TimeoutSeconds")
    $hostProc = Start-Process -FilePath $bridge -ArgumentList $hostArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $hostSession 'bridge-stdout.log') `
        -RedirectStandardError (Join-Path $hostSession 'bridge-stderr.log')
    $hostReady = Join-Path $hostSession 'steam-bridge.ready'
    $hostDeadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $hostReady) -and (Get-Date) -lt $hostDeadline -and -not $hostProc.HasExited) {
        Start-Sleep -Milliseconds 250
    }
    if (-not (Test-Path -LiteralPath $hostReady)) {
        $detail = Get-Content (Join-Path $hostSession 'bridge-stderr.log') -Raw -ErrorAction SilentlyContinue
        Step 'Host-Bridge' 'FAIL' "nicht bereit: $detail"; Finish 'FAIL'; exit 1
    }
    Step 'Host-Bridge' 'PASS' 'Profil in Steam-Lobby geschrieben'

    # 4) Echten Solo-Client gegen die Steam-Lobby starten
    Progress 'Solo-Client startet' 10
    $args = @('--mode', 'solo', '--isaac-root', "`"$IsaacRoot`"", '--session', "`"$testRoot`"",
        '--lobby-id', $LobbyId, '--expected-version', $Version, '--timeout', "$TimeoutSeconds")
    $out = Join-Path $testRoot 'bridge-stdout.log'
    $err = Join-Path $testRoot 'bridge-stderr.log'
    $proc = Start-Process -FilePath $bridge -ArgumentList $args -WindowStyle Hidden -PassThru -Wait -RedirectStandardOutput $out -RedirectStandardError $err
    $stdout = if (Test-Path $out) { (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) } else { '' }
    $stderr = if (Test-Path $err) { (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue) } else { '' }
    if ($proc.ExitCode -ne 0) {
        $detail = ($stderr + ' ' + $stdout).Trim()
        Step 'Solo-Client' 'FAIL' ("Exit {0}: {1}" -f $proc.ExitCode, $detail)
        Finish 'FAIL'; exit 1
    }
    Step 'Solo-Client' 'PASS' 'Bridge-Exit 0'

    # 5) Empfangenes Profil verifizieren
    $received = Join-Path $testRoot 'received-host-profile.json'
    if (-not (Test-Path -LiteralPath $received -PathType Leaf)) { Step 'Profil-Empfang' 'FAIL' 'received-host-profile.json fehlt'; Finish 'FAIL'; exit 1 }
    $envelope = Get-Content -LiteralPath $received -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($envelope.encoding -eq 'gzip-base64') {
        $compressed = [Convert]::FromBase64String($envelope.data)
        $input = [IO.MemoryStream]::new($compressed)
        $gzipIn = [IO.Compression.GzipStream]::new($input, [IO.Compression.CompressionMode]::Decompress)
        $reader = [IO.StreamReader]::new($gzipIn)
        $decodedJson = $reader.ReadToEnd()
        $reader.Dispose(); $gzipIn.Dispose(); $input.Dispose()
        $profile = $decodedJson | ConvertFrom-Json
    } else {
        $profile = $envelope
    }
    if ($profile.format -ne 'isaac-mod-profile' -or -not $profile.mod_set) { Step 'Profil-Empfang' 'FAIL' 'Ungueltiges Profilformat'; Finish 'FAIL'; exit 1 }
    Step 'Profil-Empfang' 'PASS' ("{0} Mods, via Steam-Lobby empfangen" -f @($profile.mod_set).Count)
    function Canonical-ModSet($mods) {
        @($mods | ForEach-Object {
            "{0}|{1}|{2}|{3}" -f [string]$_.folder, [string]$_.workshop_id, [string]$_.version, [string]$_.sha256
        } | Sort-Object) -join "`n"
    }
    $expectedSet = Canonical-ModSet $fullProfile.mod_set
    $actualSet = Canonical-ModSet $profile.mod_set
    if ($expectedSet -ne $actualSet) {
        Step 'Profil-Vergleich' 'FAIL' 'Empfangenes Mod-Set weicht vom Host-Profil ab'
        Finish 'FAIL'; exit 1
    }
    Step 'Profil-Vergleich' 'PASS' 'Empfangenes Mod-Set identisch mit dem Host-Profil'
    Progress 'Profil empfangen' 20

    # 6) Nativer Workshop-Download via ISteamUGC (v0.0.23, kein SteamCMD,
    #    keine Zugangsdaten - der angemeldete Steam-Client liefert die Items).
    $workshopId = @($profile.mod_set | Where-Object { $_.workshop_id } | Select-Object -First 1).workshop_id
    if (-not $workshopId) {
        Step 'UGC-Download' 'SKIP' 'Profil enthaelt keine Workshop-ID'
    } else {
        Progress 'UGC-Download' 60
        $dlSession = Join-Path $testRoot 'ugc-download'
        New-Item -ItemType Directory -Force -Path $dlSession | Out-Null
        $workshopRoot = Join-Path (Split-Path (Split-Path $IsaacRoot)) 'workshop\content\250900'
        $ugcArgs = @('--mode','download','--isaac-root',"`"$IsaacRoot`"",'--session',"`"$dlSession`"",
            '--workshop-ids',$workshopId,'--workshop-root',"`"$workshopRoot`"",'--timeout','90')
        $ugcProc = Start-Process -FilePath $bridge -ArgumentList $ugcArgs -PassThru -Wait -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $dlSession 'stdout.log') `
            -RedirectStandardError (Join-Path $dlSession 'stderr.log')
        $completeFile = Join-Path $dlSession 'workshop-download-complete.json'
        if ($ugcProc.ExitCode -eq 0 -and (Test-Path -LiteralPath $completeFile -PathType Leaf)) {
            Step 'UGC-Download' 'PASS' "Mod $workshopId via ISteamUGC verifiziert (0->100%)"
        } else {
            Step 'UGC-Download' 'FAIL' "ISteamUGC Exit $($ugcProc.ExitCode)"
            Finish 'FAIL'; exit 1
        }
    }
    Progress 'Verifikation fertig' 85
    if ($hostProc -and -not $hostProc.HasExited) { Stop-Process -Id $hostProc.Id -Force -ErrorAction SilentlyContinue }
    Finish 'PASS'
    exit 0
} catch {
    Step 'Ausnahme' 'FAIL' $_.Exception.Message
    Finish 'FAIL'
    exit 1
}
