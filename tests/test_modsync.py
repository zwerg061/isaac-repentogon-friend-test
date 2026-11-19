import json
import tempfile
import unittest
from pathlib import Path

from tools.modsync import (
    ManifestError,
    build_install_plan_html,
    build_manifest,
    build_profile,
    build_settings_bundle,
    capture_mcm_export,
    compare_manifests,
    compare_profile,
    compare_settings,
    load_manifest,
    load_mcm_export,
    load_profile,
    load_settings_bundle,
    prepare_settings_imports,
)


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

    def test_only_latest_log_mod_list_is_used(self):
        self.log.write_text(
            "[INFO] - Binding of Isaac: Repentance+ v1.9.7.11\n"
            "[INFO] - begin list mods\n"
            f"[INFO] - LOADED MOD {self.mods / 'alpha_101' / 'content'}\\\n"
            "[INFO] - Binding of Isaac: Repentance+ v1.9.7.12.J273\n"
            "[INFO] - begin list mods\n"
            f"[INFO] - LOADED MOD {self.mods / 'beta_202' / 'content'}\\\n",
            encoding="utf-8",
        )
        manifest = self.manifest()
        self.assertEqual(manifest["game_version"], "1.9.7.12.J273")
        self.assertEqual([m["workshop_id"] for m in manifest["mods"]], ["202"])

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
