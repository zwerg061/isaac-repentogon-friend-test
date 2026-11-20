# Changelog

## 0.0.11 - rename-before-write for antivirus / file-lock safety

- Existing target files are now renamed to `<name>.old.<timestamp>` before any
  `ExtractToFile` or `Copy-Item`. Writing to the fresh target path avoids the
  remaining `UnauthorizedAccessException` even when a scanner holds the old
  file open. The `.old` file is removed after a successful write, restored on
  failure, and stale `.old` files are cleaned up at the next run.
- `test_setup_click_order.ps1` now guarantees cleanup of every started setup
  window/process, every `setup-ui-*` fixture folder and all injected
  `ISAAC_MODSYNC_TEST_*` environment variables, including on failure.

## 0.0.10 - safe overwrite of locked / ReadOnly REPENTOGON files

- `Install-ModSyncPatch.ps1` now stops running `isaac-ng.exe` and
  `REPENTOGONLauncher.exe` processes before any extraction or copy.
- `Clear-ReadOnly` removes the ReadOnly attribute from existing target files;
  `Invoke-WithRetry` retries `ExtractToFile` and `Copy-Item` up to five times
  with a 250 ms pause so Defender/Sophos can release a freshly written DLL.
- All DLL copies are SHA-256 verified after the retry.
- New fixture test covers a ReadOnly existing `zhlREPENTOGON.dll` plus mocked
  game processes, including the exact original hash in the backup.

## 0.0.9 - robust one-click activation with real error reporting

- "Patch aktivieren" now installs the embedded tools automatically when they
  are missing, so the button works without a prior "Installieren" click.
  Both click orders are covered by a Win32 UI automation fixture test
  (`tests/test_setup_click_order.ps1`), no screenshots involved.
- PowerShell stdout/stderr and script errors are written to
  `%LOCALAPPDATA%\IsaacModSync\install.log`; the exact error cause is shown in
  the status field and message box instead of the generic failure message.
- If Steam auto-detection fails, a Windows file picker for `isaac-ng.exe` is
  opened and the selected directory is passed as `-IsaacRoot`.
- The setup keeps the full permanent patch and one-click uninstall behaviour
  of v0.0.8. All 10 embedded resources and `asInvoker` are verified.

## 0.0.8 - permanent one-click patch and complete one-click removal

- `Install-ModSyncPatch.ps1` provides `Apply`, `Uninstall` and `Status`. Apply
  installs official REPENTOGON automatically if missing, backs up the original
  `zhlREPENTOGON.dll` once as `zhlREPENTOGON.dll.orig` (SHA-256 verified),
  installs the patched DLL, starts a hidden companion and launches Isaac without
  a visible launcher window (`--stealth-mode`, game window shown afterwards).
- Uninstall stops companion processes, restores the exact original DLL (or
  removes a REPENTOGON installation created by us), removes `zz_modsync*`
  helper mods, the HKCU Apps & Features entry and the Start menu shortcut.
  Also available via `Isaac-Freund-Test-Setup.exe --uninstall`.
- The setup embeds the installer script as RCDATA 110; all 10 embedded resources
  and `asInvoker` are verified after the build.
- The mod launcher offers a prominent "Online-Patch aktiv / abschalten" switch
  that uses the same script, and detects `SteamModProfileBridge.exe` in all
  build locations so the online-sync tile turns green.
- Fixture test `tests/test_permanent_patch.ps1` verifies the full cycle
  (Apply -> patched hash -> Uninstall -> exact original hash), idempotency,
  status, tamper protection and complete removal of an auto-installed REPENTOGON.

## 0.0.7 - patched REPENTOGON DLL applied transactionally on the real install

- The setup now embeds the verified, patched `zhlREPENTOGON.dll` built from
  `sandbox/live-reload-prototype/source` (online lobby unlock, in-lobby mod hot
  reload, crash/desync fixes). SHA256: `79B85546FBEEAD4DE573C50577E699EAF97739992EF13D03F72D0882CA1F7D45`.
