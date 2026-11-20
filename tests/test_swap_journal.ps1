# Fixture-only tests for the atomic swap journal / lock / crash rollback.
# No Isaac process, Steam account, or real mod directory is touched.
$ErrorActionPreference = 'Stop'

$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Run-TempModProfile.ps1'
$source = [IO.File]::ReadAllText($runner)
$match = [regex]::Match($source, '(?s)# --- SWAP LIBRARY BEGIN.*?# --- SWAP LIBRARY END ---')
if (-not $match.Success) { throw 'Swap library region not found in runner.' }

if (-not ('ModSyncTempSessionNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ModSyncTempSessionNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveDirectory(string path);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingFile, string newFile, uint flags);
}
'@
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('modsync-swap-fixture-' + [Guid]::NewGuid().ToString('N'))
$stateDir = Join-Path $fixture 'state'
[IO.Directory]::CreateDirectory($stateDir) | Out-Null
$script:SessionStatePath = Join-Path $stateDir 'active-session.json'
$script:SwapJournalPath = Join-Path $stateDir 'swap.journal'
$script:SwapLockPath = Join-Path $stateDir 'session.lock'
$script:TempSessionsRoot = Join-Path $fixture 'sessions'
$script:ExpectedToolVersion = '0.0.6'
$script:DataRootPath = Join-Path $fixture 'data'
[IO.Directory]::CreateDirectory($script:TempSessionsRoot) | Out-Null

. ([scriptblock]::Create($match.Value))

function New-FixtureState([string]$SessionId) {
    $mods = Join-Path $fixture 'mods'
    $stageRoot = Join-Path $script:TempSessionsRoot $SessionId
    return [ordered]@{
        schema_version = 1
        session_id     = $SessionId
        profile_name   = 'fixture'
        created_utc    = [DateTime]::UtcNow.ToString('o')
        isaac_root     = $fixture
        mods_path      = $mods
        held_path      = ($mods + '.modsync-original-' + $SessionId)
        stage_root     = $stageRoot
        stage_mods     = (Join-Path $stageRoot 'mods')
        data_path      = $script:DataRootPath
        held_data_path = ($script:DataRootPath + '.modsync-original-' + $SessionId)
        stage_data     = (Join-Path $stageRoot 'data')
        bridge_pid     = 0
        phase          = 'prepared'
    }
}

function Set-SwappedFixture($State) {
    $mods = $State.mods_path
    $held = $State.held_path
    $stageMods = $State.stage_mods
    if (-not (Test-Path -LiteralPath $mods)) {
        [IO.Directory]::CreateDirectory($mods) | Out-Null
        [IO.File]::WriteAllText((Join-Path $mods 'keep.txt'), 'original')
    }
    if (-not (Test-Path -LiteralPath $stageMods)) { [IO.Directory]::CreateDirectory($stageMods) | Out-Null }
    [IO.File]::WriteAllText((Join-Path $stageMods 'staged.txt'), 'staged')
    if (-not (Test-Path -LiteralPath $State.stage_data)) { [IO.Directory]::CreateDirectory($State.stage_data) | Out-Null }
    if (-not (Test-Path -LiteralPath $State.data_path)) {
        [IO.Directory]::CreateDirectory($State.data_path) | Out-Null
        [IO.File]::WriteAllText((Join-Path $State.data_path 'persistentgamedata1.dat'), 'original-savedata')
    }
    $owner = @{ session_id = $State.session_id; created_utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $State.stage_root 'session-owner.json'), $owner, [Text.UTF8Encoding]::new($false))

    Write-SessionState $State
    Initialize-SwapJournal $State.session_id
    Add-JournalStep $State 'move-mods-to-held' 'move-held-to-mods'
    [IO.Directory]::Move($mods, $held)
    $State.phase = 'original-held'; Write-SessionState $State; Complete-JournalStep
    Add-JournalStep $State 'create-junction' 'remove-junction'
    New-Item -ItemType Junction -Path $mods -Target $stageMods | Out-Null
    if (-not (Test-IsJunctionTo $mods $stageMods)) { throw 'Junction konnte nicht verifiziert werden.' }
    $State.phase = 'junction-active'; Write-SessionState $State; Complete-JournalStep
    Add-JournalStep $State 'move-data-to-held' 'move-held-data-to-data'
    [IO.Directory]::Move($State.data_path, $State.held_data_path)
    $State.phase = 'data-held'; Write-SessionState $State; Complete-JournalStep
    Add-JournalStep $State 'create-data-junction' 'remove-data-junction'
    New-Item -ItemType Junction -Path $State.data_path -Target $State.stage_data | Out-Null
    $State.phase = 'data-junction-active'; Write-SessionState $State; Complete-JournalStep
}

