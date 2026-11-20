# Changelog

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
