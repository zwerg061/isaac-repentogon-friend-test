# Fixture-only tests for the transactional REPENTOGON DLL swap.
# No Isaac process, Steam account, game directory or real DLL is touched.
$ErrorActionPreference = 'Stop'

$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Run-TempModProfile.ps1'
$match = [regex]::Match([IO.File]::ReadAllText($runner), '(?s)# --- SWAP LIBRARY BEGIN.*?# --- SWAP LIBRARY END ---')
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

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('modsync-dll-swap-fixture-' + [Guid]::NewGuid().ToString('N'))
$stateDir = Join-Path $fixture 'state'
[IO.Directory]::CreateDirectory($stateDir) | Out-Null
$script:SessionStatePath = Join-Path $stateDir 'active-session.json'
$script:SwapJournalPath = Join-Path $stateDir 'swap.journal'
$script:SwapLockPath = Join-Path $stateDir 'session.lock'
$script:TempSessionsRoot = Join-Path $fixture 'sessions'
$script:DataRootPath = Join-Path $fixture 'data'
[IO.Directory]::CreateDirectory($script:TempSessionsRoot) | Out-Null
. ([scriptblock]::Create($match.Value))

function New-DllFixtureState([string]$SessionId) {
    $dll = Join-Path $fixture 'zhlREPENTOGON.dll'
    [IO.File]::WriteAllBytes($dll, [Text.Encoding]::ASCII.GetBytes('ORIGINAL-REPENTOGON-DLL'))
    $patched = Join-Path $fixture 'patched-source.dll'
    [IO.File]::WriteAllBytes($patched, [Text.Encoding]::ASCII.GetBytes('PATCHED-REPENTOGON-DLL'))
    $originalHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    $patchHash = (Get-FileHash -LiteralPath $patched -Algorithm SHA256).Hash
    $state = [ordered]@{
        schema_version = 1
        session_id = $SessionId
        profile_name = 'dll-fixture'
        created_utc = [DateTime]::UtcNow.ToString('o')
        isaac_root = $fixture
        mods_path = (Join-Path $fixture 'mods')
        held_path = (Join-Path $fixture ('mods.modsync-original-' + $SessionId))
        stage_root = (Join-Path $script:TempSessionsRoot $SessionId)
        stage_mods = (Join-Path (Join-Path $script:TempSessionsRoot $SessionId) 'mods')
        data_path = $script:DataRootPath
        held_data_path = ($script:DataRootPath + '.modsync-original-' + $SessionId)
        stage_data = (Join-Path (Join-Path $script:TempSessionsRoot $SessionId) 'data')
        online_patch_active = $false
        repentogon_dll_path = $dll
        repentogon_held_path = ($dll + '.modsync-original-' + $SessionId)
        repentogon_original_sha256 = $originalHash
        repentogon_patch_sha256 = $patchHash
        bridge_pid = 0
        phase = 'prepared'
    }
    return @{ State = $state; Patched = $patched; OriginalHash = $originalHash; PatchHash = $patchHash }
}

function Set-SwappedDll($State, [string]$PatchedSource) {
    [IO.Directory]::CreateDirectory($State.mods_path) | Out-Null
    [IO.Directory]::CreateDirectory($State.stage_mods) | Out-Null
    [IO.Directory]::CreateDirectory($State.stage_data) | Out-Null
    Write-SessionState $State
    Remove-Item -LiteralPath $script:SwapJournalPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ($script:SwapJournalPath + '.tmp') -Force -ErrorAction SilentlyContinue
    Initialize-SwapJournal $State.session_id
    Add-JournalStep $State 'backup-repentogon-dll' 'restore-original-repentogon-dll'
    [IO.File]::Move($State.repentogon_dll_path, $State.repentogon_held_path)
    $State.phase = 'repentogon-dll-held'; Write-SessionState $State; Complete-JournalStep
    Add-JournalStep $State 'swap-repentogon-dll' 'remove-patched-repentogon-dll'
    Copy-Item -LiteralPath $PatchedSource -Destination $State.repentogon_dll_path -Force
    $State.online_patch_active = $true; Write-SessionState $State; Complete-JournalStep
}

try {
    # 1. Journal rollback restores the original DLL and removes the patched one.
    $f1 = New-DllFixtureState ([Guid]::NewGuid().ToString('N'))
    Set-SwappedDll $f1.State $f1.Patched
    if ((Get-FileHash -LiteralPath $f1.State.repentogon_dll_path -Algorithm SHA256).Hash -ne $f1.PatchHash) {
        throw 'Patched DLL was not staged.'
    }
    Invoke-JournalRollback
    if ((Get-FileHash -LiteralPath $f1.State.repentogon_dll_path -Algorithm SHA256).Hash -ne $f1.OriginalHash) {
        throw 'Journal rollback did not restore the original REPENTOGON DLL.'
    }
    if (Test-Path -LiteralPath $f1.State.repentogon_held_path) { throw 'Original DLL hold file was left behind.' }
    Write-Output 'PASS: journal rollback restores original REPENTOGON DLL'

    # 2. Explicit restore after normal game exit.
    $f2 = New-DllFixtureState ([Guid]::NewGuid().ToString('N'))
    Set-SwappedDll $f2.State $f2.Patched
    $state2 = Read-SessionState
    Restore-RepentogonDll $state2
    if ((Get-FileHash -LiteralPath $f2.State.repentogon_dll_path -Algorithm SHA256).Hash -ne $f2.OriginalHash) {
        throw 'Restore-RepentogonDll did not restore the original DLL.'
    }
    if ((Read-SessionState).online_patch_active) { throw 'online_patch_active was not cleared.' }
    Write-Output 'PASS: explicit exit-restore of original REPENTOGON DLL'

    # 3. Crash recovery restores DLL together with mods/savedata.
    $f3 = New-DllFixtureState ([Guid]::NewGuid().ToString('N'))
    Set-SwappedDll $f3.State $f3.Patched
    $recovered = Invoke-CrashRecovery $fixture
    if (-not $recovered) { throw 'Crash recovery did not detect the stale session.' }
    if ((Get-FileHash -LiteralPath $f3.State.repentogon_dll_path -Algorithm SHA256).Hash -ne $f3.OriginalHash) {
        throw 'Crash recovery did not restore the original REPENTOGON DLL.'
    }
    Write-Output 'PASS: crash recovery restores original REPENTOGON DLL'

    # 4. A tampered DLL must abort instead of deleting an unknown file.
    $f4 = New-DllFixtureState ([Guid]::NewGuid().ToString('N'))
    Set-SwappedDll $f4.State $f4.Patched
    [IO.File]::WriteAllBytes($f4.State.repentogon_dll_path, [Text.Encoding]::ASCII.GetBytes('FOREIGN-DLL'))
    $failed = $false
    try { Invoke-JournalRollback } catch { $failed = $true }
    if (-not $failed) { throw 'Tampered DLL did not abort the rollback.' }
    Write-Output 'PASS: tampered DLL aborts rollback safely'

    Write-Output 'ALL transactional REPENTOGON DLL swap fixture tests passed.'
} finally {
    if ($script:SwapLockStream) { $script:SwapLockStream.Dispose(); $script:SwapLockStream = $null }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