function Assert-JournalDone([int]$Expected) {
    $journal = Read-SwapJournal
    $entries = @($journal.entries)
    if ($entries.Count -ne $Expected) { throw "Journal expected $Expected entries, got $($entries.Count)." }
    foreach ($entry in $entries) {
        if ($entry.status -ne 'done') { throw "Journal entry $($entry.seq) is not marked done." }
    }
}

try {
    # 1. Atomic state write: no partial file, and a corrupt file is replaced cleanly.
    $id1 = [Guid]::NewGuid().ToString('N')
    $state1 = New-FixtureState $id1
    Write-SessionState $state1 -CreateNew
    if ((Read-SessionState).session_id -ne $id1) { throw 'State round-trip failed.' }
    if (Test-Path -LiteralPath ($script:SessionStatePath + '.tmp')) { throw 'Atomic temp file was left behind.' }
    [IO.File]::WriteAllText($script:SessionStatePath, '{corrupt')
    Write-SessionState $state1
    if ((Read-SessionState).session_id -ne $id1) { throw 'Atomic replace of a corrupt state failed.' }
    Write-Output 'PASS: atomic session-state writes'

    # 2. Journal rollback reverses both swap steps in order.
    $id2 = [Guid]::NewGuid().ToString('N')
    $state2 = New-FixtureState $id2
    Set-SwappedFixture $state2
    Assert-JournalDone 4
    Invoke-JournalRollback
    if (Test-IsJunctionTo $state2.mods_path $state2.stage_mods) { throw 'Rollback left the junction in place.' }
    if (-not (Test-Path -LiteralPath (Join-Path $state2.mods_path 'keep.txt'))) { throw 'Rollback did not restore the original mods.' }
    if (Test-IsJunctionTo $state2.data_path $state2.stage_data) { throw 'Rollback left the SaveData junction in place.' }
    if (-not (Test-Path -LiteralPath (Join-Path $state2.data_path 'persistentgamedata1.dat'))) { throw 'Rollback did not restore the original SaveData.' }
    if (Test-Path -LiteralPath $script:SwapJournalPath) { throw 'Rollback did not clear the journal.' }
    Write-Output 'PASS: journal rollback of move+junction'

    # 3. Lock: live owner blocks a second runner; stale lock is reclaimed.
    Acquire-SwapLock
    if (-not (Test-Path -LiteralPath $script:SwapLockPath)) { throw 'Lock file was not created.' }
    $blocked = $false
    try { Acquire-SwapLock } catch { $blocked = $true }
    if (-not $blocked) { throw 'A second runner acquired the lock of a live owner.' }
    Release-SwapLock
    if (Test-Path -LiteralPath $script:SwapLockPath) { throw 'Lock was not released.' }
    [IO.File]::WriteAllText($script:SwapLockPath, "999999`n2026-01-01T00:00:00Z")
    Acquire-SwapLock
    Release-SwapLock
    Write-Output 'PASS: exclusive lock and stale-lock reclaim'

    # 4. Crash recovery: a stale junction-active session is restored on start.
    $id4 = [Guid]::NewGuid().ToString('N')
    $state4 = New-FixtureState $id4
    Set-SwappedFixture $state4
    $recovered = Invoke-CrashRecovery $fixture
    if (-not $recovered) { throw 'Crash recovery did not detect the stale session.' }
    if (Test-IsJunctionTo $state4.mods_path $state4.stage_mods) { throw 'Crash recovery left the junction in place.' }
    if (-not (Test-Path -LiteralPath (Join-Path $state4.mods_path 'keep.txt'))) { throw 'Crash recovery did not restore the original mods.' }
    if (-not (Test-Path -LiteralPath (Join-Path $state4.data_path 'persistentgamedata1.dat'))) { throw 'Crash recovery did not restore the original SaveData.' }
    if (Test-Path -LiteralPath $script:SessionStatePath) { throw 'Crash recovery did not clear the session state.' }
    Write-Output 'PASS: automatic crash rollback on runner start'

    Write-Output 'ALL swap journal / lock / rollback fixture tests passed.'
} finally {
    if ($script:SwapLockStream) { $script:SwapLockStream.Dispose(); $script:SwapLockStream = $null }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
