<#
.SYNOPSIS
    Runs the new -> remove -> new sandbox reload cycle with a custom shader
    fixture and verifies shader/RoomConfig stability from the REPENTOGON log.

.NOTES
    The fixture sources live in this release workspace; the script stages them
    into the existing read-only prototype before launching the test. No Steam
    account and no real Isaac mod directory is touched.
#>
param(
    [int]$Seconds = 180,
    [string]$Sequence = 'new,remove,new',
    [string]$LogDir,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$releaseRepo = Split-Path -Parent $PSScriptRoot
$root = 'G:\Coode\the binding of isaac\multyplayer modet'
$prototype = Join-Path $root 'sandbox\live-reload-prototype'
$incomingFixture = Join-Path $prototype 'game\incoming\zz_live_reload_fixture_b'
$fixtureSource = Join-Path $PSScriptRoot 'fixtures\custom-shader'
$logRoot = Join-Path $prototype 'logs'
$marker = '[modsync-live-reload-probe]'

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT: $Message" }
}

if (-not $CheckOnly) {
    Assert (Test-Path -LiteralPath $incomingFixture -PathType Container) "Incoming fixture fehlt: $incomingFixture"
    Copy-Item -LiteralPath (Join-Path $fixtureSource 'main.lua') -Destination (Join-Path $incomingFixture 'main.lua') -Force
    $shaderTarget = Join-Path $incomingFixture 'resources\shaders'
    New-Item -ItemType Directory -Force -Path $shaderTarget | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtureSource 'resources\shaders\modsync_probe.fs') -Destination $shaderTarget -Force
    Copy-Item -LiteralPath (Join-Path $fixtureSource 'resources\shaders\modsync_probe.vs') -Destination $shaderTarget -Force
    Write-Host "Custom-Shader-Fixture nach $incomingFixture gestaget." -ForegroundColor Cyan

    # Der `new`-Schritt des Probes verlangt, dass Fixture B zu Beginn nicht in
    # <sandbox>\mods liegt. Fruehere Laeufe koennen sie dort zurueckgelassen haben.
    foreach ($stale in @(
        (Join-Path $prototype 'game\mods\zz_live_reload_fixture_b'),
        (Join-Path $prototype 'game\removed\zz_live_reload_fixture_b')
    )) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
    }

    Write-Host "Starte Sandbox-Reload-Zyklus: $Sequence ..." -ForegroundColor Cyan
    & (Join-Path $root 'tools\Run-LobbyReloadTest.ps1') -Seconds $Seconds -Sequence $Sequence
}

if (-not $LogDir) {
    $LogDir = (Get-ChildItem -LiteralPath $logRoot -Directory -ErrorAction Stop |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}
Assert (Test-Path -LiteralPath $LogDir -PathType Container) "Log-Verzeichnis fehlt: $LogDir"
$logPath = Join-Path $LogDir 'repentogon.log'
Assert (Test-Path -LiteralPath $logPath -PathType Leaf) "repentogon.log fehlt: $logPath"

$lines = @(Get-Content -LiteralPath $logPath -Encoding UTF8 -ErrorAction Stop)
$probe = @($lines | Where-Object { $_ -like "*$marker*" })

function Select-Probe([string]$Pattern) {
    return @($probe | Where-Object { $_ -match $Pattern })
}

$resets = Select-Probe 'reset (\d+)/(\d+) op=(\w+)'
Assert ($resets.Count -eq 3) "Erwartet 3 Reset-Zeilen, gefunden $($resets.Count)."
$expectedOps = @('new', 'remove', 'new')
for ($i = 0; $i -lt 3; $i++) {
    Assert ($resets[$i] -match "reset $($i+1)/3 op=$($expectedOps[$i])(?:\s|$)") "Reset $($i+1) ist nicht '$($expectedOps[$i])': $($resets[$i])"
}

# Shader cache: 'new' must recompile the custom shader, 'remove' must drop it,
# the second 'new' must recompile it again. No stale shader IDs may remain.
$shaderLines = Select-Probe 'shader cache reset; reloaded=(\d+) dropped=(\d+) remaining=(\d+)'
Assert ($shaderLines.Count -eq 3) "Erwartet 3 Shader-Reset-Zeilen, gefunden $($shaderLines.Count)."
$expectedReloaded = @(1, 0, 1)
$expectedDropped = @(0, 1, 0)
for ($i = 0; $i -lt 3; $i++) {
    if ($shaderLines[$i] -match 'reloaded=(\d+) dropped=(\d+) remaining=(\d+)') {
        $reloaded = [int]$Matches[1]
        $dropped = [int]$Matches[2]
        $remaining = [int]$Matches[3]
        Assert ($reloaded -ge $expectedReloaded[$i]) "Reset $($i+1): zu wenige neu geladene Shader ($reloaded)."
        Assert ($dropped -ge $expectedDropped[$i]) "Reset $($i+1): Custom-Shader wurde nicht verworfen ($dropped)."
        if ($expectedDropped[$i] -eq 0) { Assert ($remaining -ge 1) "Reset $($i+1): kein Custom-Shader im Cache ($remaining)." }
    } else {
        throw "Shader-Zeile $($i+1) nicht parsebar: $($shaderLines[$i])"
    }
}

# Native pool/RoomConfig-adjacent state must stay duplicated-free and identical
# before and after every reset (a second reset run would grow/duplicate it).
$before = Select-Probe 'pools before: count=(\d+) duplicateIds=(\d+) duplicateNames=(\d+)'
$after = Select-Probe 'pools after: count=(\d+) duplicateIds=(\d+) duplicateNames=(\d+)'
Assert ($before.Count -eq 3 -and $after.Count -eq 3) "Erwartet 3 Pool-Vorher/Nachher-Paare, gefunden $($before.Count)/$($after.Count)."
$baseline = $null
for ($i = 0; $i -lt 3; $i++) {
    foreach ($pair in @(@($before[$i], 'before'), @($after[$i], 'after'))) {
        if ($pair[0] -match 'count=(\d+) duplicateIds=(\d+) duplicateNames=(\d+)') {
            $count = [int]$Matches[1]
            Assert ([int]$Matches[2] -eq 0 -and [int]$Matches[3] -eq 0) "Reset $($i+1) $($pair[1]): doppelte Pools/RoomConfigs erkannt."
            if ($null -eq $baseline) { $baseline = $count }
            Assert ($count -eq $baseline) "Reset $($i+1) $($pair[1]): Pool/RoomConfig-Anzahl $count != $baseline."
        } else { throw "Pool-Zeile nicht parsebar: $($pair[0])" }
    }
}

$fatal = @($lines | Where-Object { $_ -match '\[(FATAL|ERROR)\]|Invalid shader ID|version mismatch' })
Assert ($fatal.Count -eq 0) "Log enthält $($fatal.Count) Fehler-/Shader-ID-/Versionsmeldungen."

Write-Host "Shader- und RoomConfig-Stabilität OK (Log: $logPath)" -ForegroundColor Green
Write-Host '  new:     Shader neu geladen, Pools stabil' -ForegroundColor Green
Write-Host '  remove:  Shader verworfen, Pools stabil' -ForegroundColor Green
Write-Host '  new:     Shader erneut geladen, Pools stabil' -ForegroundColor Green
