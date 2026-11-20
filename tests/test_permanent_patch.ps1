# Fixture-only end-to-end test of the permanent patch cycle:
#   Apply -> verify patched hash -> Uninstall -> verify original hash restored.
# No real Steam directory, game process, registry key or network is touched.
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Install-ModSyncPatch.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('modsync-permanent-patch-' + [Guid]::NewGuid().ToString('N'))
$isaac = Join-Path $fixture 'isaac'
$tools = Join-Path $fixture 'tools'
New-Item -ItemType Directory -Force -Path (Join-Path $isaac 'mods') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $isaac 'resources\scripts') | Out-Null
New-Item -ItemType Directory -Force -Path $tools | Out-Null

$originalBytes = [Text.Encoding]::ASCII.GetBytes('ORIGINAL-REPENTOGON-DLL-v113')
$patchedBytes = [Text.Encoding]::ASCII.GetBytes('PATCHED-REPENTOGON-DLL-v008')
$dll = Join-Path $isaac 'zhlREPENTOGON.dll'
$patched = Join-Path $tools 'patched-zhlREPENTOGON.dll'
[IO.File]::WriteAllBytes($dll, $originalBytes)
[IO.File]::WriteAllBytes($patched, $patchedBytes)
[IO.File]::WriteAllBytes((Join-Path $isaac 'isaac-ng.exe'), [Text.Encoding]::ASCII.GetBytes('fake'))
[IO.File]::WriteAllBytes((Join-Path $isaac 'zhlLoader.dll'), [Text.Encoding]::ASCII.GetBytes('loader'))
[IO.File]::WriteAllBytes((Join-Path $isaac 'libzhl.dll'), [Text.Encoding]::ASCII.GetBytes('libzhl'))
[IO.File]::WriteAllBytes((Join-Path $isaac 'resources\scripts\main_ex.lua'), [Text.Encoding]::ASCII.GetBytes('lua'))
$helper = Join-Path $isaac 'mods\zz_modsync_lobby_exit_observer'
New-Item -ItemType Directory -Force -Path $helper | Out-Null
[IO.File]::WriteAllText((Join-Path $helper 'main.lua'), 'observer')

$originalHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
$patchedHash = (Get-FileHash -LiteralPath $patched -Algorithm SHA256).Hash

$oldLocal = $env:LOCALAPPDATA
$oldAppData = $env:APPDATA
$oldTestRoot = $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT
$oldTestZip = $env:ISAAC_MODSYNC_TEST_REPENTOGON_ZIP
$oldNoLaunch = $env:ISAAC_MODSYNC_NO_LAUNCH
$env:LOCALAPPDATA = Join-Path $fixture 'localappdata'
$env:APPDATA = Join-Path $fixture 'appdata'

function Get-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

