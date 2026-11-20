# Isaac REPENTOGON Friend Test

**Version:** 0.0.7 (experimental)<br>
**Status:** menu fix and patched REPENTOGON DLL verified in a sandbox; connection
not yet verified with a second player.

> **v0.0.7 adds the transactional DLL swap.** The setup embeds the verified
> patched `zhlREPENTOGON.dll`. With `-PatchedRepentogonDll`, the runner backs up
> the original DLL, applies the patch journally and restores the original on
> exit, `-RestoreOnly`, rollback and crash recovery. REPENTOGON must already be
> installed; without the switch nothing in the game directory is changed.

> **Closed friend test v0.0.6 — automatic transfer enabled.** A two-sided version
> check gates `-HostMode` and `-WaitForHostProfile`: both players must use v0.0.6
> (runner, companion file version and profile `tool_version`), otherwise the
> runner aborts before contacting Steam, sending a profile, downloading mods or
> changing the game. The complete two-player transfer and the in-lobby mod reload
> have still **not** been verified with a real second player; use only with a
> trusted friend and an isolated save.

A small Windows setup package for testing the experimental REPENTOGON online
co-op patch with a consenting friend. It installs a local patch manager and
tools to inspect and optionally apply a local mod profile. It does **not**
distribute the game, REPENTOGON, mods, Workshop files, saves, or Steam credentials.

## Important status

- With the patch applied, the isolated sandbox test reached the ONLINE menu and
  it stayed open: Quick Match, Public Match, and Friend Match were visible and
  selectable. A cursor check (one Arrow-Down, no confirmation) is used to verify
  that the selection is not locked.
- No real connection to a second player has been established yet. A reachable
  menu or temporary mod-profile staging is not proof of working networking or
  automatic multiplayer mod synchronization.
- REPENTOGON's `netstart <SteamID64>` is a possible but unverified connection
  path. It may initiate a connection/invitation, so use it only when both
  players are ready and have agreed.
- The normal Steam invitation/join handler is known to be unavailable in the
  tested REPENTOGON build. Do not rely on Steam's Join Game/Invite flow.
- This project is unofficial and experimental. Do not use the patch in public
  lobbies or with people who have not agreed to the test.

## What the patch changes

`Patch.exe` does not swap any file. It patches the installed files in place and
can undo everything:

- `Repentogon\isaac-ng.exe` — engine co-op/mod-ban patch.
- `Repentogon\zhlREPENTOGON.dll` (REPENTOGON 1.1.3), three byte patches:
  1. the menu reset filter only resets "Daily Run", not the ONLINE menu,
  2. the forced online selection (`ASMPatchOnlineSelection`) is skipped,
  3. the mod-ban status is stored as 0.

Only the exact tested SHA-256 values are accepted. The patched DLL is built in
memory, its result hash is compared with the known-good value **before** the
first write, and the written file is verified again afterwards. On any mismatch
the tool restores the original bytes. Backups are kept in a `backup` folder next
to `Patch.exe`.

## Release contents

The single-file `Isaac-Freund-Test-Setup.exe` release asset embeds:

- `Patch.exe` — GUI with **Prüfen**, **Patch anwenden**, and **Zurücksetzen**.
- `modsync.py` — manifest/profile tools. The session command copies only
  hash-verified host mods into a fresh `%TEMP%` staging folder, plus the same
  temporary lobby-exit observer on both players; it can call SteamCMD anonymously
  for Workshop IDs from the trusted host profile.
- `Run-TempModProfile.ps1` — temporarily redirects Isaac's fixed `mods` path to
  that staging folder and restores the original folder when Isaac exits. An
  experimental log-based notice reports leaving the lobby *menu*, not verified
  Steam-lobby closure. Isaac is not closed automatically.
- `SteamModProfileBridge.exe` — version-checked host/client companion for
  a future Steam P2P profile transfer.
  `steam_appid.txt` contains only Isaac's public AppID; Steam's API DLL is loaded
  from the player's own game installation, not included in the setup.
- `setup-freundestest-de.txt` — German preparation and test instructions.

The installer asks for a destination folder and refuses to overwrite existing
files. Keep the patch manager in place so the same backup is available for
**Zurücksetzen**. Neither EXE requests administrator rights, so Windows shows no
UAC prompt; the game folder must be writable by the current user.

## Requirements for both players

- Their own legitimate Steam copy of Repentance+.
- Matching tested build: `v1.9.7.12.J273`.
- Matching REPENTOGON build: `1.1.3`, installed unmodified before patching.
- Identical enabled mods, mod versions, and load order.
- Explicit consent to the experimental patch and test.

Both players would need the same setup and must be Steam friends; the automatic
transfer is currently disabled until lobby membership can be verified. Use
separate/isolated test saves.
Do not exchange save files or Steam login details. SteamCMD is optional if a mod
is missing from the local Isaac folder and Workshop cache; it uses anonymous login
only. Steam may keep downloaded Workshop originals in its cache after the active
TEMP copy is removed.

