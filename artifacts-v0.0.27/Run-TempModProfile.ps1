<#
.SYNOPSIS
    Exchange a host profile automatically over Steam P2P when the host enters a
    Friend lobby, stage exact mods in TEMP, and restore on game exit.

.DESCRIPTION
    Mods are executable Lua code. The host profile is reviewed and hash-pinned
    before staging. Missing Workshop items are requested from SteamCMD using only
    anonymous login; no Steam credentials or token files are read or stored.

    The game's fixed <Isaac>\mods path is temporarily moved aside and replaced by
    a junction to a generated TEMP session. On normal game exit, the original
    directory is moved back. Every step of that swap is journalled atomically; a
    failed step rolls back immediately, and a stale session from a hard crash is
    restored automatically on the next runner start (once Isaac is closed).

    Steam P2P profile transfer and the in-lobby hot reload are enabled for the
    closed v0.0.6 friend test, gated by a strict two-sided tool-version check.
#>
param(
    [string]$Profile,
    [string]$LocalManifest,
    [Parameter(Mandatory = $true)]
    [string]$IsaacRoot,
    [string]$Launcher = 'E:\REPENTOGONLauncher\REPENTOGONLauncher.exe',
    [string]$Python = 'py',
    [string]$SteamCmd,
    [string]$WorkshopCache,
    [string]$PatchedRepentogonDll,
    [switch]$TrustProfile,
    [switch]$RestoreOnly,
    [switch]$HostMode,
    [switch]$WaitForHostProfile,
    [switch]$SandboxOptIn,
    [ValidateRange(60, 86400)]
    [int]$WaitTimeout = 1800
)

$ErrorActionPreference = 'Stop'
$script:SessionStatePath = Join-Path $env:LOCALAPPDATA 'IsaacModSync\active-session.json'
$script:SwapJournalPath = Join-Path $env:LOCALAPPDATA 'IsaacModSync\swap.journal'
$script:SwapLockPath = Join-Path $env:LOCALAPPDATA 'IsaacModSync\session.lock'
$script:SwapLockStream = $null
$script:TempSessionsRoot = Join-Path ([IO.Path]::GetTempPath()) 'IsaacModSyncSessions'
$script:ExpectedToolVersion = '0.0.6'
$script:GameLogPath = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\log.txt'
$script:DataRootPath = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\data'

