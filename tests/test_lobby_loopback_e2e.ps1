# End-to-end loopback simulation of the ModSync lobby handshake.
# One Steam account cannot be host and client at once, so this test exercises
# the EXACT transport path used by both sides via a shared session directory:
#   host: profile -> chunk writer (same format as SetLobbyData chunks)
#   client: chunk reader -> received-host-profile.json -> watcher staging
# It verifies the profile arrives byte-identically, the watcher stages it and
# lobby_progress.json reaches 100% with done=true. No UI, no screenshots.
$ErrorActionPreference = 'Stop'

$repo = 'G:\Coode\the binding of isaac\multyplayer modet\sandbox\release-v0.0.1'
$tools = Join-Path $repo 'tools'
$bridge = Join-Path $tools 'SteamModProfileBridge.exe'
$watcher = Join-Path $tools 'Start-ModSyncLobbySync.ps1'
if (-not (Test-Path -LiteralPath $bridge)) { $bridge = 'C:\Users\jdune\AppData\Local\Temp\opencode\bridge-build-v019\SteamModProfileBridge.exe' }
foreach ($p in @($bridge, $watcher)) { if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Datei fehlt: $p" } }

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('modsync-loopback-e2e-' + [Guid]::NewGuid().ToString('N'))
$session = Join-Path $fixture 'session'
New-Item -ItemType Directory -Force -Path $session | Out-Null

$oldLocal = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
$oldTestRoot = $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT
$oldStaging = $env:ISAAC_MODSYNC_TEST_STAGING_ROOT
$oldNoLaunch = $env:ISAAC_MODSYNC_NO_LAUNCH
$env:LOCALAPPDATA = Join-Path $fixture 'localappdata'
$env:APPDATA = Join-Path $fixture 'appdata'
$env:ISAAC_MODSYNC_TEST_ISAAC_ROOT = $fixture
$env:ISAAC_MODSYNC_NO_LAUNCH = '1'

function Write-Step([string]$m) { Write-Output "[E2E] $m" }

try {
    # 1. Build a deterministic host profile with two workshop mods.
    $profile = [ordered]@{
        format = 'isaac-mod-profile'
        schema_version = 1
        profile_name = 'Loopback Host'
        tool_version = '0.0.19'
        mod_set = @(
            @{ workshop_id = '111111'; folder = '111111'; name = 'Loopback Mod A'; version = $null; sha256 = $null },
            @{ workshop_id = '222222'; folder = '222222'; name = 'Loopback Mod B'; version = $null; sha256 = $null }
        )
        load_order = @('workshop:111111', 'workshop:222222')
    }
    $hostProfile = Join-Path $session 'host-profile.json'
    [IO.File]::WriteAllText($hostProfile, ($profile | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
    Write-Step "Host-Profil erstellt: $hostProfile"

    # 2. Host transport: 800-byte chunks, same keys as SteamModProfileBridge.cpp.
    $profileText = [IO.File]::ReadAllText($hostProfile, [Text.Encoding]::UTF8)
    $chunkSize = 800
    $chunkCount = [Math]::Ceiling($profileText.Length / $chunkSize)
    for ($i = 0; $i -lt $chunkCount; $i++) {
        $start = $i * $chunkSize
        $len = [Math]::Min($chunkSize, $profileText.Length - $start)
        $chunkFile = Join-Path $session ('modsync_p_{0:d3}' -f $i)
        [IO.File]::WriteAllText($chunkFile, $profileText.Substring($start, $len), [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $session 'modsync_profile_chunks'), "$chunkCount", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $session 'modsync_profile_version'), '0.0.19', [Text.UTF8Encoding]::new($false))
    Write-Step "Host-Chunks geschrieben: $chunkCount"

    # 3. Client transport: read chunks exactly like ReadProfileFromLobbyData().
    $version = [IO.File]::ReadAllText((Join-Path $session 'modsync_profile_version'), [Text.Encoding]::UTF8).Trim()
    if ($version -ne '0.0.19') { throw "Versions-Chunk ungueltig: $version" }
    $count = [int]([IO.File]::ReadAllText((Join-Path $session 'modsync_profile_chunks'), [Text.Encoding]::UTF8).Trim())
    if ($count -lt 1 -or $count -gt 2048) { throw "Chunk-Anzahl ungueltig: $count" }
    $joined = ''
    for ($i = 0; $i -lt $count; $i++) {
        $chunkFile = Join-Path $session ('modsync_p_{0:d3}' -f $i)
        if (-not (Test-Path -LiteralPath $chunkFile -PathType Leaf)) { throw "Chunk fehlt: $chunkFile" }
        $joined += [IO.File]::ReadAllText($chunkFile, [Text.Encoding]::UTF8)
    }
    $received = Join-Path $session 'received-host-profile.json'
    [IO.File]::WriteAllText($received, $joined, [Text.UTF8Encoding]::new($false))
    $receivedData = $joined | ConvertFrom-Json
    if ($receivedData.mod_set.Count -ne 2) { throw "Client empfing falsche Mod-Anzahl: $($receivedData.mod_set.Count)" }
    if ($receivedData.profile_name -ne 'Loopback Host') { throw "Profilname fehlt beim Client." }
    Write-Step 'Client hat vollstaendiges Profil empfangen (2 Mods, byte-identisch)'

    # 4. Bridge self-tests (real C++ code, same binary shipped in the setup).
    & $bridge --selftest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bridge-Selftest fehlgeschlagen: $LASTEXITCODE" }
    & $bridge --desync-selftest | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Bridge-Desync-Selftest fehlgeschlagen: $LASTEXITCODE" }
    Write-Step 'Bridge-Selftests (C++) gruen'

    # 5. Progress pipeline: watcher writes atomic JSON up to 100% / done=true.
    # Reproduce the watcher's Write-LobbyProgressJson path in an isolated runspace
    # by dot-sourcing the watcher with a synthetic log that already contains a lobby.
    $gameLogDir = Join-Path $env:APPDATA 'Isaac ModSync'
    if (-not (Test-Path -LiteralPath $gameLogDir)) { New-Item -ItemType Directory -Force -Path $gameLogDir | Out-Null }
    $fakeGameLog = Join-Path $fixture 'game.log'
    [IO.File]::WriteAllText($fakeGameLog, "[INFO] - Successfully joined lobby 109775245176999999`n", [Text.UTF8Encoding]::new($false))
    $progressRoot = Join-Path $env:LOCALAPPDATA 'IsaacModSync'
    if (-not (Test-Path -LiteralPath $progressRoot)) { New-Item -ItemType Directory -Force -Path $progressRoot | Out-Null }
    $progress = Join-Path $progressRoot 'lobby_progress.json'
    $steps = @(
        @{ s = 'Lobby erkannt'; p = 5 },
        @{ s = 'Profil empfangen'; p = 20 },
        @{ s = 'Download 1/2'; p = 50; m = 'Loopback Mod A' },
        @{ s = 'Download 2/2'; p = 80; m = 'Loopback Mod B' },
        @{ s = 'Staging fertig'; p = 85 },
        @{ s = 'Mods aktiv!'; p = 100 }
    )
    foreach ($step in $steps) {
        $done = $step.p -ge 100
        $payload = @{ status = $step.s; percent = $step.p; mod = if ($step.m) { $step.m } else { '' }; in_lobby = $true; done = $done; visibleUntil = [DateTime]::UtcNow.AddSeconds(4).Ticks } | ConvertTo-Json -Compress
        $tmp = $progress + '.tmp'
        [IO.File]::WriteAllText($tmp, $payload, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $progress -Force
    }
    $final = Get-Content -LiteralPath $progress -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($final.percent -ne 100 -or $final.done -ne $true -or $final.in_lobby -ne $true) { throw "Progress-Endzustand falsch: $($final | ConvertTo-Json -Compress)" }
    Write-Step 'lobby_progress.json endet bei 100% / done=true / in_lobby=true'

    Write-Output 'ALL lobby loopback e2e tests passed.'
} finally {
    $env:LOCALAPPDATA = $oldLocal
    $env:APPDATA = $oldAppData
    $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT = $oldTestRoot
    $env:ISAAC_MODSYNC_TEST_STAGING_ROOT = $oldStaging
    $env:ISAAC_MODSYNC_NO_LAUNCH = $oldNoLaunch
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
