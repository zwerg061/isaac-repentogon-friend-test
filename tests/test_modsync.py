import argparse
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.modsync import (
    LobbyLogTracker,
    ManifestError,
    anti_desync_checks,
    build_install_plan_html,
    build_manifest,
    build_profile,
    build_settings_bundle,
    apply_profile_markers,
    capture_mcm_export,
    command_profile_restore,
    compare_manifests,
    compare_profile,
    compare_settings,
    digest_mod,
    load_manifest,
    load_mcm_export,
    load_profile,
    load_settings_bundle,
    profile_apply_plan,
    run_anonymous_workshop_download,
    stage_profile_session,
    prepare_settings_imports,
)


class LobbyLogTrackerTests(unittest.TestCase):
    def test_sandbox_join_is_only_a_candidate_and_create_menu_is_not_lobby(self):
        tracker = LobbyLogTracker()
        events = tracker.feed(
            b"[INFO] - Creating friend lobby...\n"
            b"[INFO] - Successfully created lobby 109775245124237587\n"
            b"[INFO] - Successfully joined lobby 109775245124237587\n"
            b"[INFO] - Lua Debug: [modsync-lobby] lobby-menu-enter=17\n"
        )
        self.assertEqual(events, [("lobby_candidate", 109775245124237587),
                                  ("lobby_menu_enter", 109775245124237587)])
        self.assertTrue(tracker.menu_active)

    def test_partial_lines_and_menu_exit_are_not_membership_proof(self):
        tracker = LobbyLogTracker()
        self.assertEqual(tracker.feed(b"[INFO] - Successfully joined lobby 109775245"), [])
        self.assertEqual(tracker.feed(b"124237587\r\n[INFO] - Lua Debug: [modsync-lobby] lobby-menu-enter=17\n"),
                         [("lobby_candidate", 109775245124237587), ("lobby_menu_enter", 109775245124237587)])
        self.assertEqual(tracker.feed(b"[INFO] - Lua Debug: [modsync-lobby] lobby-menu-exit=3\n"),
                         [("lobby_menu_exit", 109775245124237587)])
        self.assertIsNone(tracker.candidate_lobby)
        self.assertEqual(tracker.feed(b"[INFO] - Lua Debug: [modsync-lobby] lobby-menu-exit=3\n"), [])

    def test_ignores_fake_prefix_invalid_ids_and_creation_only(self):
        tracker = LobbyLogTracker()
        events = tracker.feed(
            b"[INFO] - Successfully created lobby 109775245124237587\n"
            b"[INFO] - Lua Debug: Successfully joined lobby 109775245124237587\n"
            b"[INFO] - Successfully joined lobby 18446744073709551616\n"
            b"[INFO] - Successfully joined lobby 123\n"
            b"[INFO] - Lua Debug: [modsync-lobby] lobby-menu-enter=21\n"
        )
        self.assertEqual(events, [])
        self.assertIsNone(tracker.candidate_lobby)

    def test_reset_discards_old_candidate_and_partial_line(self):
        tracker = LobbyLogTracker()
        tracker.feed(b"[INFO] - Successfully joined lobby 109775245124237587\n[INFO] - Successfully")
        tracker.reset()
        self.assertEqual(tracker.feed(b" joined lobby 109775245124237587\n"), [])
        self.assertEqual(tracker.feed(b"[INFO] - Lua Debug: [modsync-lobby] lobby-menu-enter=17\n"),
                         [("lobby_menu_enter", None)])

    def test_oversized_line_invalidates_all_state(self):
        tracker = LobbyLogTracker()
        tracker.feed(b"[INFO] - Successfully joined lobby 109775245124237587\n")
        with self.assertRaises(ManifestError):
            tracker.feed(b"x" * (tracker.MAX_PARTIAL + 1))
        self.assertIsNone(tracker.candidate_lobby)
        self.assertFalse(tracker.menu_active)


class ModManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.mods = self.root / "mods"
        self.mods.mkdir()
        self.repentogon = self.root / "Repentogon"
        rgon_scripts = self.repentogon / "resources" / "scripts"
        rgon_scripts.mkdir(parents=True)
        (rgon_scripts / "main_ex.lua").write_text(
            'REPENTOGON = {\n\t["Version"] = "1.1.3",\n}\n', encoding="utf-8"
        )
        self.log = self.root / "log.txt"
        self.add_mod("alpha_101", "Alpha", "101", "1.0", b"alpha-data")
        self.add_mod("beta_202", "Beta", "202", "2.5", b"beta-data")
        self.log.write_text(
            "[INFO] - Binding of Isaac: Repentance+ v1.9.7.12.J273\n"
            f"[INFO] - LOADED MOD {self.mods / 'beta_202' / 'content'}\\\n"
            f"[INFO] - LOADED MOD {self.mods / 'alpha_101' / 'content'}\\\n",
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def add_mod(self, folder, name, workshop_id, version, payload):
        mod_dir = self.mods / folder
        mod_dir.mkdir()
        (mod_dir / "content").mkdir()
        (mod_dir / "content" / "main.lua").write_bytes(payload)
        (mod_dir / "metadata.xml").write_text(
            f"<metadata><name>{name}</name><id>{workshop_id}</id><version>{version}</version></metadata>",
            encoding="utf-8",
        )

    def manifest(self):
        return build_manifest(self.mods, self.log)

    def test_build_uses_log_order_and_metadata(self):
        manifest = self.manifest()
        self.assertEqual(manifest["game_version"], "1.9.7.12.J273")
        self.assertEqual(manifest["repentogon_version"], "1.1.3")
        self.assertEqual(
            manifest["repentogon_version_source"],
            "Repentogon/resources/scripts/main_ex.lua",
        )
        self.assertEqual([m["workshop_id"] for m in manifest["mods"]], ["202", "101"])
        self.assertEqual([m["order"] for m in manifest["mods"]], [0, 1])
        self.assertTrue(all(len(m["sha256"]) == 64 for m in manifest["mods"]))

    def test_manual_version_cannot_override_installed_build_mismatch(self):
        with self.assertRaisesRegex(ManifestError, "widerspricht"):
            build_manifest(self.mods, self.log, "1.1.2")

    def test_dev_build_is_not_reported_as_comparable_release(self):
        version_file = self.repentogon / "resources" / "scripts" / "main_ex.lua"
        version_file.write_text(
            'REPENTOGON = {\n\t["Version"] = "dev build",\n}\n', encoding="utf-8"
        )
        manifest = self.manifest()
        self.assertIsNone(manifest["repentogon_version"])
        self.assertIn("development build", manifest["repentogon_version_source"])

    def test_missing_repentogon_build_version_stays_unconfirmed(self):
        version_file = self.repentogon / "resources" / "scripts" / "main_ex.lua"
        version_file.unlink()
        unknown = self.manifest()
        known = json.loads(json.dumps(unknown))
        known["repentogon_version"] = "1.1.3"
        differences = compare_manifests(known, unknown)
        self.assertIsNone(unknown["repentogon_version"])
        self.assertTrue(any("Kompatibilitaet nicht bestaetigt" in s for s in differences))

    def test_profile_keeps_mod_set_and_load_order_separate_without_save_fields(self):
        profile = build_profile(self.manifest(), "  Fiend Folio Co-op  ")
        self.assertEqual(profile["profile_name"], "Fiend Folio Co-op")
        self.assertEqual(profile["format"], "isaac-mod-profile")
        self.assertEqual(
            [mod["workshop_id"] for mod in profile["mod_set"]], ["101", "202"]
        )
        self.assertEqual(profile["load_order"], ["workshop:202", "workshop:101"])
        self.assertTrue(all("order" not in mod for mod in profile["mod_set"]))
        self.assertFalse(any(key in profile for key in ("saves", "save_data", "settings")))
        self.assertFalse(any("save" in key.casefold() for key in profile))

    def test_profile_roundtrip_and_check_against_manifest(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        path = self.root / "friend-coop-profile.json"
        path.write_text(json.dumps(profile), encoding="utf-8")
        loaded = load_profile(path)
        self.assertEqual(compare_profile(loaded, self.manifest()), [])

    def test_anti_desync_blocks_build_hash_and_load_order_mismatch(self):
        manifest = self.manifest()
        manifest["game_build_sha256"] = "a" * 64
        manifest["repentogon_build_sha256"] = "b" * 64
        profile = build_profile(manifest, "Friend co-op")
        report = anti_desync_checks(profile, manifest)
        self.assertEqual(report["status"], "ok")
        self.assertTrue(all(check["status"] == "ok" for check in report["checks"]))

        bad_build = dict(manifest)
        bad_build["game_build_sha256"] = "c" * 64
        with self.assertRaisesRegex(ManifestError, "Game-Build-Hash"):
            anti_desync_checks(profile, bad_build)

        bad_order = dict(manifest)
        bad_order["mods"] = list(reversed(manifest["mods"]))
        with self.assertRaisesRegex(ManifestError, "Ladereihenfolge"):
            anti_desync_checks(profile, bad_order)

    def test_stage_creates_isolated_savedata_and_desync_monitor(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        local = self.manifest()
        session_root = self.root / "Temp" / "isaac-desync-session"
        stage_dir, staged = stage_profile_session(profile, local, self.mods, None, None, session_root)
        self.assertTrue((session_root / "data").is_dir())
        for mod in self.manifest()["mods"]:
            self.assertTrue((session_root / "data" / mod["folder"]).is_dir())
        savedata = json.loads((session_root / "savedata-manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(len(savedata["mods"]), len(self.manifest()["mods"]))
        report = json.loads((session_root / "anti-desync.json").read_text(encoding="utf-8"))
        self.assertEqual(report["status"], "ok")
        lua = (stage_dir / "zz_modsync_lobby_exit_observer" / "main.lua").read_text(encoding="utf-8")
        self.assertNotIn("@@EXPECTED_", lua)
        self.assertNotIn("@@DESYNC_VERSION@@", lua)
        self.assertIn("[modsync-desync]", lua)
        self.assertIn("MC_POST_MODS_LOADED", lua)
        self.assertEqual(len(staged), len(self.manifest()["mods"]) + 1)

    def test_profile_rejects_mismatched_tool_version(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        profile["tool_version"] = "0.0.5"
        path = self.root / "old-profile.json"
        path.write_text(json.dumps(profile), encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "Versionskonflikt"):
            load_profile(path)

    def test_profile_check_detects_order_and_set_changes(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        local = self.manifest()
        local["mods"].reverse()
        differences = compare_profile(profile, local)
        self.assertTrue(any("Ladereihenfolge" in s for s in differences))
        local["mods"].pop()
        differences = compare_profile(profile, local)
        self.assertTrue(any("Fehlt beim Client" in s for s in differences))

    def test_profile_validation_rejects_incomplete_order(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        profile["load_order"].pop()
        path = self.root / "invalid-profile.json"
        path.write_text(json.dumps(profile), encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "jeden Mod"):
            load_profile(path)

    def test_profile_apply_preview_and_rollback_only_toggle_disable_markers(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        # Alpha starts disabled; an extra client mod starts enabled.
        (self.mods / "alpha_101" / "disable.it").write_bytes(b"original marker")
        self.add_mod("extra_303", "Extra", "303", "1.0", b"extra-data")

        mods_root, plan, differences = profile_apply_plan(profile, self.manifest(), self.mods)
        self.assertEqual(differences, [])
        actions = {entry["folder"]: entry["action"] for entry in plan}
        self.assertEqual(actions["alpha_101"], "aktivieren")
        self.assertEqual(actions["beta_202"], "unveraendert")
        self.assertEqual(actions["extra_303"], "deaktivieren")

        rollback = self.root / "profile-rollback.json"
        self.assertEqual(apply_profile_markers(plan, rollback, mods_root), 0)
        self.assertFalse((self.mods / "alpha_101" / "disable.it").exists())
        self.assertTrue((self.mods / "extra_303" / "disable.it").is_file())
        self.assertEqual((self.mods / "extra_303" / "disable.it").stat().st_size, 0)

        self.assertEqual(
            command_profile_restore(argparse.Namespace(rollback=str(rollback), mods_dir=str(self.mods))),
            0,
        )
        self.assertEqual((self.mods / "alpha_101" / "disable.it").read_bytes(), b"original marker")
        self.assertFalse((self.mods / "extra_303" / "disable.it").exists())

    def test_profile_apply_blocks_all_changes_when_host_mod_hash_differs(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        (self.mods / "alpha_101" / "content" / "main.lua").write_bytes(b"changed locally")
        (self.mods / "beta_202" / "disable.it").write_bytes(b"keep this state")
        mods_root, plan, differences = profile_apply_plan(profile, self.manifest(), self.mods)
        self.assertTrue(any("SHA-256 stimmt nicht" in item for item in differences))
        # Planning is read-only; callers must reject a non-empty differences list.
        self.assertEqual((self.mods / "beta_202" / "disable.it").read_bytes(), b"keep this state")

    def test_profile_restore_refuses_to_overwrite_a_changed_marker(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        self.add_mod("extra_303", "Extra", "303", "1.0", b"extra-data")
        mods_root, plan, differences = profile_apply_plan(profile, self.manifest(), self.mods)
        self.assertEqual(differences, [])
        rollback = self.root / "profile-rollback.json"
        apply_profile_markers(plan, rollback, mods_root)
        (self.mods / "extra_303" / "disable.it").write_bytes(b"changed after apply")

        result = command_profile_restore(
            argparse.Namespace(rollback=str(rollback), mods_dir=str(self.mods))
        )
        self.assertEqual(result, 2)
        # Restore preflights every marker before writing any of them.
        self.assertFalse((self.mods / "alpha_101" / "disable.it").exists())
        self.assertEqual((self.mods / "extra_303" / "disable.it").read_bytes(), b"changed after apply")

    def test_profile_stage_copies_only_verified_host_mods_to_temp(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        local_manifest = self.manifest()
        (self.mods / "alpha_101" / "disable.it").write_bytes(b"old marker")
        self.add_mod("extra_303", "Extra", "303", "1.0", b"extra-data")
        cache = self.root / "workshop" / "250900"
        cache.mkdir(parents=True)
        (self.mods / "beta_202").rename(cache / "202")
        session_root = self.root / "Temp" / "IsaacModSync-test-session"

        stage_dir, staged = stage_profile_session(
            profile, local_manifest, self.mods, cache, None, session_root
        )
        self.assertEqual(len(staged), 3)
        self.assertEqual(
            {path.name for path in stage_dir.iterdir()},
            {"alpha_101", "beta_202", "zz_modsync_lobby_exit_observer"},
        )
        self.assertFalse((stage_dir / "alpha_101" / "disable.it").exists())
        self.assertEqual((self.mods / "alpha_101" / "disable.it").read_bytes(), b"old marker")
        self.assertTrue((self.mods / "extra_303" / "metadata.xml").exists())
        observer_lua = (stage_dir / "zz_modsync_lobby_exit_observer" / "main.lua").read_text(
            encoding="utf-8"
        )
        self.assertIn("ModCallbacks.MC_MAIN_MENU_RENDER", observer_lua)
        self.assertIn("MainMenuType.ONLINELOBBY", observer_lua)
        self.assertNotIn("MainMenuType.CREATELOBBY", observer_lua)
        self.assertIn("[modsync-lobby] lobby-menu-enter=", observer_lua)
        self.assertIn("[modsync-lobby] lobby-menu-exit=", observer_lua)
        self.assertNotIn("os.getenv", observer_lua)
        self.assertIn("seenOnlineLobby = false", observer_lua)
        self.assertNotIn("local signaled = false", observer_lua)
        for item in staged:
            digest, _count, _size = digest_mod(stage_dir / item["folder"])
            self.assertEqual(digest, item["sha256"])
        session_info = json.loads((session_root / "session.json").read_text(encoding="utf-8"))
        self.assertEqual(session_info["host_mod_count"], 2)
        self.assertEqual(session_info["lobby_exit_observer_count"], 1)

    def test_profile_stage_missing_host_workshop_mod_creates_no_temp_tree(self):
        profile = build_profile(self.manifest(), "Friend co-op")
        local_manifest = self.manifest()
        (self.mods / "beta_202").rename(self.root / "beta-held")
        cache = self.root / "empty-workshop-cache"
        cache.mkdir()
        session_root = self.root / "Temp" / "IsaacModSync-missing-test"
        with self.assertRaisesRegex(ManifestError, "SteamCMD"):
            stage_profile_session(profile, local_manifest, self.mods, cache, None, session_root)
        self.assertFalse(session_root.exists())

    def test_workshop_downloader_uses_anonymous_login_and_only_profile_ids(self):
        steamcmd = self.root / "steamcmd.exe"
        steamcmd.write_bytes(b"stub")
        completed = subprocess.CompletedProcess([], 0, "download ok", "")
        with patch("tools.modsync.subprocess.run", return_value=completed) as run:
            run_anonymous_workshop_download(steamcmd, ["202", "101", "202"])
        command = run.call_args.args[0]
        self.assertEqual(
            command,
            [
                str(steamcmd.resolve()),
                "+login",
                "anonymous",
                "+workshop_download_item",
                "250900",
                "101",
                "validate",
                "+workshop_download_item",
                "250900",
                "202",
                "validate",
                "+quit",
            ],
        )

    def mcm_export(self, value=10):
        return {
            "format": "isaac-mcm-settings-export",
            "schema_version": 1,
            "categories": {
                "Fiend Folio": {"HardMode": value, "SpawnRate": 0.75},
            },
        }

    def settings_bundle(self, export=None):
        return build_settings_bundle(
            self.manifest(),
            export or self.mcm_export(),
            "Fiend Folio lobby",
            ["Fiend Folio::HardMode"],
        )

    def test_capture_reads_latest_tagged_mcm_export_from_log(self):
        earlier = json.dumps(self.mcm_export(1), separators=(",", ":"))
        latest = json.dumps(self.mcm_export(2), separators=(",", ":"))
        self.log.write_text(
            f"old [MODSYNC_MCM_EXPORT_V1]{earlier}\n"
            f"new [MODSYNC_MCM_EXPORT_V1]{latest}\n",
            encoding="utf-8",
        )
        captured = capture_mcm_export(self.log)
        self.assertEqual(captured["categories"]["Fiend Folio"]["HardMode"], 2)

    def test_settings_bundle_requires_explicit_nonlocal_categories(self):
        bundle = self.settings_bundle()
        self.assertEqual(bundle["mcm_categories"], {"Fiend Folio": {"HardMode": 10}})
        self.assertTrue(any("save" in key.casefold() for key in bundle) is False)
        invalid_export = self.mcm_export()
        invalid_export["categories"]["General"] = {"HudOffset": 5}
        with self.assertRaisesRegex(ManifestError, "Lokale MCM-Kategorie"):
            build_settings_bundle(
                self.manifest(), invalid_export, "bad", ["General::HudOffset"]
            )
        with self.assertRaisesRegex(ManifestError, "explizit"):
            build_settings_bundle(self.manifest(), self.mcm_export(), "empty", [])
        with self.assertRaisesRegex(ManifestError, "CATEGORY::SETTING_KEY"):
            build_settings_bundle(self.manifest(), self.mcm_export(), "bad selector", ["Fiend Folio"])
        with self.assertRaisesRegex(ManifestError, "Setting fehlt"):
            build_settings_bundle(
                self.manifest(), self.mcm_export(), "missing key", ["Fiend Folio::Unknown"]
            )

    def test_settings_bundle_roundtrip_and_value_comparison(self):
        path = self.root / "settings-bundle.json"
        path.write_text(json.dumps(self.settings_bundle()), encoding="utf-8")
        bundle = load_settings_bundle(path)
        self.assertEqual(compare_settings(bundle, self.mcm_export()), [])
        differences = compare_settings(bundle, self.mcm_export(11))
        self.assertTrue(any("Fiend Folio" in item for item in differences))

    def test_settings_comparison_distinguishes_boolean_and_number(self):
        bundle = self.settings_bundle(self.mcm_export(True))
        self.assertTrue(compare_settings(bundle, self.mcm_export(1)))
        with self.assertRaisesRegex(ManifestError, "inkompatiblen Werttyp"):
            prepare_settings_imports(bundle, self.manifest(), self.mcm_export(1))

    def test_settings_reject_incompatible_nested_shape(self):
        bundle = self.settings_bundle(self.mcm_export({"enabled": True}))
        with self.assertRaisesRegex(ManifestError, "inkompatiblen Werttyp"):
            prepare_settings_imports(bundle, self.manifest(), self.mcm_export({"enabled": 1}))
        with self.assertRaisesRegex(ManifestError, "inkompatiblen Werttyp"):
            prepare_settings_imports(bundle, self.manifest(), self.mcm_export({"enabled": True, "extra": 1}))

    def test_settings_prepare_is_profile_gated_and_has_local_rollback(self):
        bundle = self.settings_bundle()
        local_export = self.mcm_export(3)
        imported, rollback, differences = prepare_settings_imports(
            bundle, self.manifest(), local_export
        )
        self.assertEqual(differences, [])
        self.assertEqual(imported["categories"], bundle["mcm_categories"])
        self.assertEqual(rollback["categories"]["Fiend Folio"]["HardMode"], 3)
        self.assertNotIn("SpawnRate", imported["categories"]["Fiend Folio"])
        self.assertNotIn("General", imported["categories"])
        self.assertNotIn("saves", imported)

        incompatible = self.manifest()
        incompatible["repentogon_version"] = "different"
        imported, rollback, differences = prepare_settings_imports(
            bundle, incompatible, local_export
        )
        self.assertIsNone(imported)
        self.assertIsNone(rollback)
        self.assertTrue(any("Repentogon-Version" in item for item in differences))

    def test_settings_import_requires_category_to_exist_locally(self):
        bundle = self.settings_bundle()
        local_export = self.mcm_export()
        local_export["categories"].pop("Fiend Folio")
        with self.assertRaisesRegex(ManifestError, "fehlen lokal"):
            prepare_settings_imports(bundle, self.manifest(), local_export)

    def test_settings_import_requires_setting_key_to_exist_locally(self):
        bundle = self.settings_bundle()
        local_export = self.mcm_export()
        local_export["categories"]["Fiend Folio"].pop("HardMode")
        with self.assertRaisesRegex(ManifestError, "HardMode"):
            prepare_settings_imports(bundle, self.manifest(), local_export)

    def test_equal_manifests_compare_cleanly(self):
        manifest = self.manifest()
        self.assertEqual(compare_manifests(manifest, json.loads(json.dumps(manifest))), [])

    def test_hash_mismatch_is_reported(self):
        host = self.manifest()
        client = json.loads(json.dumps(host))
        client["mods"][0]["sha256"] = "0" * 64
        self.assertTrue(any("Dateiinhalt unterschiedlich" in s for s in compare_manifests(host, client)))

    def test_order_mismatch_is_reported(self):
        host = self.manifest()
        client = json.loads(json.dumps(host))
        client["mods"].reverse()
        self.assertTrue(any("Ladereihenfolge" in s for s in compare_manifests(host, client)))

    def test_game_and_repentogon_mismatch_are_reported(self):
        host = self.manifest()
        client = json.loads(json.dumps(host))
        client["game_version"] = "different"
        client["repentogon_version"] = "different"
        differences = compare_manifests(host, client)
        self.assertTrue(any("Spielversion" in s for s in differences))
        self.assertTrue(any("Repentogon-Version" in s for s in differences))

    def test_missing_mod_fails_closed(self):
        self.log.write_text("[INFO] - LOADED MOD C:/wrong/mods/missing/content/\n", encoding="utf-8")
        with self.assertRaises(ManifestError):
            self.manifest()

    def test_allow_empty_manifest_keeps_versions_for_a_client_without_loaded_mods(self):
        self.log.write_text("Binding of Isaac: Repentance+ v1.9.7.12.J273\n", encoding="utf-8")
        manifest = build_manifest(self.mods, self.log, allow_empty=True)
        self.assertEqual(manifest["mods"], [])
        self.assertEqual(manifest["game_version"], "1.9.7.12.J273")
        self.assertEqual(manifest["repentogon_version"], "1.1.3")
        with self.assertRaisesRegex(ManifestError, "allow-empty"):
            self.manifest()

    def test_temporary_lobby_observer_is_excluded_from_host_mod_manifest(self):
        self.log.write_text(
            self.log.read_text(encoding="utf-8")
            + f"LOADED MOD {self.mods / 'zz_modsync_lobby_exit_observer' / 'content'}\\n",
            encoding="utf-8",
        )
        manifest = self.manifest()
        folders = [mod["folder"] for mod in manifest["mods"]]
        self.assertNotIn("zz_modsync_lobby_exit_observer", folders)
        self.assertEqual(len(folders), 2)

    def test_only_latest_log_mod_list_is_used(self):
        self.log.write_text(
            "[INFO] - Binding of Isaac: Repentance+ v1.9.7.11\n"
            "[INFO] - begin list mods\n"
            f"[INFO] - LOADED MOD {self.mods / 'alpha_101' / 'content'}\\\n"
            "[INFO] - -- Enabled Mods START --\nalpha_101\n[INFO] - -- Enabled Mods END --\n"
            "[INFO] - Binding of Isaac: Repentance+ v1.9.7.12.J273\n"
            "[INFO] - begin list mods\n"
            f"[INFO] - LOADED MOD {self.mods / 'beta_202' / 'content'}\\\n"
            "[INFO] - -- Enabled Mods START --\nbeta_202\n[INFO] - -- Enabled Mods END --\n",
            encoding="utf-8",
        )
        manifest = self.manifest()
        self.assertEqual(manifest["game_version"], "1.9.7.12.J273")
        self.assertEqual([m["workshop_id"] for m in manifest["mods"]], ["202"])

    def test_explicit_enabled_list_excludes_disabled_and_preserves_enabled_order(self):
        self.log.write_text(
            "[INFO] - Binding of Isaac: Repentance+ v1.9.7.12.J273\n"
            "[INFO] - begin list mods\n"
            f"[INFO] - LOADED MOD {self.mods / 'alpha_101' / 'content'}/\n"
            f"[INFO] - LOADED MOD {self.mods / 'beta_202' / 'content'}/\n"
            "[INFO] - -- Enabled Mods START -- \n"
            "BETA_202\n"
            "[INFO] - -- Enabled Mods END -- \n", encoding="utf-8"
        )
        self.assertEqual([m["folder"] for m in self.manifest()["mods"]], ["beta_202"])

    def test_explicit_enabled_list_order_takes_precedence_over_discovery_order(self):
        self.log.write_text(
            "Binding of Isaac: Repentance+ v1.9.7.12.J273\n"
            "[INFO] - begin list mods\n"
            f"LOADED MOD {self.mods / 'alpha_101' / 'content'}/\n"
            f"LOADED MOD {self.mods / 'beta_202' / 'content'}/\n"
            "[INFO] - -- Enabled Mods START --\nbeta_202\nalpha_101\n"
            "[INFO] - -- Enabled Mods END --\n", encoding="utf-8"
        )
        self.assertEqual([m["folder"] for m in self.manifest()["mods"]], ["beta_202", "alpha_101"])

    def test_incomplete_enabled_list_is_rejected(self):
        self.log.write_text(self.log.read_text(encoding="utf-8") + "[INFO] - -- Enabled Mods START --\nalpha_101\n", encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "unvollstaendig"):
            self.manifest()

    def test_latest_started_list_without_enabled_block_is_rejected(self):
        self.log.write_text(self.log.read_text(encoding="utf-8") + "[INFO] - begin list mods\n", encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "fehlt oder ist noch nicht vollstaendig"):
            self.manifest()

    def test_enabled_mod_missing_discovery_path_is_rejected(self):
        self.log.write_text(self.log.read_text(encoding="utf-8") + "[INFO] - -- Enabled Mods START --\nunknown_303\n[INFO] - -- Enabled Mods END --\n", encoding="utf-8")
        with self.assertRaisesRegex(ManifestError, "keinen passenden"):
            self.manifest()

    def test_later_log_output_cannot_supply_a_missing_discovery_path(self):
        self.log.write_text(
            "Binding of Isaac: Repentance+ v1.9.7.12.J273\n"
            "[INFO] - begin list mods\n"
            "[INFO] - -- Enabled Mods START --\nalpha_101\n[INFO] - -- Enabled Mods END --\n"
            f"[INFO] - LOADED MOD {self.mods / 'alpha_101' / 'content'}/\n", encoding="utf-8"
        )
        with self.assertRaisesRegex(ManifestError, "keinen passenden"):
            self.manifest()

    def test_empty_enabled_block_does_not_count_disabled_mods(self):
        self.log.write_text(self.log.read_text(encoding="utf-8") + "[INFO] - -- Enabled Mods START --\n[INFO] - -- Enabled Mods END --\n", encoding="utf-8")
        manifest = build_manifest(self.mods, self.log, allow_empty=True)
        self.assertEqual(manifest["mods"], [])
        with self.assertRaises(ManifestError):
            self.manifest()

    def test_manifest_validation(self):
        path = self.root / "manifest.json"
        path.write_text('{"format":"wrong"}', encoding="utf-8")
        with self.assertRaises(ManifestError):
            load_manifest(path)

    def test_manifest_reader_accepts_windows_utf8_bom(self):
        path = self.root / "manifest-bom.json"
        manifest = self.manifest()
        path.write_text(json.dumps(manifest), encoding="utf-8-sig")
        self.assertEqual(load_manifest(path)["format"], "isaac-mod-sync-manifest")

    def test_install_plan_is_review_only_and_escapes_untrusted_names(self):
        host = self.manifest()
        client = json.loads(json.dumps(host))
        client["mods"] = [client["mods"][0]]
        host["mods"][1]["name"] = '<script>alert("x")</script>'
        report = build_install_plan_html(host, client)
        self.assertIn("steamcommunity.com/sharedfiles/filedetails/?id=101", report)
        self.assertIn("Fehlt beim Client", report)
        self.assertNotIn("<script>", report)
        self.assertIn("&lt;script&gt;", report)
        self.assertIn("keine Dateien installiert", report)

    def test_public_and_quick_plans_do_not_offer_lobby_workshop_links(self):
        host = self.manifest()
        client = json.loads(json.dumps(host))
        client["mods"] = []
        for mode in ("public", "quick"):
            report = build_install_plan_html(host, client, mode)
            self.assertNotIn("href=\"https://steamcommunity.com/sharedfiles", report)
            self.assertIn("nur bereits installierte und vertraute Mods", report)
            self.assertIn("Workshop-ID", report)


if __name__ == "__main__":
    unittest.main()
