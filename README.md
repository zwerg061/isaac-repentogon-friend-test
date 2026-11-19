# Isaac REPENTOGON Friend Test

**Version:** 0.0.1 (experimental)<br>
**Status:** connection not yet verified with a second player.

A small Windows setup package for testing the experimental REPENTOGON online
co-op patch with a consenting friend. It installs a local patch manager and a
read-only mod-manifest checker. It does **not** distribute the game, REPENTOGON,
mods, Workshop files, saves, or Steam credentials.

## Important status

- The REPENTOGON menu path has not yet been reliably navigated to Friend Match;
  previous automated attempts selected Quick Match instead and stopped without
  creating a lobby.
- Removing a local mod-ban check is not proof of working networking or mod sync.
- REPENTOGON's `netstart <SteamID64>` is a possible but unverified connection
  path. It may initiate a connection/invitation, so use it only when both
  players are ready and have agreed.
- The normal Steam invitation/join handler is known to be unavailable in the
  tested REPENTOGON build. Do not rely on Steam's Join Game/Invite flow.
- This project is unofficial and experimental. Do not use the patch in public
  lobbies or with people who have not agreed to the test.

## Release contents

The single-file `Isaac-Freund-Test-Setup.exe` release asset embeds:

- `Patch.exe` — GUI with **Prüfen**, **Patch anwenden**, and **Zurücksetzen**.
- `modsync.py` — read-only comparison of loaded mod versions, hashes, and order.
- `setup-freundestest-de.txt` — German preparation and test instructions.

The installer asks for a destination folder and refuses to overwrite existing
files. The patch manager only modifies a locally detected/selected REPENTOGON
installation when its expected byte patterns match. It keeps its backups next to
`Patch.exe` in a `backup` subfolder. Keep the patch manager in place so the same
backup is available for **Zurücksetzen**.

## Requirements for both players

- Their own legitimate Steam copy of Repentance+.
- Matching tested build: `v1.9.7.12.J273`.
- Matching REPENTOGON build: `1.1.3`.
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

## Version 0.0.1

First experimental friend-test package. A real two-player connection, private
lobby creation, and REPENTOGON mod synchronization remain unverified.