- `Run-TempModProfile.ps1` accepts `-PatchedRepentogonDll <path>`. When supplied,
  it requires REPENTOGON to be installed (DLL + core files + resources), stores
  the original DLL, swaps in the patched DLL via two new journalled steps, and
  restores the original on normal exit, `-RestoreOnly`, error rollback and
  automatic crash recovery. Every step is SHA-256 verified before any file is
  removed; a foreign/tampered DLL aborts the rollback instead of being deleted.
- Atomic journal writes retry transient `ACCESS_DENIED`/`SHARING_VIOLATION`
  (e.g. Defender scanning a freshly written DLL) instead of failing the launch.
- The runner now accepts a real Steam layout (`<IsaacRoot>\isaac-ng.exe`) in
  addition to the sandbox layout (`<IsaacRoot>\Repentogon\isaac-ng.exe`).
- New fixture-only test `tests/test_repentogon_dll_swap.ps1` covers journal
  rollback, exit restore, crash recovery and tamper protection. No real game or
  Steam files are touched.
- The `isaac-mod-launcher` passes `-PatchedRepentogonDll` automatically when a
  modpack has online mod sync enabled and refuses to start when REPENTOGON or
  the patched DLL is missing.

## 0.0.6 - closed friend test: P2P transfer and hot reload enabled

- **Enabled for the closed friend test:** automatic Steam P2P profile transfer and
  the in-lobby mod hot reload are now active. They are gated by a strict
  two-sided version check: the runner verifies the companion's file version and
  the profile's `tool_version`, and the companion verifies `--expected-version`.
  Any mismatch aborts before a profile is sent, a download starts, or the
  installation is touched. `-SandboxOptIn` is now a no-op legacy switch.
- The runner reads the private lobby ID from the live game log, passes it to the
  companion and shows an active progress bar while waiting for the lobby and for
  SteamAPI readiness. Missing Workshop items are downloaded with SteamCMD
  `+login anonymous` only; no Steam credentials or tokens are read or saved.
- **Transactional swap:** every step of the mods directory junction swap is
  journalled atomically (temp file + `MoveFileEx` with write-through), guarded by
  an exclusive lockfile, and rolled back immediately if a step fails. A stale
  session after a hard game crash is restored automatically at the next runner
  start once Isaac is closed. Fixture-only tests cover atomic writes, journal
  rollback, lock reclaim and crash recovery.
- Add offline lobby-log candidate parsing and a log-based menu-exit notice.
  A candidate ID is not authentication, and a menu exit is not proof that the
  Steam lobby ended. Two-player and end-to-end notice tests remain outstanding.
- Add `SteamModProfileBridge.exe` using the game's installed `steam_api.dll`.
  HostLoop/ClientLoop re-verify lobby ownership, membership and friend status on
  every callback before sending a profile. No Steam token files are read or saved.
- Add a custom-shader fixture (`.fs`/`.vs`) and a log-based shader/RoomConfig
  stability check for the `new -> remove -> new` sandbox reload cycle.
- **Anti-desync prevention gate:** `modsync.py anti-desync-check` and the runner
  now enforce the exact mod load order (including an order digest), matching
  game/REPENTOGON build SHA-256 hashes and version equality before any swap or
  game start. Mod SaveData is isolated in a fresh session `data/` tree and
  junctioned for the session, so local persistent mod data cannot desync co-op.
  All four swap steps (mods + data) are journalled and crash-recovered.
- **Isaac Desync Assistant:** the temporary helper mod monitors start seed,
  stage/room index, item-pool checksum and loaded-mod state and writes diagnostic
  markers. The companion analyses the local log and opens a German Windows
  dialog on a desync, P2P timeout or unexpected lobby abort, naming the reason,
  the affected mod/file and offering the one-click fix "Profil & SaveData neu
  synchronisieren" (`Resync-ProfileAndSaveData.ps1`).