if (-not ('ModSyncTempSessionNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class ModSyncTempSessionNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveDirectory(string path);
    // MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH: atomic, durable rename.
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool MoveFileEx(string existingFile, string newFile, uint flags);
}
// Diagnostic only. Begin at EOF so an earlier game cannot produce a notice.
// A changed tail sample or a shorter file invalidates all observed state.
public sealed class ModSyncLobbyLogWatcher {
    private readonly string path;
    private long position;
    private byte[] sample = new byte[0];
    private string partial = "";
    private bool inMenu;
    private bool initialized;
    public ModSyncLobbyLogWatcher(string logPath) { path = logPath; Initialize(); }
    private void Initialize() {
        using (FileStream f = Open()) {
            if (f == null) return;
            position = f.Length;
            SaveSample(f);
            initialized = true;
        }
    }
    private FileStream Open() {
        try { return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
    }
    private void SaveSample(FileStream f) {
        int n = (int)Math.Min(256, position);
        sample = new byte[n];
        f.Position = position - n;
        int got = 0;
        while (got < n) { int r = f.Read(sample, got, n - got); if (r == 0) throw new IOException("Log changed while reading"); got += r; }
    }
    private bool SampleMatches(FileStream f) {
        if (f.Length < position) return false;
        f.Position = position - sample.Length;
        for (int i = 0; i < sample.Length; ++i) if (f.ReadByte() != sample[i]) return false;
        return true;
    }
    public string[] ReadEvents() {
        var result = new List<string>();
        using (FileStream f = Open()) {
            if (f == null) { initialized = false; position = 0; sample = new byte[0]; partial = ""; inMenu = false; return result.ToArray(); }
            if (!initialized) { position = 0; sample = new byte[0]; partial = ""; inMenu = false; initialized = true; }
            if (!SampleMatches(f)) { position = 0; sample = new byte[0]; partial = ""; inMenu = false; }
            f.Position = position;
            byte[] buffer = new byte[65536];
            int n = f.Read(buffer, 0, buffer.Length);
            position += n;
            SaveSample(f);
            partial += Encoding.ASCII.GetString(buffer, 0, n);
            int newline;
            while ((newline = partial.IndexOf('\n')) >= 0) {
                string line = partial.Substring(0, newline).TrimEnd('\r');
                partial = partial.Substring(newline + 1);
                const string prefix = "[INFO] - Lua Debug: [modsync-lobby] ";
                if (line == prefix + "lobby-menu-enter=17") { inMenu = true; result.Add("menu-enter"); }
                else if (inMenu && line.StartsWith(prefix + "lobby-menu-exit=", StringComparison.Ordinal)) {
                    int menu;
                    if (Int32.TryParse(line.Substring((prefix + "lobby-menu-exit=").Length), out menu) && menu >= 0) {
                        inMenu = false; result.Add("menu-exit");
                    }
                }
            }
            if (partial.Length > 65536) { partial = ""; inMenu = false; throw new IOException("Overlong lobby log line"); }
        }
        return result.ToArray();
    }
}
'@
}

# --- SWAP LIBRARY BEGIN (fixture-tests extract this region) ---
function Get-NormalizedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-IsJunctionTo([string]$LinkPath, [string]$ExpectedTarget) {
    $item = Get-Item -LiteralPath $LinkPath -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { return $false }
    $target = @($item.Target) | Select-Object -First 1
    if (-not $target) { return $false }
    return [string]::Equals(
        (Get-NormalizedPath $target),
        (Get-NormalizedPath $ExpectedTarget),
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Remove-VerifiedJunction([string]$LinkPath, [string]$ExpectedTarget) {
    if (-not (Test-IsJunctionTo $LinkPath $ExpectedTarget)) {
        throw "Sicherheitsabbruch: $LinkPath ist nicht die erwartete Junction auf $ExpectedTarget."
    }
    if (-not [ModSyncTempSessionNative]::RemoveDirectory($LinkPath)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Temp-Mod-Junction konnte nicht entfernt werden (Win32 $code): $LinkPath"
    }
}

function Read-SessionState {
    if (-not (Test-Path -LiteralPath $script:SessionStatePath)) { return $null }
    try {
        return Get-Content -LiteralPath $script:SessionStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Temp-Mod-Sitzungsstatus ist unlesbar. Nichts wurde veraendert: $script:SessionStatePath"
    }
}

function Write-AtomicFile([string]$Path, [byte[]]$Bytes) {
    # Never write state in place: a torn write after a crash must be impossible.
    # Write to a sibling temp file, flush to disk, then atomically replace.
    # Defender can briefly hold a freshly written REPENTOGON DLL (or a sibling
    # file) open, so a transient ACCESS_DENIED/SHARING_VIOLATION is retried.
    $temp = $Path + '.tmp'
    for ($attempt = 0; $attempt -lt 6; $attempt++) {
        $code = 0
        try {
            $stream = [IO.File]::Open($temp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
            finally { $stream.Dispose() }
            if ([ModSyncTempSessionNative]::MoveFileEx($temp, $Path, 0x9)) { return }
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        } catch {
            $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        }
        if ($code -ne 5 -and $code -ne 32) {
            throw "Atomares Schreiben fehlgeschlagen (Win32 $code): $Path"
        }
        Start-Sleep -Milliseconds 150
    }
    throw "Atomares Schreiben fehlgeschlagen nach 6 Versuchen (Win32 $code): $Path"
}

function Write-SessionState($State, [switch]$CreateNew) {
    $json = $State | ConvertTo-Json -Depth 8
    Write-AtomicFile -Path $script:SessionStatePath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Read-SwapJournal {
    if (-not (Test-Path -LiteralPath $script:SwapJournalPath)) { return $null }
    try { return Get-Content -LiteralPath $script:SwapJournalPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Write-SwapJournal($Journal) {
    $json = $Journal | ConvertTo-Json -Depth 8
    Write-AtomicFile -Path $script:SwapJournalPath -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Initialize-SwapJournal([string]$SessionId) {
    Write-SwapJournal ([ordered]@{ schema_version = 1; session_id = $SessionId; entries = @() })
}

function Add-JournalStep($State, [string]$Action, [string]$Undo) {
    $journal = Read-SwapJournal
    if (-not $journal -or $journal.session_id -ne $State.session_id) {
        throw 'Swap-Journal fehlt oder gehoert zu einer anderen Session.'
    }
    $entries = @($journal.entries)
    $entries += [ordered]@{
        seq        = $entries.Count + 1
        action     = $Action
        undo       = $Undo
        status     = 'pending'
        utc        = [DateTime]::UtcNow.ToString('o')
        utc_done   = $null
        mods_path      = $State.mods_path
        held_path      = $State.held_path
        stage_mods     = $State.stage_mods
        data_path      = $State.data_path
        held_data_path = $State.held_data_path
        stage_data     = $State.stage_data
        repentogon_dll_path = $State.repentogon_dll_path
        repentogon_held_path = $State.repentogon_held_path
        repentogon_original_sha256 = $State.repentogon_original_sha256
        repentogon_patch_sha256 = $State.repentogon_patch_sha256
    }
    $journal.entries = $entries
    Write-SwapJournal $journal
    Write-Host "Journal: $Action (Schritt $($entries.Count))" -ForegroundColor DarkCyan
}

function Complete-JournalStep {
    $journal = Read-SwapJournal
    if (-not $journal) { throw 'Swap-Journal fehlt beim Abschluss eines Schritts.' }
    $entries = @($journal.entries)
    if ($entries.Count -eq 0) { throw 'Swap-Journal hat keinen offenen Schritt.' }
    $entries[-1].status = 'done'
    $entries[-1].utc_done = [DateTime]::UtcNow.ToString('o')
    $journal.entries = $entries
    Write-SwapJournal $journal
}

function Invoke-JournalRollback {
    $journal = Read-SwapJournal
    if (-not $journal) { return }
    $entries = @($journal.entries)
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $entry = $entries[$i]
        if ($entry.status -ne 'done') { continue }
        switch ($entry.undo) {
            'remove-junction' {
                if (Test-IsJunctionTo $entry.mods_path $entry.stage_mods) {
                    Remove-VerifiedJunction $entry.mods_path $entry.stage_mods
                    Write-Host "Journal-Rollback: Temp-Junction entfernt: $($entry.mods_path)"
                }
            }
            'move-held-to-mods' {
                if ((Test-Path -LiteralPath $entry.held_path) -and -not (Test-Path -LiteralPath $entry.mods_path)) {
                    [IO.Directory]::Move($entry.held_path, $entry.mods_path)
                    Write-Host "Journal-Rollback: Original-Mods zurueckverschoben: $($entry.mods_path)"
                }
            }
            'remove-data-junction' {
                if (Test-IsJunctionTo $entry.data_path $entry.stage_data) {
                    Remove-VerifiedJunction $entry.data_path $entry.stage_data
                    Write-Host "Journal-Rollback: SaveData-Junction entfernt: $($entry.data_path)"
                }
            }
            'move-held-data-to-data' {
                if ((Test-Path -LiteralPath $entry.held_data_path) -and -not (Test-Path -LiteralPath $entry.data_path)) {
                    [IO.Directory]::Move($entry.held_data_path, $entry.data_path)
                    Write-Host "Journal-Rollback: Original-SaveData zurueckverschoben: $($entry.data_path)"
                }
            }
            'remove-patched-repentogon-dll' {
                $target = $entry.repentogon_dll_path
                if ($target -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                    if ($actual -ne $entry.repentogon_patch_sha256) {
                        throw "Sicherheitsabbruch: gepatchte DLL am Ziel hat unerwarteten Hash: $target"
                    }
                    Remove-Item -LiteralPath $target -Force
                    Write-Host "Journal-Rollback: gepatchte DLL entfernt: $target"
                }
            }
            'restore-original-repentogon-dll' {
                $target = $entry.repentogon_dll_path
                $held = $entry.repentogon_held_path
                if ($held -and (Test-Path -LiteralPath $held -PathType Leaf)) {
                    $actual = (Get-FileHash -LiteralPath $held -Algorithm SHA256).Hash
                    if ($actual -ne $entry.repentogon_original_sha256) {
                        throw "Sicherheitsabbruch: gesicherte Original-DLL hat unerwarteten Hash: $held"
                    }
                    if ($target -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                        $current = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
                        if ($current -ne $entry.repentogon_patch_sha256) {
                            throw "Sicherheitsabbruch: Ziel-DLL wurde extern geaendert: $target"
                        }
                        Remove-Item -LiteralPath $target -Force
                    }
                    [IO.File]::Move($held, $target)
                    Write-Host "Journal-Rollback: Original-DLL wiederhergestellt: $target"
                }
            }
        }
    }
    Remove-Item -LiteralPath $script:SwapJournalPath -Force -ErrorAction SilentlyContinue
}

function Acquire-SwapLock {
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $stream = [IO.File]::Open($script:SwapLockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $owner = (@($PID, [DateTime]::UtcNow.ToString('o')) -join "`n")
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($owner)
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
            $script:SwapLockStream = $stream
            return
        } catch [IO.IOException] {
            $ownerPid = 0
            try {
                $lines = @(Get-Content -LiteralPath $script:SwapLockPath -ErrorAction Stop)
                if ($lines.Count -gt 0) { $ownerPid = [int]$lines[0] }
            } catch {}
            if ($ownerPid -gt 0 -and (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue)) {
                throw "Ein anderer IsaacModSync-Runner laeuft bereits (PID $ownerPid). Kein Swap ausgefuehrt."
            }
            # Lock eines hart abgestuerzten Runners: verwaist, darf uebernommen werden.
            Remove-Item -LiteralPath $script:SwapLockPath -Force -ErrorAction SilentlyContinue
        }
    }
    throw 'Swap-Lock konnte nach drei Versuchen nicht erworben werden.'
}

function Release-SwapLock {
    if ($script:SwapLockStream) { $script:SwapLockStream.Dispose(); $script:SwapLockStream = $null }
    Remove-Item -LiteralPath $script:SwapLockPath -Force -ErrorAction SilentlyContinue
}

function Get-RunningIsaac {
    return @(Get-Process -Name 'isaac-ng' -ErrorAction SilentlyContinue)
}

function Get-LobbyIdFromLog([string]$LogPath) {
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $null }
    $lines = @(Get-Content -LiteralPath $LogPath -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue)
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'Successfully joined lobby (\d{10,20})') { return $Matches[1] }
    }
    return $null
}

function Wait-LobbyId([string]$LogPath, [int]$TimeoutSeconds, [string]$Activity) {
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSeconds) {
        $lobbyId = Get-LobbyIdFromLog $LogPath
        if ($lobbyId) {
            Write-Progress -Activity $Activity -Completed
            return $lobbyId
        }
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $percent = [Math]::Min(99, [int](100 * $elapsed / $TimeoutSeconds))
        Write-Progress -Activity $Activity `
            -Status "Warte auf den Lobby-Beitritt im Spiel-Log ($elapsed/$TimeoutSeconds s)" `
            -PercentComplete $percent
        Start-Sleep -Seconds 1
    }
    Write-Progress -Activity $Activity -Completed
    throw "Keine private Freund-Lobby im Spiel-Log gefunden (Timeout ${TimeoutSeconds}s). Profil wurde nicht gesendet, keine Mods gestaget."
}

function Test-SessionPaths($State, [string]$ExpectedIsaacRoot) {
    foreach ($key in @('session_id', 'isaac_root', 'mods_path', 'held_path', 'stage_root', 'stage_mods', 'data_path', 'held_data_path', 'stage_data', 'phase')) {
        if ($null -eq $State.$key) { throw "Temp-Mod-Sitzungsstatus unvollstaendig ($key)." }
    }
    if ($State.session_id -notmatch '^[a-f0-9]{32}$') { throw 'Ungueltige Session-ID im Sitzungsstatus.' }
    $root = Get-NormalizedPath $ExpectedIsaacRoot
    $expectedMods = Get-NormalizedPath (Join-Path $root 'mods')
    $expectedHeld = Get-NormalizedPath ($expectedMods + '.modsync-original-' + $State.session_id)
    $expectedStageRoot = Get-NormalizedPath (Join-Path $script:TempSessionsRoot $State.session_id)
    $expectedStageMods = Get-NormalizedPath (Join-Path $expectedStageRoot 'mods')
    $expectedData = Get-NormalizedPath $script:DataRootPath
    $expectedHeldData = Get-NormalizedPath ($expectedData + '.modsync-original-' + $State.session_id)
    $expectedStageData = Get-NormalizedPath (Join-Path $expectedStageRoot 'data')
    if (-not [string]::Equals((Get-NormalizedPath $State.isaac_root), $root, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.mods_path), $expectedMods, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.held_path), $expectedHeld, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.stage_root), $expectedStageRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.stage_mods), $expectedStageMods, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.data_path), $expectedData, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.held_data_path), $expectedHeldData, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-NormalizedPath $State.stage_data), $expectedStageData, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Sitzungsstatus passt nicht zu den erwarteten Spiel-/Temp-Pfaden. Nichts wurde veraendert.'
    }
}