try {
    # 1. Apply
    & $scriptPath -Action Apply -IsaacRoot $isaac -ToolsRoot $tools -PatchedDll $patched -NoLaunch -NoCompanion -Quiet | Out-Null
    if ((Get-Hash $dll) -ne $patchedHash) { throw 'Apply did not install the patched DLL.' }
    $backup = "$dll.orig"
    if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw 'Apply did not create the .orig backup.' }
    if ((Get-Hash $backup) -ne $originalHash) { throw 'Backup hash does not match the original DLL.' }
    $statePath = Join-Path $env:LOCALAPPDATA 'IsaacModSync\permanent-patch.json'
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $state.applied -or $state.original_dll_sha256 -ne $originalHash) { throw 'State file is incorrect after Apply.' }
    Write-Output 'PASS: Apply installs patched DLL and verifies original backup'

    # 2. Apply is idempotent
    & $scriptPath -Action Apply -IsaacRoot $isaac -ToolsRoot $tools -PatchedDll $patched -NoLaunch -NoCompanion -Quiet | Out-Null
    if ((Get-Hash $dll) -ne $patchedHash -or (Get-Hash $backup) -ne $originalHash) { throw 'Second Apply changed the verified state.' }
    Write-Output 'PASS: Apply is idempotent'

    # 3. Status
    $status = & $scriptPath -Action Status -Quiet | ConvertFrom-Json
    if (-not $status.applied -or $status.patched_dll_sha256 -ne $patchedHash) { throw 'Status did not report the applied patch.' }
    Write-Output 'PASS: Status reports applied patch'

    # 4. Uninstall restores the exact original DLL and removes helper mods
    & $scriptPath -Action Uninstall -Quiet | Out-Null
    if ((Get-Hash $dll) -ne $originalHash) { throw 'Uninstall did not restore the exact original DLL.' }
    if (Test-Path -LiteralPath $backup) { throw 'Uninstall left the .orig backup behind.' }
    if (Test-Path -LiteralPath $statePath) { throw 'Uninstall left the state file behind.' }
    if (Test-Path -LiteralPath $helper) { throw 'Uninstall did not remove helper mods.' }
    Write-Output 'PASS: Uninstall restores original hash and removes helpers'

    # 5. Tampered backup aborts instead of writing an unknown DLL
    & $scriptPath -Action Apply -IsaacRoot $isaac -ToolsRoot $tools -PatchedDll $patched -NoLaunch -NoCompanion -Quiet | Out-Null
    [IO.File]::WriteAllBytes($backup, [Text.Encoding]::ASCII.GetBytes('TAMPERED-BACKUP'))
    $failed = $false
    try { & $scriptPath -Action Uninstall -Quiet | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Tampered backup did not abort uninstall.' }
    if ((Get-Hash $dll) -ne $patchedHash) { throw 'Failed uninstall changed the DLL.' }
    Write-Output 'PASS: tampered backup aborts uninstall safely'

    # 6. When REPENTOGON was installed by us, uninstall removes it completely.
    $freshRoot = Join-Path $fixture 'fresh-isaac'
    New-Item -ItemType Directory -Force -Path $freshRoot | Out-Null
    $addedDll = Join-Path $freshRoot 'zhlREPENTOGON.dll'
    [IO.File]::WriteAllBytes($addedDll, $patchedBytes)
    $addedLoader = Join-Path $freshRoot 'zhlLoader.dll'
    [IO.File]::WriteAllBytes($addedLoader, [Text.Encoding]::ASCII.GetBytes('loader'))
    $freshState = [ordered]@{
        schema_version = 1
        applied = $true
        isaac_root = $freshRoot
        dll_path = $addedDll
        backup_path = "$addedDll.orig"
        original_dll_sha256 = $patchedHash
        patched_dll_sha256 = $patchedHash
        repentogon_installed_by_us = $true
        installed_files = @('zhlREPENTOGON.dll', 'zhlLoader.dll')
    }
    [IO.File]::WriteAllText($statePath, ($freshState | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    & $scriptPath -Action Uninstall -Quiet | Out-Null
    if (Test-Path -LiteralPath $addedDll) { throw 'REPENTOGON DLL installed by us was not removed.' }
    if (Test-Path -LiteralPath $addedLoader) { throw 'REPENTOGON loader installed by us was not removed.' }
    Write-Output 'PASS: uninstall removes a REPENTOGON installation created by us'

    # 7. ReadOnly target + running isaac-ng: extraction and copy must survive.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fixtureZip = Join-Path $fixture 'REPENTOGON-fixture.zip'
    $officialDllBytes = [Text.Encoding]::ASCII.GetBytes('OFFICIAL-REPENTOGON-DLL-FOR-EXTRACT')
    $zipFileStream = [IO.File]::Open($fixtureZip, [IO.FileMode]::Create)
    $zip = [IO.Compression.ZipArchive]::new($zipFileStream, [IO.Compression.ZipArchiveMode]::Create)
    $entries = [ordered]@{
        'zhlREPENTOGON.dll' = $officialDllBytes
        'zhlLoader.dll' = [Text.Encoding]::ASCII.GetBytes('loader')
        'libzhl.dll' = [Text.Encoding]::ASCII.GetBytes('libzhl')
        'resources/scripts/main_ex.lua' = [Text.Encoding]::ASCII.GetBytes('lua')
    }
    foreach ($name in $entries.Keys) {
        $entry = $zip.CreateEntry($name)
        $stream = $entry.Open()
        $data = $entries[$name]
        $stream.Write($data, 0, $data.Length)
        $stream.Dispose()
    }
    $zip.Dispose()
    $zipFileStream.Dispose()

    $lockedRoot = Join-Path $fixture 'locked-isaac'
    New-Item -ItemType Directory -Force -Path (Join-Path $lockedRoot 'resources\scripts') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $lockedRoot 'isaac-ng.exe'), [Text.Encoding]::ASCII.GetBytes('fake'))
    $lockedDll = Join-Path $lockedRoot 'zhlREPENTOGON.dll'
    [IO.File]::WriteAllBytes($lockedDll, [Text.Encoding]::ASCII.GetBytes('STALE-READONLY-DLL'))
    Set-ItemProperty -LiteralPath $lockedDll -Name IsReadOnly -Value $true
    # Verify Stop-GameProcesses with mocked cmdlets (no real game process).
    . $scriptPath -Action Status -Quiet | Out-Null
    $script:stoppedPids = @()
    function Get-Process { param([string]$Name) if ($Name -in @('isaac-ng', 'REPENTOGONLauncher')) { return [pscustomobject]@{ Id = 4242; ProcessName = $Name } } }
    function Stop-Process { param([int]$Id, [switch]$Force, [object]$ErrorAction) $script:stoppedPids += $Id }
    Stop-GameProcesses
    Remove-Item function:Get-Process -ErrorAction SilentlyContinue
    Remove-Item function:Stop-Process -ErrorAction SilentlyContinue
    if (($script:stoppedPids | Select-Object -Unique).Count -ne 1 -or $script:stoppedPids.Count -ne 2) {
        throw 'Stop-GameProcesses hat nicht beide Prozessnamen gestoppt.'
    }
    try {
        $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT = $lockedRoot
        $env:ISAAC_MODSYNC_TEST_REPENTOGON_ZIP = $fixtureZip
        $env:ISAAC_MODSYNC_NO_LAUNCH = '1'
        & $scriptPath -Action Apply -ToolsRoot $tools -PatchedDll $patched -Quiet | Out-Null
        if ((Get-Hash $lockedDll) -ne $patchedHash) { throw 'Apply nach ReadOnly-Konflikt hat die gepatchte DLL nicht installiert.' }
        $attrs = [IO.File]::GetAttributes($lockedDll)
        if (($attrs -band [IO.FileAttributes]::ReadOnly) -ne 0) { throw 'ReadOnly-Attribut der Ziel-DLL wurde nicht entfernt.' }
        $backupHash = (Get-Hash "$lockedDll.orig")
        $expectedOfficial = (Get-FileHash -InputStream ([IO.MemoryStream]::new($officialDllBytes)) -Algorithm SHA256).Hash
        if ($backupHash -ne $expectedOfficial) { throw 'Original-DLL aus dem Zip wurde nicht korrekt gesichert.' }
        Write-Output 'PASS: ReadOnly-Ziel wird sicher überschrieben; Game-Prozesse werden gestoppt'
    } finally { }

    Write-Output 'ALL permanent-patch cycle tests passed.'
} finally {
    $env:LOCALAPPDATA = $oldLocal
    $env:APPDATA = $oldAppData
    $env:ISAAC_MODSYNC_TEST_ISAAC_ROOT = $oldTestRoot
    $env:ISAAC_MODSYNC_TEST_REPENTOGON_ZIP = $oldTestZip
    $env:ISAAC_MODSYNC_NO_LAUNCH = $oldNoLaunch
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