- **Still unverified with a real second player:** the two-player transfer, the
  live lobby trigger, and the hot reload after joining. Equal hashes are not
  proof against desync; load order and MCM settings are not synchronized.
- The runner restores original mods after Isaac closes; the experimental
  menu-exit notice leaves the game open with its current mods until then.

## 0.0.5 - lobby-exit notice (experimental)

- Add one identical, temporary observer mod to both staged profiles. It watches
  REPENTOGON's `MainMenuType.ONLINELOBBY` and writes a local signal after the
  player returns to another main-menu section.
- The PowerShell runner displays a lobby-ended notice and leaves Isaac open.
  The original `mods` directory and TEMP stage remain in place until Isaac exits;
  only then are the original mods restored and the TEMP copy removed.
- Both players must use the same v0.0.5 runner so the temporary observer mod is
  present on both sides. A live two-player lobby-exit event is not yet verified.

## 0.0.4 - temporary host-mod sessions (experimental)

- Add `profile stage`: copy only exact host-profile mods to a fresh TEMP folder;
  use installed folders or the local Workshop cache first.
- Optionally call SteamCMD with anonymous login for only missing Workshop IDs
  named by a trusted host profile. No Steam credentials/tokens are read or saved;
  source and staged files must match the host SHA-256.
- Add `Run-TempModProfile.ps1`: temporarily move the game's `mods` directory
  aside and junction it to the TEMP session. Restore the original directory and
  remove the staged copy when Isaac exits; `-RestoreOnly` recovers an interrupted
  session after the game is closed.
- The original mods restore when Isaac exits. Steam/SteamCMD may retain their
  Workshop download cache.
- Keep MCM setting transfer separate and explicit; no saves or load order are
  synchronized by this feature.

## 0.0.3 - local mod profile apply/restore (experimental)

- Add a preview-first `profile apply` command that enables only exact,
  already-installed host mods and disables local extras through REPENTOGON's
  `disable.it` markers.
- Require matching game/REPENTOGON versions and exact mod hashes; missing or
  changed host mods block all changes. No mod files are downloaded or copied.
- Save previous marker contents in a rollback JSON and add `profile restore`;
  refuse to overwrite marker states changed after applying.
- Exclude `disable.it` from mod-content hashes so enabled-state toggles do not
  make otherwise identical mods appear modified.
- Mod load order, MCM settings, saves, and automatic multiplayer syncing are
  not changed by profile application.

## 0.0.2 - in-place menu fix

- Replace the shipped menu-fix DLL with three in-place byte patches in the
  installed `Repentogon\zhlREPENTOGON.dll` (REPENTOGON 1.1.3):
  - the menu reset filter now only resets "Daily Run" instead of also resetting
    the ONLINE menu,
  - the forced online selection is skipped, so Quick/Public/Friend Match stay
    selectable,
  - the mod-ban status is stored as 0.
- `Patch.exe` accepts only the exact tested SHA-256 values, builds the patched
  DLL in memory, compares the result hash before writing, and verifies the file
  after writing. Any mismatch rolls back.
- The setup EXE no longer contains or installs a REPENTOGON DLL.
- Both EXEs embed an `asInvoker` manifest. Windows no longer treats the setup
  file name as an installer and no longer shows a UAC ("administrator")
  prompt; the tools run with normal user rights.
- Sandbox test with the patched official DLL: ONLINE stayed open during the
  observation window and Friend Match was selectable. A real two-player
  connection is still unverified.

## 0.0.1 - first experimental package

- Add a self-contained setup EXE that installs the patch GUI, mod manifest
  checker, and German friend-test guide into a chosen folder.
- Add reversible patch/unpatch controls for recognized REPENTOGON files.
- Add read-only host/client mod-manifest comparison.
- Clearly mark connection, Friend Match, private-lobby, and mod-sync status as
  unverified.