function Remove-OwnedTempSession($State) {
    $sessionRoot = Get-NormalizedPath $State.stage_root
    $expectedRoot = Get-NormalizedPath (Join-Path $script:TempSessionsRoot $State.session_id)
    if (-not [string]::Equals($sessionRoot, $expectedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Temp-Ordner liegt nicht im verwalteten IsaacModSyncSessions-Ordner; nichts geloescht.'
    }
    $ownerPath = Join-Path $sessionRoot 'session-owner.json'
    if (-not (Test-Path -LiteralPath $ownerPath)) {
        Write-Warning "Temp-Kopie bleibt zur manuellen Pruefung erhalten (Besitznachweis fehlt): $sessionRoot"
        return
    }
    $owner = Get-Content -LiteralPath $ownerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($owner.session_id -ne $State.session_id) {
        Write-Warning "Temp-Kopie bleibt erhalten (Session-ID stimmt nicht): $sessionRoot"
        return
    }
    Remove-Item -LiteralPath $sessionRoot -Recurse -Force
    Write-Host "Temp-Mod-Kopie nach Wiederherstellung entfernt: $sessionRoot"
}

function Restore-OriginalMods($State, [string]$ExpectedIsaacRoot) {
    if (Get-RunningIsaac) {
        throw 'Isaac laeuft noch. Erst das Spiel schliessen, dann -RestoreOnly erneut ausfuehren.'
    }
    Test-SessionPaths $State $ExpectedIsaacRoot
    if ($State.bridge_pid -and [int]$State.bridge_pid -gt 0) {
        $bridge = Get-Process -Id ([int]$State.bridge_pid) -ErrorAction SilentlyContinue
        if ($bridge) {
            $expectedBridge = Get-NormalizedPath (Join-Path $PSScriptRoot 'SteamModProfileBridge.exe')
            $actualBridge = $null
            try { $actualBridge = Get-NormalizedPath $bridge.Path } catch {}
            if ($actualBridge -and [string]::Equals($actualBridge, $expectedBridge, [StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $bridge.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $modsPath = $State.mods_path
    $heldPath = $State.held_path
    $stageMods = $State.stage_mods
    $modsIsStageJunction = Test-IsJunctionTo $modsPath $stageMods
    $modsExists = (Test-Path -LiteralPath $modsPath) -or $modsIsStageJunction
    $heldExists = Test-Path -LiteralPath $heldPath

    if ($modsIsStageJunction) {
        if (-not $heldExists) { throw "Originaler Mods-Ordner fehlt am Haltepfad: $heldPath" }
        Remove-VerifiedJunction $modsPath $stageMods
        $modsExists = $false
    } elseif ($modsExists -and $heldExists) {
        throw "Sicherheitsabbruch: Mods-Pfad und Original-Haltepfad existieren beide. Nichts geloescht: $heldPath"
    } elseif (-not $modsExists -and -not $heldExists) {
        throw "Sicherheitsabbruch: Sowohl Mods-Pfad als auch Original-Haltepfad fehlen. Status bleibt erhalten: $script:SessionStatePath"
    }
    if (-not $modsExists -and $heldExists) {
        [IO.Directory]::Move($heldPath, $modsPath)
        Write-Host "Urspruenglicher Mods-Ordner wiederhergestellt: $modsPath"
    } else {
        Write-Host 'Originaler Mods-Pfad ist vorhanden; kein Junction-Eingriff erforderlich.'
    }

    # Isoliertes Mod-SaveData (data/) gehoert zur Temp-Session und muss ebenso
    # journaled zurueckgerollt werden wie der Mods-Ordner.
    $dataPath = $State.data_path
    $heldDataPath = $State.held_data_path
    $stageData = $State.stage_data
    $dataIsStageJunction = Test-IsJunctionTo $dataPath $stageData
    $dataExists = (Test-Path -LiteralPath $dataPath) -or $dataIsStageJunction
    $heldDataExists = Test-Path -LiteralPath $heldDataPath
    if ($dataIsStageJunction) {
        if (-not $heldDataExists) { throw "Originaler Data-Ordner fehlt am Haltepfad: $heldDataPath" }
        Remove-VerifiedJunction $dataPath $stageData
        $dataExists = $false
    } elseif ($dataExists -and $heldDataExists) {
        throw "Sicherheitsabbruch: Data-Pfad und Original-Haltepfad existieren beide. Nichts geloescht: $heldDataPath"
    }
    if (-not $dataExists -and $heldDataExists) {
        [IO.Directory]::Move($heldDataPath, $dataPath)
        Write-Host "Urspruenglicher Mod-SaveData-Ordner wiederhergestellt: $dataPath"
    }

    Remove-OwnedTempSession $State
    Remove-Item -LiteralPath $script:SessionStatePath -Force
}

function Invoke-RestoreOnly {
    $state = Read-SessionState
    if (-not $state) {
        Write-Host 'Keine offene Temp-Mod-Session; nichts zu tun.'
        return
    }
    Invoke-JournalRollback
    Restore-RepentogonDll $state
    Restore-OriginalMods $state $IsaacRoot
}

function Invoke-SandboxHotReload {
    # The REPENTOGON prototype resets the file map and shader cache so the staged
    # TEMP mod set is re-read without closing Isaac. Only reachable after the
    # two-sided v0.0.6 version check has passed (-HotReloadEnabled).
    param([string]$IsaacRoot)
    $state = Read-SessionState
    if (-not $state) { throw 'Keine offene Temp-Mod-Session fuer Hot-Reload.' }
    Test-SessionPaths $state $IsaacRoot
    $stageMods = $state.stage_mods
    if (-not (Test-Path -LiteralPath $stageMods -PathType Container)) { throw 'Temp-Mod-Stage fehlt fuer Hot-Reload.' }
    Write-Host "Sandbox-Hot-Reload: staged Mod-Set zuruecksetzen und neu einlesen: $stageMods" -ForegroundColor Cyan
}

function Get-RepentogonDllPath([string]$Root) {
    # Real Steam installs keep REPENTOGON files in the game root; the isolated
    # sandbox build keeps them in a "Repentogon" subfolder.
    foreach ($candidate in @(
        (Join-Path $Root 'zhlREPENTOGON.dll'),
        (Join-Path $Root 'Repentogon\zhlREPENTOGON.dll')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Restore-RepentogonDll($State) {
    if (-not $State -or -not $State.online_patch_active) { return }
    $target = $State.repentogon_dll_path
    $held = $State.repentogon_held_path
    if (-not $target -or -not $held) { throw 'Online-Patch-Status unvollstaendig (DLL-Pfade fehlen).' }
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $current = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($current -eq $State.repentogon_original_sha256) {
            # Der Journal-Rollback hat die DLL bereits zurueckgesetzt.
            $State.online_patch_active = $false
            if (Test-Path -LiteralPath $script:SessionStatePath) { Write-SessionState $State }
            return
        }
        if ($current -ne $State.repentogon_patch_sha256) {
            throw "Sicherheitsabbruch: Ziel-DLL wurde extern geaendert: $target"
        }
        Remove-Item -LiteralPath $target -Force
    }
    if (Test-Path -LiteralPath $held -PathType Leaf) {
        $original = (Get-FileHash -LiteralPath $held -Algorithm SHA256).Hash
        if ($original -ne $State.repentogon_original_sha256) {
            throw "Sicherheitsabbruch: gesicherte Original-DLL hat unerwarteten Hash: $held"
        }
        [IO.File]::Move($held, $target)
        Write-Host "Original-REPENTOGON-DLL wiederhergestellt: $target" -ForegroundColor Green
    }
    $State.online_patch_active = $false
    if (Test-Path -LiteralPath $script:SessionStatePath) { Write-SessionState $State }
}

function Invoke-CrashRecovery([string]$ExpectedIsaacRoot) {
    $previousState = Read-SessionState
    if (-not $previousState) { return $false }
    if (Get-RunningIsaac) {
        throw 'Vorherige Temp-Mod-Session ist noch offen und Isaac laeuft. Erst das Spiel schliessen; der naechste Start rollt automatisch zurueck.'
    }
    Write-Host 'Crash-Rollback: verwaiste Temp-Mod-Session erkannt; Originale werden automatisch wiederhergestellt.' -ForegroundColor Yellow
    Invoke-JournalRollback
    Restore-RepentogonDll $previousState
    Restore-OriginalMods $previousState $ExpectedIsaacRoot
    Write-Host 'Crash-Rollback abgeschlossen: Original-Mods und REPENTOGON-DLL sind wieder aktiv.' -ForegroundColor Green
    return $true
}
# --- SWAP LIBRARY END ---

# --- GAME EXE SELECTION BEGIN (fixture tests extract this region) ---
function Get-GameExecutable([string]$Root) {
    $repentogonExe = Join-Path $Root 'Repentogon\isaac-ng.exe'
    if (Test-Path -LiteralPath $repentogonExe -PathType Leaf) {
        return [IO.Path]::GetFullPath($repentogonExe)
    }
    return [IO.Path]::GetFullPath((Join-Path $Root 'isaac-ng.exe'))
}
# --- GAME EXE SELECTION END ---

Acquire-SwapLock
$isaacRoot = Get-NormalizedPath $IsaacRoot

if ($RestoreOnly) {
    try { Invoke-RestoreOnly }
    finally { Release-SwapLock }
    exit 0
}

# A hard game crash can leave a junction pointing at the TEMP stage. The next
# runner start rolls it back automatically as soon as Isaac is no longer alive.
if (Test-Path -LiteralPath $script:SessionStatePath) {
    try { Invoke-CrashRecovery $isaacRoot | Out-Null }
    catch {
        Write-Warning "Crash-Rollback fehlgeschlagen: $($_.Exception.Message). Bitte manuell -RestoreOnly ausfuehren."
        Release-SwapLock
        throw
    }
}
if (Test-Path -LiteralPath $script:SwapJournalPath) {
    Remove-Item -LiteralPath $script:SwapJournalPath -Force -ErrorAction SilentlyContinue
}

$profilePath = if ($Profile) { [IO.Path]::GetFullPath($Profile) } else { $null }
$modsPath = Join-Path $isaacRoot 'mods'
# Der Online-Unlock-Patch (Menu_Online / UnknownJoinLobby / online_mods_check)
# ist gegen die REPENTOGON-EXE v1.9.7.12.J273 gebaut. Die Root-EXE ist
# v1.9.7.19.J510 und zeigt mit aktiven Mods sonst
# "Change the Launch Mode to Vanilla ... to play Online".
# Deshalb immer die REPENTOGON-EXE bevorzugen, wenn sie installiert ist.
$gameExe = Get-GameExecutable $isaacRoot
$launcherPath = [IO.Path]::GetFullPath($Launcher)
$modsyncPath = Join-Path $PSScriptRoot 'modsync.py'
$bridgePath = Join-Path $PSScriptRoot 'SteamModProfileBridge.exe'
$resyncScriptPath = Join-Path $PSScriptRoot 'Resync-ProfileAndSaveData.ps1'
$appIdFile = Join-Path $PSScriptRoot 'steam_appid.txt'

# Transaktionaler REPENTOGON-Online-Patch: Nur wenn eine gepatchte DLL explizit
# uebergeben wurde. Original und Core-Dateien MUESSEN vorhanden sein, sonst
# wird nichts geaendert und der Start abgebrochen.
$onlinePatchEnabled = $false
$patchedSource = $null
$repentogonDllPath = $null
$repentogonHeldPath = $null
$repentogonOriginalHash = $null
$repentogonPatchHash = $null
if ($PatchedRepentogonDll) {
    $patchedSource = [IO.Path]::GetFullPath($PatchedRepentogonDll)
    if (-not (Test-Path -LiteralPath $patchedSource -PathType Leaf)) { throw "Gepatchte REPENTOGON-DLL fehlt: $patchedSource" }
    $repentogonDllPath = Get-RepentogonDllPath $isaacRoot
    if (-not $repentogonDllPath) {
        throw "REPENTOGON ist nicht installiert (zhlREPENTOGON.dll fehlt): $isaacRoot"
    }
    $repentogonFolder = Split-Path -Parent $repentogonDllPath
    foreach ($required in @('zhlLoader.dll', 'libzhl.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $repentogonFolder $required) -PathType Leaf)) {
            throw "REPENTOGON-Core-Datei fehlt: $required"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repentogonFolder 'resources\scripts\main_ex.lua') -PathType Leaf)) {
        throw 'REPENTOGON-Resources fehlen (resources\scripts\main_ex.lua).'
    }
    $repentogonOriginalHash = (Get-FileHash -LiteralPath $repentogonDllPath -Algorithm SHA256).Hash
    $repentogonPatchHash = (Get-FileHash -LiteralPath $patchedSource -Algorithm SHA256).Hash
    if ($repentogonOriginalHash -eq $repentogonPatchHash) {
        # Dauerhafter Patch (v0.0.20) ist bereits installiert. Ein zweiter Swap
        # wuerde die gepatchte DLL als "Original" sichern und beim Restore genau
        # diese wieder einsetzen (oder an Lockfiles scheitern) -> Exit 1.
        # Deshalb: kein Swap, die vorhandene gepatchte DLL bleibt aktiv.
        Write-Host 'Ziel-DLL ist bereits gepatcht (dauerhafter Patch aktiv) - kein DLL-Swap.' -ForegroundColor Green
        $onlinePatchEnabled = $false
    } else {
        $onlinePatchEnabled = $true
    }
}

if ($HostMode -and $WaitForHostProfile) { throw 'HostMode und WaitForHostProfile sind gegenseitig ausschliessend.' }
if ($HostMode -and $Profile) { throw 'HostMode erstellt das Profil lokal; --Profile nicht angeben.' }
if ($WaitForHostProfile -and $Profile) { throw 'WaitForHostProfile empfaengt das Profil automatisch; --Profile nicht angeben.' }
$autoLobbySyncRequested = [bool]($HostMode -or $WaitForHostProfile)
$hotReloadEnabled = $false

# Ein klarer, zweiseitiger Versions-Check ist die einzige Freigabe fuer den
# geschlossenen Freundestest. -SandboxOptIn bleibt nur als veralteter, wirkungsloser
# Schalter erhalten, damit bestehende Aufrufe nicht brechen.
$versionFile = Join-Path $PSScriptRoot 'VERSION'
if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    $fileVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    if ($fileVersion -match '^\d+\.\d+\.\d+$') { $script:ExpectedToolVersion = $fileVersion }
}
if ($autoLobbySyncRequested) {
    $bridgeVersion = (Get-Item -LiteralPath $bridgePath).VersionInfo.ProductVersion
    if ($bridgeVersion -ne $script:ExpectedToolVersion) {
        throw "Versionskonflikt: SteamModProfileBridge v$bridgeVersion passt nicht zu Runner v$($script:ExpectedToolVersion). Kein Profil gesendet, kein Download gestartet, Installation unveraendert."
    }
    Write-Host "Versions-Check OK: Runner und Steam-P2P-Companion sind v$($script:ExpectedToolVersion)." -ForegroundColor Green
}
if (-not $HostMode -and -not $WaitForHostProfile -and -not $Profile) {
    throw 'Modus fehlt: entweder -HostMode (Profil lokal erzeugen), -WaitForHostProfile (Steam-P2P) oder -Profile (manuell).'
}
$manifestPath = if ($LocalManifest) { [IO.Path]::GetFullPath($LocalManifest) } else { $null }
if ($manifestPath -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Lokales Manifest fehlt: $manifestPath" }
if (-not (Test-Path -LiteralPath $modsyncPath -PathType Leaf)) { throw "modsync.py fehlt neben diesem Runner: $modsyncPath" }
if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf)) { throw "REPENTOGON-Spiel-EXE fehlt: $gameExe" }
if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) { throw "REPENTOGON-Launcher fehlt: $launcherPath" }
if (($HostMode -or $WaitForHostProfile) -and (-not (Test-Path -LiteralPath $bridgePath -PathType Leaf) -or -not (Test-Path -LiteralPath $appIdFile -PathType Leaf))) {
    throw 'SteamModProfileBridge.exe oder steam_appid.txt fehlt neben diesem Runner.'
}
if (-not (Test-Path -LiteralPath $modsPath -PathType Container)) { throw "Isaac-Mods-Ordner fehlt: $modsPath" }
if ((Get-Item -LiteralPath $modsPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Mods-Pfad ist bereits eine Junction/ein Link; Sicherheitsabbruch: $modsPath"
}
if (Get-RunningIsaac) { throw 'Isaac laeuft bereits. Erst das Spiel schliessen.' }
if (Test-Path -LiteralPath $script:SessionStatePath) {
    throw "Vorherige Temp-Mod-Session noch offen. Isaac schliessen und ausfuehren: .\Run-TempModProfile.ps1 -IsaacRoot `"$isaacRoot`" -RestoreOnly"
}

$pythonCommand = Get-Command $Python -ErrorAction Stop
$pythonExe = $pythonCommand.Source
if (-not $pythonExe) { throw "Python-Programm muss eine EXE-Datei sein: $Python" }
$steamCmdPath = $SteamCmd
if (-not $steamCmdPath) {
    $steamCmdCommand = Get-Command 'steamcmd.exe' -ErrorAction SilentlyContinue
    if ($steamCmdCommand) { $steamCmdPath = $steamCmdCommand.Source }
    if (-not $steamCmdPath) {
        foreach ($candidate in @(
            'C:\steamcmd\steamcmd.exe',
            (Join-Path $env:ProgramFiles 'SteamCMD\steamcmd.exe'),
            (Join-Path $env:LOCALAPPDATA 'SteamCMD\steamcmd.exe')
        )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $steamCmdPath = $candidate
                break
            }
        }
    }
}
$sessionId = [Guid]::NewGuid().ToString('N')
if ($onlinePatchEnabled) {
    $repentogonHeldPath = $repentogonDllPath + '.modsync-original-' + $sessionId
    if (Test-Path -LiteralPath $repentogonHeldPath) { throw "Original-DLL-Haltepfad existiert bereits: $repentogonHeldPath" }
}
$sessionRoot = Join-Path $script:TempSessionsRoot $sessionId
$stageMods = Join-Path $sessionRoot 'mods'
$temporaryManifest = $null
$temporaryProfile = $null
$waitRoot = $null
$stageCreated = $false
$waitRootCreated = $false
$workshopRoot = $WorkshopCache
if (-not $workshopRoot) {
    $steamApps = Split-Path -Parent (Split-Path -Parent $isaacRoot)
    $workshopRoot = Join-Path $steamApps 'workshop\content\250900'
}

New-Item -ItemType Directory -Force -Path $script:TempSessionsRoot | Out-Null
try {
    if (-not $manifestPath) {
        $temporaryManifest = Join-Path $script:TempSessionsRoot ($sessionId + '.local-manifest.json')
        $gameLog = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\log.txt'
        if (-not (Test-Path -LiteralPath $gameLog -PathType Leaf)) { throw "Isaac-Spiel-Log fehlt: $gameLog" }
        $createManifestArgs = @(
            $modsyncPath, 'create', '--mods-dir', $modsPath, '--log', $gameLog,
            '--repentogon-dir', (Join-Path $isaacRoot 'Repentogon'), '--allow-empty', '--output', $temporaryManifest
        )
        & $pythonExe @createManifestArgs
        if ($LASTEXITCODE -ne 0) { throw "Lokales Manifest konnte nicht erstellt werden (Exit $LASTEXITCODE)." }
        $manifestPath = $temporaryManifest
    }

    if ($HostMode) {
        $temporaryProfile = Join-Path $script:TempSessionsRoot ($sessionId + '.host-profile.json')
        $createProfileArgs = @(
            $modsyncPath, 'profile', 'create', '--manifest', $manifestPath,
            '--name', 'Friend co-op', '--output', $temporaryProfile
        )
        & $pythonExe @createProfileArgs
        if ($LASTEXITCODE -ne 0) { throw "Lokales Host-Profil konnte nicht erstellt werden (Exit $LASTEXITCODE)." }
        $profilePath = $temporaryProfile
    } elseif ($WaitForHostProfile) {
        $waitRoot = Join-Path $script:TempSessionsRoot ($sessionId + '-inbox')
        New-Item -ItemType Directory -Path $waitRoot | Out-Null
        $waitRootCreated = $true
        Write-Host 'Warte auf Host-Profil ueber Steam-P2P; der Host muss seine Friend-Lobby oeffnen...'
        $clientLobbyId = Wait-LobbyId -LogPath $script:GameLogPath -TimeoutSeconds $WaitTimeout -Activity 'Steam-P2P Lobby (Client)'
        Write-Host "Private Freund-Lobby erkannt: $clientLobbyId" -ForegroundColor Green
        $bridgeArgs = @(
            '--mode', 'client', '--isaac-root', "`"$isaacRoot`"",
            '--session', "`"$waitRoot`"", '--lobby-id', $clientLobbyId,
            '--expected-version', $script:ExpectedToolVersion,
            '--resync-script', "`"$resyncScriptPath`"", '--game-log', "`"$script:GameLogPath`"",
            '--timeout', [string]$WaitTimeout
        )
        $bridgeWait = Start-Process -FilePath $bridgePath -ArgumentList $bridgeArgs -Wait -PassThru -NoNewWindow `
            -WorkingDirectory $PSScriptRoot
        if ($bridgeWait.ExitCode -ne 0) { throw "Kein Host-Profil empfangen (Steam-P2P Exit $($bridgeWait.ExitCode))." }
        $profilePath = Join-Path $waitRoot 'received-host-profile.json'
        $senderInfo = Join-Path $waitRoot 'received-host-profile-sender.txt'
        if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw 'Steam-P2P meldete Erfolg, aber das Profil fehlt.' }
        if (Test-Path -LiteralPath $senderInfo) {
            $senderLines = Get-Content -LiteralPath $senderInfo -Encoding UTF8
            if ($senderLines.Count -gt 1) { Write-Host "Host-Profil empfangen von Steam-Freund: $($senderLines[1])" }
        }
    } else {
        $profilePath = [IO.Path]::GetFullPath($Profile)
    }

    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw "Host-Profil fehlt: $profilePath" }
    $profileData = Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($profileData.format -ne 'isaac-mod-profile' -or -not $profileData.profile_name -or $null -eq $profileData.mod_set) {
        throw 'Ungueltiges Host-Profil; vor Workshop-Download/Spielstart wurde nichts geaendert.'
    }
    if ($profileData.tool_version -and $profileData.tool_version -ne $script:ExpectedToolVersion) {
        throw "Versionskonflikt: Host-Profil stammt von v$($profileData.tool_version), dieser Runner ist v$($script:ExpectedToolVersion). Kein Download gestartet, Installation unveraendert."
    }
    if ($autoLobbySyncRequested) {
        if (-not $profileData.tool_version) { throw 'Versions-Check fehlgeschlagen: Das Host-Profil enthaelt keine tool_version.' }
        $hotReloadEnabled = $true
    }
    if ($HostMode -and $profileData.mod_set.Count -eq 0) {
        throw 'Host-Log enthaelt keine geladenen Mods. Isaac einmal mit dem gewuenschten Mod-Set starten und normal schliessen, dann HostMode erneut starten.'
    }
    Write-Host "Host-Profil: $($profileData.profile_name) | Mods: $($profileData.mod_set.Count)"
    Write-Host 'Mods enthalten ausfuehrbaren Lua-Code. Nur Workshop-IDs aus diesem Steam-Freund-Profil werden angefordert.'
    if (-not $HostMode -and -not $TrustProfile) {
        $answer = Read-Host 'Nur fortfahren, wenn dieses Profil von deinem vertrauten Steam-Freund stammt. Mods stagen? (J/N)'
        if ($answer -notmatch '^(j|ja|y|yes)$') { throw 'Vor Download und Spielstart abgebrochen.' }
    }

    $pythonArgs = @(
        $modsyncPath, 'profile', 'stage',
        '--profile', $profilePath,
        '--local-manifest', $manifestPath,
        '--mods-dir', $modsPath,
        '--workshop-cache', $workshopRoot,
        '--output', $sessionRoot
    )
    if ($steamCmdPath) { $pythonArgs += @('--steamcmd', [IO.Path]::GetFullPath($steamCmdPath)) }
    Write-Host 'Pruefe/verifiziere Host-Mods und erstelle eine Session-Kopie unter TEMP...'
    & $pythonExe @pythonArgs
    if ($LASTEXITCODE -ne 0) { throw "Temp-Mod-Staging fehlgeschlagen (Exit $LASTEXITCODE); Isaac-Installation blieb unveraendert." }
    $stageCreated = $true

    Write-Host 'Anti-Desync-Gate: Ladereihenfolge, Build-Hashes und Versionen werden geprueft...' -ForegroundColor Cyan
    & $pythonExe $modsyncPath 'anti-desync-check' --profile $profilePath --local-manifest $manifestPath
    if ($LASTEXITCODE -ne 0) { throw "Anti-Desync-Pruefung hat den Spielstart blockiert (Exit $LASTEXITCODE)." }
    $desyncReportPath = Join-Path $sessionRoot 'anti-desync.json'
    if (Test-Path -LiteralPath $desyncReportPath -PathType Leaf) {
        $desyncReport = Get-Content -LiteralPath $desyncReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($warning in @($desyncReport.warnings)) {
            Write-Warning "Anti-Desync-Hinweis: $warning"
        }
    }

    $sessionInfoPath = Join-Path $sessionRoot 'session.json'
    if (-not (Test-Path -LiteralPath $stageMods -PathType Container) -or -not (Test-Path -LiteralPath $sessionInfoPath -PathType Leaf)) {
        throw 'Temp-Mod-Staging unvollstaendig; Isaac-Installation blieb unveraendert.'
    }
    $sessionInfo = Get-Content -LiteralPath $sessionInfoPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($sessionInfo.format -ne 'isaac-mod-profile-session' -or
        $sessionInfo.session_id -ne $sessionId -or
        $sessionInfo.host_mod_count -ne $profileData.mod_set.Count -or
        $sessionInfo.lobby_exit_observer_count -ne 1 -or
        $sessionInfo.mods.Count -ne ($profileData.mod_set.Count + 1)) {
        throw 'Temp-Session-Manifest stimmt nicht mit dem Host-Profil ueberein; Isaac-Installation blieb unveraendert.'
    }
    Copy-Item -LiteralPath $profilePath -Destination (Join-Path $sessionRoot 'session-host-profile.json')
    $owner = @{ session_id = $sessionId; created_utc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $sessionRoot 'session-owner.json'), $owner, [Text.UTF8Encoding]::new($false))
} catch {
    if ($stageCreated -and (Test-Path -LiteralPath $sessionRoot)) { Remove-Item -LiteralPath $sessionRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($waitRootCreated -and (Test-Path -LiteralPath $waitRoot)) { Remove-Item -LiteralPath $waitRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($temporaryManifest -and (Test-Path -LiteralPath $temporaryManifest)) { Remove-Item -LiteralPath $temporaryManifest -Force -ErrorAction SilentlyContinue }
    if ($temporaryProfile -and (Test-Path -LiteralPath $temporaryProfile)) { Remove-Item -LiteralPath $temporaryProfile -Force -ErrorAction SilentlyContinue }
    throw
}
if ($waitRoot -and (Test-Path -LiteralPath $waitRoot)) { Remove-Item -LiteralPath $waitRoot -Recurse -Force }
if ($temporaryManifest -and (Test-Path -LiteralPath $temporaryManifest)) { Remove-Item -LiteralPath $temporaryManifest -Force }
if ($temporaryProfile -and (Test-Path -LiteralPath $temporaryProfile)) { Remove-Item -LiteralPath $temporaryProfile -Force }

$heldPath = $modsPath + '.modsync-original-' + $sessionId
$heldDataPath = $script:DataRootPath + '.modsync-original-' + $sessionId
$stageData = Join-Path $sessionRoot 'data'
if (Test-Path -LiteralPath $heldPath) { throw "Original-Haltepfad existiert bereits: $heldPath" }
if (Test-Path -LiteralPath $heldDataPath) { throw "Original-Data-Haltepfad existiert bereits: $heldDataPath" }
if (-not (Test-Path -LiteralPath $stageData -PathType Container)) { throw 'Isoliertes Mod-SaveData fehlt im Temp-Profil.' }
$state = [ordered]@{
    schema_version = 1
    session_id = $sessionId
    profile_name = [string]$profileData.profile_name
    created_utc = [DateTime]::UtcNow.ToString('o')
    isaac_root = $isaacRoot
    mods_path = $modsPath
    held_path = $heldPath
    stage_root = $sessionRoot
    stage_mods = $stageMods
    data_path = $script:DataRootPath
    held_data_path = $heldDataPath
    stage_data = $stageData
    online_patch_active = $false
    repentogon_dll_path = $repentogonDllPath
    repentogon_held_path = $repentogonHeldPath
    repentogon_original_sha256 = $repentogonOriginalHash
    repentogon_patch_sha256 = $repentogonPatchHash
    bridge_pid = 0
    phase = 'prepared'
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:SessionStatePath) | Out-Null
Write-SessionState $state -CreateNew

$launcherProcess = $null
$hostBridgeProcess = $null
$gameLog = Join-Path $env:USERPROFILE 'Documents\My Games\Binding of Isaac Repentance+\log.txt'
$lobbyWatcher = $null
try { $lobbyWatcher = [ModSyncLobbyLogWatcher]::new($gameLog) }
catch { Write-Warning "Lobby-Menue-Hinweis nicht verfuegbar: $($_.Exception.Message)" }
$previousSessionEnvironment = [Environment]::GetEnvironmentVariable('ISAAC_MODSYNC_SESSION', 'Process')
try {
    Initialize-SwapJournal $sessionId

    if ($onlinePatchEnabled) {
        Add-JournalStep $state 'backup-repentogon-dll' 'restore-original-repentogon-dll'
        [IO.File]::Move($repentogonDllPath, $repentogonHeldPath)
        $state.phase = 'repentogon-dll-held'
        Write-SessionState $state
        Complete-JournalStep

        Add-JournalStep $state 'swap-repentogon-dll' 'remove-patched-repentogon-dll'
        Copy-Item -LiteralPath $patchedSource -Destination $repentogonDllPath -Force
        if ((Get-FileHash -LiteralPath $repentogonDllPath -Algorithm SHA256).Hash -ne $repentogonPatchHash) {
            throw 'Gepatchte REPENTOGON-DLL konnte nach dem Kopieren nicht verifiziert werden.'
        }
        $state.online_patch_active = $true
        Write-SessionState $state
        Complete-JournalStep
        Write-Host "REPENTOGON-Online-Patch aktiv: $repentogonDllPath" -ForegroundColor Magenta
    }

    Add-JournalStep $state 'move-mods-to-held' 'move-held-to-mods'
    [IO.Directory]::Move($modsPath, $heldPath)
    $state.phase = 'original-held'
    Write-SessionState $state
    Complete-JournalStep

    Add-JournalStep $state 'create-junction' 'remove-junction'
    New-Item -ItemType Junction -Path $modsPath -Target $stageMods | Out-Null
    if (-not (Test-IsJunctionTo $modsPath $stageMods)) { throw 'Temp-Mod-Junction konnte nicht verifiziert werden.' }
    $state.phase = 'junction-active'
    Write-SessionState $state
    Complete-JournalStep

    Add-JournalStep $state 'move-data-to-held' 'move-held-data-to-data'
    if (Test-Path -LiteralPath $script:DataRootPath) {
        [IO.Directory]::Move($script:DataRootPath, $heldDataPath)
    }
    $state.phase = 'data-held'
    Write-SessionState $state
    Complete-JournalStep

    Add-JournalStep $state 'create-data-junction' 'remove-data-junction'
    New-Item -ItemType Junction -Path $script:DataRootPath -Target $stageData | Out-Null
    if (-not (Test-IsJunctionTo $script:DataRootPath $stageData)) { throw 'SaveData-Junction konnte nicht verifiziert werden.' }
    $state.phase = 'data-junction-active'
    Write-SessionState $state
    Complete-JournalStep

    $configPath = Join-Path $sessionRoot 'repentogon_launcher.ini'
    @"
[General]
IsaacExecutable = $gameExe
RanWizard = 1
HideWindow = 0
StealthMode = 0
[Repentogon]
Console = 1
Update = 0
UnstableUpdates = 0
SkipUpdateMods = 1
SkipWaitModDownloads = 1
[Vanilla]
LuaHeapSize = 1024M
LuaDebug = 0
[Shared]
LaunchMode = 0
"@ | Set-Content -LiteralPath $configPath -Encoding ASCII

    $stdoutPath = Join-Path $sessionRoot 'launcher-stdout.txt'
    $stderrPath = Join-Path $sessionRoot 'launcher-stderr.txt'
    $launchArgs = @(
        '--isaac', "`"$gameExe`"",
        '--launch-mode', 'repentogon',
        '--stealth-mode',
        '--skip-wizard', '--skip-repentogon-update',
        '--configuration-file', "`"$configPath`""
    )
    [Environment]::SetEnvironmentVariable('ISAAC_MODSYNC_SESSION', $sessionRoot, 'Process')
    Write-Host 'Starte REPENTOGON mit temporaerem Host-Mod-Set und experimentellem Lobby-Menue-Beobachter.'
    $launcherProcess = Start-Process -FilePath $launcherPath -ArgumentList $launchArgs -PassThru `
        -WorkingDirectory (Split-Path -Parent $launcherPath) `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $deadline = (Get-Date).AddSeconds(180)
    $gameProcesses = Get-RunningIsaac
    while (-not $gameProcesses -and (Get-Date) -lt $deadline) {
        if ($launcherProcess.HasExited) { break }
        Start-Sleep -Milliseconds 500
        $gameProcesses = Get-RunningIsaac
    }
    if (-not $gameProcesses) {
        $launcherProcess.Refresh()
        $status = if ($launcherProcess.HasExited) { "Launcher-Exit $($launcherProcess.ExitCode)" } else { 'Spielprozess erschien nicht innerhalb von 180 Sekunden' }
        throw "REPENTOGON-Start fehlgeschlagen: $status"
    }

    if ($HostMode) {
        $hostProfileForBridge = Join-Path $sessionRoot 'session-host-profile.json'
        $hostLobbyId = Wait-LobbyId -LogPath $script:GameLogPath -TimeoutSeconds 180 -Activity 'Steam-P2P Lobby (Host)'
        Write-Host "Private Freund-Lobby des Hosts erkannt: $hostLobbyId" -ForegroundColor Green
        $bridgeArgs = @(
            '--mode', 'host', '--isaac-root', "`"$isaacRoot`"",
            '--session', "`"$sessionRoot`"", '--profile', "`"$hostProfileForBridge`"",
            '--lobby-id', $hostLobbyId, '--expected-version', $script:ExpectedToolVersion,
            '--resync-script', "`"$resyncScriptPath`"", '--game-log', "`"$script:GameLogPath`"",
            '--timeout', '86400'
        )
        $hostBridgeProcess = Start-Process -FilePath $bridgePath -ArgumentList $bridgeArgs -PassThru -NoNewWindow `
            -WorkingDirectory $PSScriptRoot
        $state.bridge_pid = $hostBridgeProcess.Id
        Write-SessionState $state
        $bridgeReady = Join-Path $sessionRoot 'steam-bridge.ready'
        $bridgeDeadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $bridgeReady) -and (Get-Date) -lt $bridgeDeadline) {
            $hostBridgeProcess.Refresh()
            if ($hostBridgeProcess.HasExited) { break }
            $waited = [int](30 - ($bridgeDeadline - (Get-Date)).TotalSeconds)
            Write-Progress -Activity 'Steam-P2P Companion (Host)' -Status "SteamAPI-Initialisierung ($waited/30 s)" -PercentComplete ([Math]::Min(99, [int](100 * $waited / 30)))
            Start-Sleep -Milliseconds 250
        }
        Write-Progress -Activity 'Steam-P2P Companion (Host)' -Completed
        if (Test-Path -LiteralPath $bridgeReady) {
            Write-Host 'Steam-P2P-Companion bereit; Host-Profil wird erst beim ONLINELOBBY-Signal an wartende Freunde gesendet.'
        } else {
            $hostBridgeProcess.Refresh()
            $status = if ($hostBridgeProcess.HasExited) { "Exit $($hostBridgeProcess.ExitCode)" } else { 'SteamAPI-Init dauerte zu lange' }
            Write-Warning "Steam-P2P-Companion nicht bereit ($status). Das Spiel laeuft weiter, aber Profiltransfer ist aus."
        }
    }

    Write-Host "Temp-Mod-Session laeuft (Isaac PID $($gameProcesses[0].Id)). HostMode=$HostMode; beide brauchen den gleichen Runner."
    while (Get-RunningIsaac) {
        if ($hostBridgeProcess) { $hostBridgeProcess.Refresh() }
        if ($HostMode -and $hostBridgeProcess -and $hostBridgeProcess.HasExited) {
            Write-Warning "Steam-P2P-Companion wurde beendet (Exit $($hostBridgeProcess.ExitCode)); Profiltransfer ist nicht mehr aktiv."
            $hostBridgeProcess = $null
        }
        if ($lobbyWatcher) {
            try {
                foreach ($event in $lobbyWatcher.ReadEvents()) {
                    if ($event -eq 'menu-enter') {
                        if ($hotReloadEnabled) {
                            try { Invoke-SandboxHotReload -IsaacRoot $isaacRoot }
                            catch { Write-Warning "Hot-Reload fehlgeschlagen: $($_.Exception.Message)" }
                        }
                    }
                    if ($event -eq 'menu-exit') {
                        Write-Host ''
                        Write-Host 'Lobby-Menue verlassen. Isaac bleibt offen; das Host-Mod-Set bleibt aktiv.' -ForegroundColor Yellow
                        Write-Host 'Der Menuewechsel bestaetigt nicht, dass die Steam-Lobby beendet ist.' -ForegroundColor Yellow
                        Write-Host 'Beim spaeteren Schliessen von Isaac werden Original-Mods wiederhergestellt.' -ForegroundColor Yellow
                        try { $Host.UI.RawUI.WindowTitle = 'Isaac ModSync - Lobby-Menue verlassen' } catch {}
                        try { [Console]::Beep(880, 250) } catch {}
                    }
                }
            } catch {
                Write-Warning "Lobby-Menue-Hinweis ausgefallen: $($_.Exception.Message)"
                $lobbyWatcher = $null
            }
        }
        Start-Sleep -Seconds 2
    }
    Write-Host 'Isaac geschlossen; stelle Original-Mods wieder her...'
} catch {
    Write-Host 'Swap-Fehler: Journal-Rollback wird ausgefuehrt ...' -ForegroundColor Red
    if (Get-RunningIsaac) {
        Write-Warning 'Isaac laeuft noch; Temp-Junction bleibt bis zum Spielende aktiv.'
    } else {
        try { Invoke-JournalRollback }
        catch { Write-Warning "Journal-Rollback meldete einen Fehler: $($_.Exception.Message)" }
    }
    throw
} finally {
    [Environment]::SetEnvironmentVariable('ISAAC_MODSYNC_SESSION', $previousSessionEnvironment, 'Process')
    if (Get-RunningIsaac) {
        Write-Warning 'Isaac laeuft noch; Temp-Junction bleibt aktiv. Isaac schliessen und danach -RestoreOnly ausfuehren.'
    } else {
        $currentState = Read-SessionState
        if ($currentState) {
            Restore-RepentogonDll $currentState
            Restore-OriginalMods $currentState $isaacRoot
        }
        Remove-Item -LiteralPath $script:SwapJournalPath -Force -ErrorAction SilentlyContinue
    }
    Release-SwapLock
}
