# Isaac REPENTOGON Friend Test

**Version:** 0.0.2 (experimental)<br>
**Status:** menu fix verified in a sandbox; connection not yet verified with a
second player.

A small Windows setup package for testing the experimental REPENTOGON online
co-op patch with a consenting friend. It installs a local patch manager and a
read-only mod-manifest checker. It does **not** distribute the game, REPENTOGON,
mods, Workshop files, saves, or Steam credentials.

## Important status

- With the patch applied, the isolated sandbox test reached the ONLINE menu and
  it stayed open: Quick Match, Public Match, and Friend Match were visible and
  selectable. A cursor check (one Arrow-Down, no confirmation) is used to verify
  that the selection is not locked.
- No real connection to a second player has been established yet. A reachable
  menu is not proof of working networking or mod sync.
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
- `modsync.py` — mod manifest comparison (the documented `create` and
  `compare` steps only read local files and write the manifest JSON you name).
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

Use separate/isolated test saves. Do not exchange save files or Steam login
details. The manifest contains mod metadata and hashes only; it does not install,
enable, or download mods. Python 3 is needed only for the manifest comparison.

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

## Mod manifest commands

From the folder containing `modsync.py`, each player creates a manifest using
their own installed mods and game log. The host privately shares only
`host-mods.json`; the friend compares their local manifest:

```powershell
py .\modsync.py create --mods-dir "<Isaac>\mods" `
  --log "$env:USERPROFILE\Documents\My Games\Binding of Isaac Repentance+\log.txt" `
  --repentogon-dir "<Isaac>\Repentogon" --output host-mods.json

py .\modsync.py compare --host .\host-mods.json --local .\client-mods.json
```

The comparison is informational; matching files do not guarantee desync-free
multiplayer.

## Version 0.0.2

In-place menu fix for the installed REPENTOGON 1.1.3 DLL, no DLL shipping. A real
two-player connection, private lobby creation, and REPENTOGON mod synchronization
remain unverified.