## Build from source (Windows)

Requires Visual Studio 2022 Build Tools with the x86 C++ toolchain and Windows
SDK, plus Python 3 for the test suite.

```powershell
powershell -ExecutionPolicy Bypass -File tools\build-friend-test-setup.ps1 `
  -OutDir artifacts
```

The build produces `artifacts\Isaac-Freund-Test-Setup.exe`. The installer is
unsigned; Windows SmartScreen may show a warning. Verify its SHA-256 from the
release page before sharing.

Run the unit tests:

```powershell
python -m unittest discover -s tests -v
```

## Local mod manifest (optional diagnostics)

Each player can create a local manifest from their own game log. These files
stay on that player's PC. The automatic Steam P2P transfer now requires a
matching v0.0.6 version on both sides:

```powershell
py .\modsync.py create --mods-dir "<Isaac>\mods" `
  --log "$env:USERPROFILE\Documents\My Games\Binding of Isaac Repentance+\log.txt" `
  --repentogon-dir "<Isaac>\Repentogon" --output host-mods.json

py .\modsync.py compare --host .\host-mods.json --local .\client-mods.json
```

The comparison is informational; matching files do not guarantee desync-free
multiplayer. Both role-specific runner modes can also generate a temporary local
manifest automatically if `-LocalManifest` is omitted.

### Automatic Friend-lobby profile exchange (v0.0.6 friend test)

The workflow needs no manual JSON exchange. Both commands are active after the
two-sided v0.0.6 version check. The runner reads the lobby ID from the live game
log, shows a progress bar while waiting, and the companion re-verifies lobby
ownership/membership on every callback:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-TempModProfile.ps1 `
  -HostMode -IsaacRoot "<Isaac-installation>"
```

The client command waits for the host profile after the private lobby is joined:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-TempModProfile.ps1 `
  -WaitForHostProfile -IsaacRoot "<Isaac-installation>" `
  -SteamCmd "<SteamCMD-folder>\steamcmd.exe"
```

The experimental routing checks lobby membership and host ownership on every
callback and triggers a safe in-lobby mod reload; end-to-end verification with
two players is still outstanding. Missing Workshop items are fetched with
SteamCMD `+login anonymous`; no Steam token files are read or saved.

In the manual profile mode the runner moves the original `mods` folder aside,
puts a verified junction to the TEMP session in its place, then starts REPENTOGON.
The temporary observer logs transitions out of the `ONLINELOBBY` menu and the
runner may show a notice; this does not prove that the Steam lobby has ended.
Detection has not been tested end-to-end on two players. The live game still
has the host mods loaded until it closes; then the original Mods folder is
restored and the staged copy removed. Lobby detection is experimental and has
not yet been verified in a real two-player session. If the runner is interrupted
while Isaac is open, close the game and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-TempModProfile.ps1 `
  -IsaacRoot "<Isaac-installation>" -RestoreOnly
```

The swap is journalled atomically and protected by an exclusive lockfile: a
failed step rolls back immediately, and a stale session after a hard game crash
is restored automatically on the next runner start (once Isaac is closed).
Fixture-only tests cover this in `tests/test_swap_journal.ps1`.

Do not launch a second Isaac instance or start a Steam game update during the
session. The runner changes no original mod contents or saves, but the game
installation's `mods` directory path is temporarily a junction. It does not
synchronize load order or MCM settings; selected MCM values remain a separate
manual sandbox flow.

## Anti-desync protection and Isaac Desync Assistant

Before the game starts, the runner enforces the exact mod load order, matching
game/REPENTOGON build SHA-256 hashes and version equality on both sides. Mod
SaveData is staged into a fresh isolated `data/` tree and junctioned for the
session; a critical mismatch blocks the start with a clear message.

The temporary helper mod monitors start seed, stage/room index, item-pool
checksums and loaded mod state, writing diagnostic markers to the game log. The
companion analyses that log and opens the **Isaac Desync Assistant** on a desync,
P2P timeout or unexpected lobby abort. The German dialog names the cause and the
affected mod/file and offers a one-click **"Profil & SaveData neu
synchronisieren"** action that rebuilds the temp profile from the same trusted
host profile.

## Version 0.0.6

Enables automatic Steam P2P profile transfer and the in-lobby mod hot reload for
a closed friend test, gated by a strict two-sided v0.0.6 version check. Adds an
atomic journal/lockfile with immediate rollback and automatic crash recovery, a
custom-shader fixture with a log-based shader/RoomConfig stability check, and
build-time hash and `asInvoker` verification. A real two-player connection,
SteamAPI companion behavior alongside Isaac, the live Friend-lobby trigger,
settings transfer and mod load-order application remain unverified.
