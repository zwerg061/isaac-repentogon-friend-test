# Fixture-only tests; no game, Steam, or real save directory is touched.
$ErrorActionPreference = 'Stop'
$runner = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Run-TempModProfile.ps1'
$source = [IO.File]::ReadAllText($runner)
$match = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $match.Success) { throw 'Watcher source not found in runner.' }
Add-Type -TypeDefinition $match.Groups[1].Value
$dir = Join-Path ([IO.Path]::GetTempPath()) ('modsync-watcher-fixture-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($dir) | Out-Null
$file = Join-Path $dir 'log.txt'
$enter = '[INFO] - Lua Debug: [modsync-lobby] lobby-menu-enter=17'
$leave = '[INFO] - Lua Debug: [modsync-lobby] lobby-menu-exit=3'
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    [IO.File]::WriteAllText($file, "$enter`n$leave`n", $utf8)
    $watcher = [ModSyncLobbyLogWatcher]::new($file)
    if (@($watcher.ReadEvents()).Count -ne 0) { throw 'Read an earlier session.' }
    [IO.File]::AppendAllText($file, "$enter`n$leave", $utf8)
    $events = @($watcher.ReadEvents())
    if ($events.Count -ne 1 -or $events[0] -ne 'menu-enter') { throw 'Partial line was processed too early.' }
    [IO.File]::AppendAllText($file, "`n", $utf8)
    $events = @($watcher.ReadEvents())
    if ($events.Count -ne 1 -or $events[0] -ne 'menu-exit') { throw 'Menu exit was not detected.' }
    [IO.File]::AppendAllText($file, "$leave`n", $utf8)
    if (@($watcher.ReadEvents()).Count -ne 0) { throw 'Duplicate exit was reported.' }
    [IO.File]::AppendAllText($file, "$enter`n$leave`n", $utf8)
    $events = @($watcher.ReadEvents())
    if ($events.Count -ne 2 -or $events[0] -ne 'menu-enter' -or $events[1] -ne 'menu-exit') {
        throw 'Second lobby menu cycle was not observed.'
    }
    [IO.File]::WriteAllText($file, "$leave`n", $utf8)
    if (@($watcher.ReadEvents()).Count -ne 0) { throw 'Exit after log truncation used stale menu state.' }
    [IO.File]::WriteAllText($file, "$enter`n$leave`n", $utf8)
    $events = @($watcher.ReadEvents())
    if ($events.Count -ne 2 -or $events[0] -ne 'menu-enter' -or $events[1] -ne 'menu-exit') {
        throw 'Rewritten log was not detected and processed as a new session.'
    }
    Write-Output 'Fixture-only lobby log watcher tests passed.'
} finally {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    if (Test-Path -LiteralPath $dir) { [IO.Directory]::Delete($dir) }
}
