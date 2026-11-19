#!/usr/bin/env python3
"""Create and compare read-only Isaac mod manifests and mod-only profiles.

This first Mod Sync component does not download, install, enable, or execute mods.
It records the mods actually loaded according to the game's log, their order,
metadata version, and a SHA-256 digest of their installed files.

Examples:
  python tools/modsync.py create --mods-dir "...\\mods" --log "...\\log.txt" \
      --output host-mods.json
  python tools/modsync.py compare --host host-mods.json --local client-mods.json
  python tools/modsync.py profile create --manifest host-mods.json \
      --name "Co-op set" --output coop-profile.json
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


FORMAT = "isaac-mod-sync-manifest"
SCHEMA_VERSION = 1
PROFILE_FORMAT = "isaac-mod-profile"
PROFILE_SCHEMA_VERSION = 1
MCM_EXPORT_FORMAT = "isaac-mcm-settings-export"
SETTINGS_BUNDLE_FORMAT = "isaac-mod-settings-bundle"
MCM_IMPORT_FORMAT = "isaac-mcm-settings-import"
SETTINGS_SCHEMA_VERSION = 1
MCM_EXPORT_MARKER = "[MODSYNC_MCM_EXPORT_V1]"
MCM_LOCAL_CATEGORIES = {"general", "mod config menu"}
LOADED_MOD_RE = re.compile(r"[/\\]mods[/\\](?P<folder>[^/\\]+)[/\\]+content(?:[/\\]*)", re.IGNORECASE)
GAME_VERSION_RE = re.compile(r"Binding of Isaac:\s*Repentance\+\s+v([^\s]+)", re.IGNORECASE)
RGON_VERSION_RE = re.compile(
    r"^\s*\[\s*['\"]Version['\"]\s*\]\s*=\s*['\"]([^'\"]+)['\"]",
    re.MULTILINE,
)
RELEASE_VERSION_RE = re.compile(r"^\d+(?:\.\d+){1,3}[a-z]?$", re.IGNORECASE)
IGNORED_DIRS = {".git", ".svn", "__pycache__", "cache", "logs"}
IGNORED_SUFFIXES = {".log", ".tmp", ".pyc", ".bak"}


class ManifestError(Exception):
    pass


def parse_loaded_mods(log_path: Path) -> tuple[list[str], str | None]:
    """Return the latest loaded-mod list in log order and the latest game version."""
    folders: list[str] = []
    seen: set[str] = set()
    game_version = None
    try:
        lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        raise ManifestError(f"Kann Log nicht lesen: {log_path}: {exc}") from exc

    for line in lines:
        version_match = GAME_VERSION_RE.search(line)
        if version_match:
            game_version = version_match.group(1).rstrip(".,;")

    # Isaac may append to log.txt across launches. Never combine multiple load
    # lists; use only the last explicit list if the marker is present.
    starts = [i for i, line in enumerate(lines) if "begin list mods" in line.casefold()]
    current_list = lines[starts[-1]:] if starts else lines
    for line in current_list:
        if "LOADED MOD" not in line.upper():
            continue
        match = LOADED_MOD_RE.search(line)
        if not match:
            continue
        folder = match.group("folder").strip()
        key = folder.casefold()
        if key not in seen:
            seen.add(key)
            folders.append(folder)

    if not folders:
        raise ManifestError(
            "Im Log wurden keine 'LOADED MOD .../mods/<ordner>/content/'-Zeilen gefunden. "
            "Starte das Spiel mit den gewünschten Mods und verwende dessen aktuelles log.txt."
        )
    return folders, game_version


def detect_repentogon_version(repentogon_dir: Path) -> tuple[str | None, str | None]:
    """Read the build-stamped version from Repentogon's installed main_ex.lua.

    Official Repentogon build workflows inject version.txt into this field when
    preparing a release. A development placeholder is deliberately not treated
    as a comparable release version.
    """
    version_file = repentogon_dir / "resources" / "scripts" / "main_ex.lua"
    if not version_file.is_file():
        return None, None
    try:
        text = version_file.read_text(encoding="utf-8-sig", errors="replace")
    except OSError as exc:
        raise ManifestError(f"Kann Repentogon-Buildversion nicht lesen: {version_file}: {exc}") from exc

    match = RGON_VERSION_RE.search(text)
    if not match:
        raise ManifestError(
            f"Keine build-versionierte REPENTOGON.Version in {version_file} gefunden."
        )
    version = match.group(1).strip()
    if not RELEASE_VERSION_RE.fullmatch(version):
        # In particular, do not claim that two arbitrary development builds
        # are compatible just because both say "dev build".
        if version.casefold() == "dev build":
            return None, "Repentogon/resources/scripts/main_ex.lua (development build; keine Release-Version)"
        raise ManifestError(
            f"Nicht unterstuetztes Repentogon-Versionsformat {version!r} in {version_file}."
        )
    return version, "Repentogon/resources/scripts/main_ex.lua"


def read_metadata(mod_dir: Path) -> dict[str, str | None]:
    metadata_file = mod_dir / "metadata.xml"
    result: dict[str, str | None] = {
        "name": mod_dir.name,
        "workshop_id": None,
        "version": None,
    }
    if metadata_file.is_file():
        try:
            root = ET.parse(metadata_file).getroot()
        except (ET.ParseError, OSError) as exc:
            raise ManifestError(f"Ungueltige metadata.xml in {mod_dir.name}: {exc}") from exc
        for tag, key in (("name", "name"), ("id", "workshop_id"), ("version", "version")):
            element = root.find(tag)
            if element is not None and element.text and element.text.strip():
                result[key] = element.text.strip()

    if not result["workshop_id"]:
        match = re.search(r"_(\d+)$", mod_dir.name)
        if match:
            result["workshop_id"] = match.group(1)
    if result["workshop_id"] and not str(result["workshop_id"]).isdigit():
        result["workshop_id"] = None
    return result


def digest_mod(mod_dir: Path) -> tuple[str, int, int]:
    """Hash regular mod files deterministically; ignore caches/logs/VCS metadata."""
    digest = hashlib.sha256()
    file_count = 0
    total_bytes = 0
    paths: list[Path] = []
    for root, dirs, files in os.walk(mod_dir, followlinks=False):
        root_path = Path(root)
        dirs[:] = [
            d for d in dirs
            if d.casefold() not in IGNORED_DIRS and not (root_path / d).is_symlink()
        ]
        for filename in files:
            path = root_path / filename
            if path.is_symlink() or path.suffix.casefold() in IGNORED_SUFFIXES:
                continue
            paths.append(path)

    paths.sort(key=lambda p: p.relative_to(mod_dir).as_posix().casefold())
    for path in paths:
        rel = path.relative_to(mod_dir).as_posix().encode("utf-8", errors="surrogateescape")
        digest.update(len(rel).to_bytes(4, "big"))
        digest.update(rel)
        size = path.stat().st_size
        digest.update(size.to_bytes(8, "big"))
        with path.open("rb") as stream:
            while True:
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
        file_count += 1
        total_bytes += size
    return digest.hexdigest(), file_count, total_bytes


def build_manifest(
    mods_dir: Path,
    log_path: Path,
    repentogon_version: str | None = None,
    game_version_override: str | None = None,
    repentogon_dir: Path | None = None,
) -> dict[str, Any]:
    mods_root = mods_dir.resolve()
    if not mods_root.is_dir():
        raise ManifestError(f"Mods-Ordner nicht gefunden: {mods_dir}")
    folders, detected_game_version = parse_loaded_mods(log_path)
    game_version = game_version_override or detected_game_version
    if not game_version:
        raise ManifestError("Spielversion nicht im Log gefunden; nutze --game-version.")

    rgon_root = repentogon_dir.resolve() if repentogon_dir else mods_root.parent / "Repentogon"
    detected_rg_version, rg_version_source = detect_repentogon_version(rgon_root)
    if repentogon_version:
        if detected_rg_version and detected_rg_version != repentogon_version:
            raise ManifestError(
                f"Angegebene Repentogon-Version {repentogon_version!r} widerspricht "
                f"der installierten Build-Version {detected_rg_version!r}."
            )
        if not RELEASE_VERSION_RE.fullmatch(repentogon_version):
            raise ManifestError(f"Ungueltige Repentogon-Release-Version: {repentogon_version!r}")
        final_rg_version = repentogon_version
        final_rg_source = rg_version_source or "manuelle Angabe"
    else:
        final_rg_version = detected_rg_version
        final_rg_source = rg_version_source

    mods = []
    ids_seen: set[str] = set()
    for order, folder in enumerate(folders):
        mod_dir = mods_root / folder
        if not mod_dir.is_dir():
            raise ManifestError(f"Geladener Mod-Ordner fehlt lokal: {folder}")
        metadata = read_metadata(mod_dir)
        workshop_id = metadata["workshop_id"]
        if workshop_id:
            if workshop_id in ids_seen:
                raise ManifestError(f"Doppelte Workshop-ID {workshop_id} in der geladenen Mod-Liste.")
            ids_seen.add(workshop_id)
        digest, file_count, total_bytes = digest_mod(mod_dir)
        mods.append({
            "order": order,
            "workshop_id": workshop_id,
            "folder": folder,
            "name": metadata["name"],
            "version": metadata["version"],
            "sha256": digest,
            "file_count": file_count,
            "bytes": total_bytes,
        })

    return {
        "format": FORMAT,
        "schema_version": SCHEMA_VERSION,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "game_version": game_version,
        "repentogon_version": final_rg_version,
        "repentogon_version_source": final_rg_source,
        "load_order_source": "game-log",
        "mods": mods,
    }


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        # Windows PowerShell's UTF-8 output may include a BOM.
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"Kann Manifest nicht lesen: {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("format") != FORMAT:
        raise ManifestError(f"Kein {FORMAT}-Manifest: {path}")
    if data.get("schema_version") != SCHEMA_VERSION or not isinstance(data.get("mods"), list):
        raise ManifestError(f"Nicht unterstuetzte oder unvollstaendige Manifest-Version: {path}")
    return data


def build_profile(manifest: dict[str, Any], name: str) -> dict[str, Any]:
    """Create a portable mods-only profile; deliberately exclude saves/settings."""
    profile_name = name.strip()
    if not profile_name or len(profile_name) > 80 or any(ord(char) < 32 for char in profile_name):
        raise ManifestError("Profilname muss 1 bis 80 druckbare Zeichen enthalten.")

    mod_set: list[dict[str, Any]] = []
    load_order: list[str] = []
    seen: set[str] = set()
    manifest_mods = manifest.get("mods")
    if not isinstance(manifest_mods, list):
        raise ManifestError("Manifest muss eine Mod-Liste enthalten.")
    for mod in manifest_mods:
        if not isinstance(mod, dict):
            raise ManifestError("Ungueltiger Mod-Eintrag im Manifest.")
        key = mod_key(mod)
        if key in seen:
            raise ManifestError(f"Doppelter Mod-Schluessel im Manifest: {key}")
        seen.add(key)
        # Keep set membership/version/hash separate from the independent order list.
        mod_set.append({
            "workshop_id": mod.get("workshop_id"),
            "folder": mod.get("folder"),
            "name": mod.get("name"),
            "version": mod.get("version"),
            "sha256": mod.get("sha256"),
        })
        load_order.append(key)
    mod_set.sort(key=mod_key)

    return {
        "format": PROFILE_FORMAT,
        "schema_version": PROFILE_SCHEMA_VERSION,
        "profile_name": profile_name,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "game_version": manifest.get("game_version"),
        "repentogon_version": manifest.get("repentogon_version"),
        "mod_set": mod_set,
        "load_order": load_order,
    }


def profile_to_manifest(profile: dict[str, Any]) -> dict[str, Any]:
    """Convert a validated profile to the comparison shape without changing it."""
    mod_set = profile.get("mod_set")
    load_order = profile.get("load_order")
    if not isinstance(mod_set, list) or not isinstance(load_order, list):
        raise ManifestError("Profil muss 'mod_set' und 'load_order' als Listen enthalten.")
    mods_by_key: dict[str, dict[str, Any]] = {}
    for mod in mod_set:
        if not isinstance(mod, dict):
            raise ManifestError("Ungueltiger Eintrag in mod_set.")
        workshop_id = mod.get("workshop_id")
        folder = mod.get("folder")
        sha256 = mod.get("sha256")
        if workshop_id is not None and (
            not isinstance(workshop_id, str) or not workshop_id.isdigit()
        ):
            raise ManifestError("Workshop-IDs im Profil muessen Ziffernfolgen sein.")
        if not isinstance(folder, str) or not folder:
            raise ManifestError("Jeder Profileintrag braucht einen Mod-Ordnernamen.")
        if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", sha256):
            raise ManifestError(f"Ungueltiger SHA-256 im Profil fuer {folder}.")
        key = mod_key(mod)
        if key in mods_by_key:
            raise ManifestError(f"Doppelter Mod-Schluessel im Profil: {key}")
        mods_by_key[key] = mod
    if any(not isinstance(key, str) for key in load_order):
        raise ManifestError("load_order darf nur Mod-Schluessel enthalten.")
    if len(load_order) != len(set(load_order)) or set(load_order) != set(mods_by_key):
        raise ManifestError("load_order muss jeden Mod aus mod_set genau einmal enthalten.")

    ordered_mods = []
    for order, key in enumerate(load_order):
        mod = dict(mods_by_key[key])
        mod["order"] = order
        ordered_mods.append(mod)
    return {
        "game_version": profile.get("game_version"),
        "repentogon_version": profile.get("repentogon_version"),
        "mods": ordered_mods,
    }


def load_profile(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"Kann Profil nicht lesen: {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("format") != PROFILE_FORMAT:
        raise ManifestError(f"Kein {PROFILE_FORMAT}-Profil: {path}")
    if data.get("schema_version") != PROFILE_SCHEMA_VERSION:
        raise ManifestError(f"Nicht unterstuetzte Profil-Version: {path}")
    profile_to_manifest(data)  # Validate set/order consistency before accepting it.
    return data


def compare_profile(profile: dict[str, Any], local_manifest: dict[str, Any]) -> list[str]:
    """Compare a mods-only profile against a fresh local manifest."""
    expected = profile_to_manifest(profile)
    return compare_manifests(expected, local_manifest)


def validate_mcm_export(data: Any) -> dict[str, Any]:
    if not isinstance(data, dict) or data.get("format") != MCM_EXPORT_FORMAT:
        raise ManifestError(f"Kein {MCM_EXPORT_FORMAT}-Export.")
    if data.get("schema_version") != SETTINGS_SCHEMA_VERSION:
        raise ManifestError("Nicht unterstuetzte MCM-Export-Version.")
    categories = data.get("categories")
    if not isinstance(categories, dict):
        raise ManifestError("MCM-Export muss 'categories' als Objekt enthalten.")
    try:
        serialized = json.dumps(data, ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError, RecursionError) as exc:
        raise ManifestError(f"MCM-Export enthaelt keinen gueltigen JSON-Wertebaum: {exc}") from exc
    if len(serialized.encode("utf-8")) > 1024 * 1024:
        raise ManifestError("MCM-Export ist groesser als 1 MiB.")
    for category, values in categories.items():
        if not isinstance(category, str) or not category.strip():
            raise ManifestError("MCM-Kategorien muessen nichtleere Namen haben.")
        if category.casefold() in MCM_LOCAL_CATEGORIES:
            raise ManifestError(f"Lokale MCM-Kategorie wird nicht synchronisiert: {category}")
        if not isinstance(values, dict):
            raise ManifestError(f"MCM-Kategorie {category!r} muss ein Objekt sein.")
    return categories


def load_mcm_export(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError, RecursionError) as exc:
        raise ManifestError(f"Kann MCM-Export nicht lesen: {path}: {exc}") from exc
    validate_mcm_export(data)
    return data


def capture_mcm_export(log_path: Path) -> dict[str, Any]:
    try:
        lines = log_path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    except OSError as exc:
        raise ManifestError(f"Kann Spiel-Log nicht lesen: {log_path}: {exc}") from exc
    for line in reversed(lines):
        marker_index = line.find(MCM_EXPORT_MARKER)
        if marker_index < 0:
            continue
        encoded = line[marker_index + len(MCM_EXPORT_MARKER):].strip()
        try:
            data = json.loads(encoded)
        except (json.JSONDecodeError, RecursionError) as exc:
            raise ManifestError(f"MCM-Exportmarker im Log enthaelt ungueltiges JSON: {exc}") from exc
        validate_mcm_export(data)
        return data
    raise ManifestError(
        f"Kein {MCM_EXPORT_MARKER}-Eintrag im Log. Im Spiel zuerst modsyncmcmexport ausfuehren."
    )


def build_settings_bundle(
    manifest: dict[str, Any], export: dict[str, Any], name: str, settings: list[str]
) -> dict[str, Any]:
    available = validate_mcm_export(export)
    if not settings:
        raise ManifestError("Waehle mindestens einen MCM-Wert explizit mit --setting aus.")
    if len(set(settings)) != len(settings):
        raise ManifestError("Ein MCM-Wert wurde mehrfach angegeben.")
    selected: dict[str, Any] = {}
    for selection in settings:
        if "::" not in selection:
            raise ManifestError(
                f"Ungueltige Auswahl {selection!r}; erwartet wird CATEGORY::SETTING_KEY."
            )
        category, setting_key = selection.split("::", 1)
        if not category or not setting_key:
            raise ManifestError(
                f"Ungueltige Auswahl {selection!r}; Kategorie und Setting-Schluessel sind erforderlich."
            )
        if category.casefold() in MCM_LOCAL_CATEGORIES:
            raise ManifestError(f"Persoenliche MCM-Kategorie darf nicht synchronisiert werden: {category}")
        if category not in available:
            raise ManifestError(f"MCM-Kategorie fehlt im Export: {category}")
        if setting_key not in available[category]:
            raise ManifestError(f"MCM-Setting fehlt im Export: {category}::{setting_key}")
        selected.setdefault(category, {})[setting_key] = available[category][setting_key]

    runtime_profile = build_profile(manifest, name)
    return {
        "format": SETTINGS_BUNDLE_FORMAT,
        "schema_version": SETTINGS_SCHEMA_VERSION,
        "bundle_name": name.strip(),
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "runtime_profile": runtime_profile,
        "mcm_categories": selected,
    }


def load_settings_bundle(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError, RecursionError) as exc:
        raise ManifestError(f"Kann Settings-Bundle nicht lesen: {path}: {exc}") from exc
    if not isinstance(data, dict) or data.get("format") != SETTINGS_BUNDLE_FORMAT:
        raise ManifestError(f"Kein {SETTINGS_BUNDLE_FORMAT}-Bundle: {path}")
    if data.get("schema_version") != SETTINGS_SCHEMA_VERSION:
        raise ManifestError("Nicht unterstuetzte Settings-Bundle-Version.")
    runtime_profile = data.get("runtime_profile")
    if not isinstance(runtime_profile, dict):
        raise ManifestError("Settings-Bundle enthaelt kein Runtime-Profil.")
    profile_to_manifest(runtime_profile)
    validate_mcm_export({
        "format": MCM_EXPORT_FORMAT,
        "schema_version": SETTINGS_SCHEMA_VERSION,
        "categories": data.get("mcm_categories"),
    })
    if not data["mcm_categories"]:
        raise ManifestError("Settings-Bundle enthaelt keine ausgewaehlten MCM-Kategorien.")
    return data


def compare_settings(bundle: dict[str, Any], local_export: dict[str, Any]) -> list[str]:
    expected_categories = bundle["mcm_categories"]
    current_categories = validate_mcm_export(local_export)
    differences: list[str] = []
    for category, expected in expected_categories.items():
        if category not in current_categories:
            differences.append(f"MCM-Kategorie fehlt lokal: {category}")
            continue
        for setting_key, expected_value in expected.items():
            if setting_key not in current_categories[category]:
                differences.append(f"MCM-Setting fehlt lokal: {category}::{setting_key}")
            elif current_categories[category][setting_key] != expected_value:
                differences.append(f"MCM-Setting unterscheidet sich: {category}::{setting_key}")
    return differences


def build_mcm_import(categories: dict[str, Any], purpose: str) -> dict[str, Any]:
    """Make a data-only payload consumed by the sandbox MCM bridge (never Lua code)."""
    validate_mcm_export({
        "format": MCM_EXPORT_FORMAT,
        "schema_version": SETTINGS_SCHEMA_VERSION,
        "categories": categories,
    })
    return {
        "format": MCM_IMPORT_FORMAT,
        "schema_version": SETTINGS_SCHEMA_VERSION,
        "purpose": purpose,
        "categories": categories,
    }


def prepare_settings_imports(
    bundle: dict[str, Any],
    local_manifest: dict[str, Any],
    local_export: dict[str, Any],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, list[str]]:
    """Prepare import and rollback JSON only when the exact mod profile matches."""
    runtime_differences = compare_profile(bundle["runtime_profile"], local_manifest)
    if runtime_differences:
        return None, None, runtime_differences

    current_categories = validate_mcm_export(local_export)
    missing: list[str] = []
    for category, selected_values in bundle["mcm_categories"].items():
        if category not in current_categories:
            missing.append(category)
            continue
        missing.extend(
            f"{category}::{setting_key}"
            for setting_key in selected_values
            if setting_key not in current_categories[category]
        )
    if missing:
        raise ManifestError(
            "Diese MCM-Kategorien/Settings fehlen lokal; Abbruch statt neue Werte anzulegen: "
            + ", ".join(missing)
        )
    import_payload = build_mcm_import(bundle["mcm_categories"], "host-settings")
    rollback_categories = {
        category: {setting_key: current_categories[category][setting_key] for setting_key in selected_values}
        for category, selected_values in bundle["mcm_categories"].items()
    }
    rollback_payload = build_mcm_import(rollback_categories, "restore-local-settings")
    return import_payload, rollback_payload, []


def mod_key(mod: dict[str, Any]) -> str:
    workshop_id = mod.get("workshop_id")
    if workshop_id:
        return f"workshop:{workshop_id}"
    return f"local:{str(mod.get('folder', '')).casefold()}"


def compare_manifests(host: dict[str, Any], local: dict[str, Any]) -> list[str]:
    differences: list[str] = []
    if host.get("game_version") != local.get("game_version"):
        differences.append(
            f"Spielversion unterschiedlich: Host={host.get('game_version')!r}, Client={local.get('game_version')!r}"
        )
    host_rg = host.get("repentogon_version")
    local_rg = local.get("repentogon_version")
    if not host_rg or not local_rg:
        differences.append("Repentogon-Version fehlt in mindestens einem Manifest; Kompatibilitaet nicht bestaetigt.")
    elif host_rg != local_rg:
        differences.append(f"Repentogon-Version unterschiedlich: Host={host_rg!r}, Client={local_rg!r}")

    host_mods = host["mods"]
    local_mods = local["mods"]
    host_by_key = {mod_key(mod): mod for mod in host_mods}
    local_by_key = {mod_key(mod): mod for mod in local_mods}

    for key, host_mod in host_by_key.items():
        client_mod = local_by_key.get(key)
        label = host_mod.get("name") or host_mod.get("folder") or key
        if client_mod is None:
            differences.append(f"Fehlt beim Client: {label} ({key})")
            continue
        if host_mod.get("version") != client_mod.get("version"):
            differences.append(
                f"Mod-Version unterschiedlich: {label} Host={host_mod.get('version')!r}, Client={client_mod.get('version')!r}"
            )
        if host_mod.get("sha256") != client_mod.get("sha256"):
            differences.append(f"Dateiinhalt unterschiedlich: {label} ({key})")

    for key, client_mod in local_by_key.items():
        if key not in host_by_key:
            label = client_mod.get("name") or client_mod.get("folder") or key
            differences.append(f"Zusaetzlicher Client-Mod: {label} ({key})")

    host_order = [mod_key(mod) for mod in host_mods]
    client_order = [mod_key(mod) for mod in local_mods]
    if host_order != client_order and set(host_order) == set(client_order):
        differences.append("Ladereihenfolge unterschiedlich.")
    return differences


def build_install_plan_html(
    host: dict[str, Any], local: dict[str, Any], match_type: str = "friend"
) -> str:
    """Build a review-only report; never downloads or changes local mods."""
    if match_type not in {"friend", "public", "quick"}:
        raise ManifestError(f"Unbekannter Match-Typ: {match_type}")
    host_mods = host["mods"]
    local_mods = local["mods"]
    local_by_key = {mod_key(mod): mod for mod in local_mods}
    host_keys = {mod_key(mod) for mod in host_mods}
    rows: list[str] = []

    if host.get("game_version") != local.get("game_version"):
        rows.append(
            '<tr class="bad"><td colspan="5">Spielversion abweichend: '
            f'{html.escape(str(host.get("game_version")))} (Host) / '
            f'{html.escape(str(local.get("game_version")))} (Client)</td></tr>'
        )
    host_rg, local_rg = host.get("repentogon_version"), local.get("repentogon_version")
    if host_rg != local_rg:
        rows.append(
            '<tr class="bad"><td colspan="5">Repentogon-Version abweichend oder unbekannt: '
            f'{html.escape(str(host_rg or "unbekannt"))} (Host) / '
            f'{html.escape(str(local_rg or "unbekannt"))} (Client)</td></tr>'
        )

    for host_mod in host_mods:
        key = mod_key(host_mod)
        client_mod = local_by_key.get(key)
        name = html.escape(str(host_mod.get("name") or host_mod.get("folder") or key))
        workshop_id = host_mod.get("workshop_id")
        safe_id = str(workshop_id) if workshop_id and str(workshop_id).isdigit() else None
        if safe_id and match_type == "friend":
            link = (
                f'<a href="https://steamcommunity.com/sharedfiles/filedetails/?id={safe_id}">'
                f"Workshop {safe_id}</a> (nur nach deiner Zustimmung)"
            )
        elif safe_id:
            link = f"Workshop-ID {safe_id}; Public/Quick: nur vorinstallierte, vertraute Mods verwenden"
        else:
            link = "kein Workshop-Link (lokaler Mod; Quelle separat pruefen)"
        if client_mod is None:
            state = "Fehlt beim Client"
            row_class = "bad"
            client_version = "—"
            host_hash = str(host_mod.get("sha256", ""))[:12]
        else:
            host_hash = str(host_mod.get("sha256", ""))[:12]
            client_hash = str(client_mod.get("sha256", ""))[:12]
            client_version = html.escape(str(client_mod.get("version") or "unbekannt"))
            if host_hash != client_hash or host_mod.get("sha256") != client_mod.get("sha256"):
                state = "Dateiinhalt abweichend"
                row_class = "bad"
            elif host_mod.get("version") != client_mod.get("version"):
                state = "Metadaten-Version abweichend"
                row_class = "warn"
            elif host_mod.get("order") != client_mod.get("order"):
                state = "Ladereihenfolge abweichend"
                row_class = "warn"
            else:
                state = "Identisch"
                row_class = "ok"
        host_version = html.escape(str(host_mod.get("version") or "unbekannt"))
        rows.append(
            f'<tr class="{row_class}"><td>{name}</td>'
            f'<td>{html.escape(str(workshop_id or "lokal"))}</td>'
            f'<td>{host_version}</td><td>{client_version}</td>'
            f'<td>{state}; {link}; Host-Hash {host_hash}</td></tr>'
        )

    for client_mod in local_mods:
        key = mod_key(client_mod)
        if key in host_keys:
            continue
        name = html.escape(str(client_mod.get("name") or client_mod.get("folder") or key))
        rows.append(
            f'<tr class="warn"><td>{name}</td><td>{html.escape(str(client_mod.get("workshop_id") or "lokal"))}</td>'
            '<td>nicht im Host-Manifest</td><td>installiert</td>'
            '<td>Vor einem Match manuell deaktivieren oder mit dem Host absprechen.</td></tr>'
        )

    if not rows:
        rows.append('<tr class="ok"><td colspan="5">Keine Abweichungen gefunden.</td></tr>')
    body = "\n".join(rows)
    if match_type == "friend":
        mode_notice = (
            "Installiere oder aktualisiere Mods nur nach deiner Zustimmung und nur, wenn du "
            "dem Host vertraust. Pruefe danach die Datei-Hashes erneut."
        )
    else:
        mode_notice = (
            "Keine Download-Links fuer Public/Quick-Matches: nur bereits installierte und "
            "vertraute Mods verwenden; bei unbekannten Mods abbrechen."
        )
    return f"""<!doctype html>
<html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Isaac Mod-Sync-Pruefplan</title>
<style>
body{{font:16px Segoe UI,Arial,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#222}}
.notice{{padding:1rem;background:#fff3cd;border:1px solid #e4c34d;border-radius:6px}}
table{{border-collapse:collapse;width:100%;margin-top:1rem}}th,td{{border:1px solid #bbb;padding:.55rem;text-align:left}}
th{{background:#eee}}.bad{{background:#ffe5e5}}.warn{{background:#fff5d8}}.ok{{background:#e5f6e8}}
code{{word-break:break-all}}
</style>
<h1>Isaac Mod-Sync-Pruefplan</h1>
<p>Match-Typ: <code>{html.escape(match_type)}</code>.</p>
<p>Host-Spielversion: <code>{html.escape(str(host.get('game_version') or 'unbekannt'))}</code>;
Repentogon: <code>{html.escape(str(host.get('repentogon_version') or 'unbekannt'))}</code>.</p>
<div class="notice"><strong>Nur ein Pruefplan:</strong> Es wurden keine Dateien installiert,
aktiviert oder geaendert. Workshop-Mods enthalten ausfuehrbaren Lua-Code.
{mode_notice} Eine gleiche Mod-Liste garantiert keine Desync-Freiheit.</div>
<table><thead><tr><th>Mod</th><th>ID</th><th>Host-Version</th><th>Client-Version</th><th>Status / Aktion</th></tr></thead>
<tbody>{body}</tbody></table>
</html>
"""


def command_create(args: argparse.Namespace) -> int:
    try:
        manifest = build_manifest(
            Path(args.mods_dir),
            Path(args.log),
            args.repentogon_version,
            args.game_version,
            Path(args.repentogon_dir) if args.repentogon_dir else None,
        )
        output = Path(args.output)
        output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except (ManifestError, OSError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    total = sum(mod["bytes"] for mod in manifest["mods"])
    print(f"Manifest geschrieben: {output}")
    print(f"Spiel={manifest['game_version']} Repentogon={manifest['repentogon_version'] or 'NICHT ERMITTELT'}")
    if manifest["repentogon_version_source"]:
        print(f"Repentogon-Quelle={manifest['repentogon_version_source']}")
    print(f"Geladene Mods={len(manifest['mods'])}; gehashte Daten={total:,} Bytes")
    if not manifest["repentogon_version"]:
        print(
            "WARNUNG: Keine vergleichbare Release-Version aus Repentogon/main_ex.lua ermittelt. "
            "Nutze --repentogon-dir oder gib eine verifizierte Version mit --repentogon-version an."
        )
    return 0


def command_compare(args: argparse.Namespace) -> int:
    try:
        host = load_manifest(Path(args.host))
        local = load_manifest(Path(args.local))
        differences = compare_manifests(host, local)
    except ManifestError as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    if not differences:
        print("MOD-MANIFESTE IDENTISCH: Versionen, Datei-Hashes und Reihenfolge stimmen ueberein.")
        return 0
    print(f"NICHT KOMPATIBEL: {len(differences)} Abweichung(en):")
    for difference in differences:
        print(f"  - {difference}")
    return 1


def command_plan(args: argparse.Namespace) -> int:
    try:
        host = load_manifest(Path(args.host))
        local = load_manifest(Path(args.local))
        report = build_install_plan_html(host, local, args.match_type)
        output = Path(args.output)
        output.write_text(report, encoding="utf-8")
    except (ManifestError, OSError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print(f"Pruefplan geschrieben: {output}")
    print("Nur Bericht: keine Downloads, Installationen oder Mod-Aktivierungen ausgefuehrt.")
    return 0


def command_profile_create(args: argparse.Namespace) -> int:
    try:
        manifest = load_manifest(Path(args.manifest))
        profile = build_profile(manifest, args.name)
        output = Path(args.output)
        serialized = json.dumps(profile, indent=2, ensure_ascii=False) + "\n"
        if args.overwrite:
            output.write_text(serialized, encoding="utf-8")
        else:
            # Exclusive create prevents silently replacing an existing profile.
            with output.open("x", encoding="utf-8", newline="\n") as stream:
                stream.write(serialized)
    except FileExistsError:
        print(
            f"FEHLER: Profil-Datei existiert bereits: {args.output} "
            "(zum bewussten Ersetzen --overwrite verwenden).",
            file=sys.stderr,
        )
        return 2
    except (ManifestError, OSError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print(f"Mod-Profil gespeichert: {output}")
    print(f"Name={profile['profile_name']} Mods={len(profile['mod_set'])}")
    print("Enthaelt nur Mod-Set und Ladereihenfolge; keine Saves oder Mod-Einstellungen.")
    print("Profil wurde nicht angewendet; aktive Mods und Spielstaende blieben unveraendert.")
    return 0


def command_profile_check(args: argparse.Namespace) -> int:
    try:
        profile = load_profile(Path(args.profile))
        local_manifest = load_manifest(Path(args.local))
        differences = compare_profile(profile, local_manifest)
    except ManifestError as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    if not differences:
        print(
            f"PROFIL PASST: {profile['profile_name']} - Versionen, Mod-Set, "
            "Datei-Hashes und Ladereihenfolge stimmen ueberein."
        )
        return 0
    print(f"PROFIL WEICHT AB: {profile['profile_name']} ({len(differences)} Abweichung(en)):")
    for difference in differences:
        print(f"  - {difference}")
    print("Nur geprueft: keine Mods aktiviert und keine Saves/Einstellungen uebertragen.")
    return 1


def write_json_new(path: Path, data: dict[str, Any]) -> None:
    serialized = json.dumps(data, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(serialized)


def command_settings_capture(args: argparse.Namespace) -> int:
    try:
        export = capture_mcm_export(Path(args.log))
        write_json_new(Path(args.output), export)
    except FileExistsError:
        print(f"FEHLER: Zieldatei existiert bereits: {args.output}", file=sys.stderr)
        return 2
    except (ManifestError, OSError, ValueError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print(f"MCM-Settings-Export gespeichert: {args.output}")
    print(f"Exportierte Kategorien={len(export['categories'])}; keine Saves gelesen.")
    return 0


def command_settings_list(args: argparse.Namespace) -> int:
    try:
        export = load_mcm_export(Path(args.export))
    except ManifestError as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    count = 0
    for category in sorted(export["categories"], key=str.casefold):
        for setting_key in sorted(export["categories"][category], key=str.casefold):
            print(f"{category}::{setting_key}")
            count += 1
    print(f"{count} auswaehlbare Kategorie/Schluessel-Paare; Werte nicht ausgegeben.")
    return 0


def command_settings_pack(args: argparse.Namespace) -> int:
    try:
        manifest = load_manifest(Path(args.manifest))
        export = load_mcm_export(Path(args.export))
        bundle = build_settings_bundle(manifest, export, args.name, args.setting)
        write_json_new(Path(args.output), bundle)
    except FileExistsError:
        print(f"FEHLER: Zieldatei existiert bereits: {args.output}", file=sys.stderr)
        return 2
    except (ManifestError, OSError, ValueError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print(f"Settings-Bundle gespeichert: {args.output}")
    setting_count = sum(len(values) for values in bundle["mcm_categories"].values())
    print(f"Mod-Profil={args.name}; ausgewaehlte MCM-Werte={setting_count}")
    print("Nur die mit --setting ausgewaehlten Kategorie/Schluessel-Werte sind enthalten; keine Saves.")
    return 0


def command_settings_compare(args: argparse.Namespace) -> int:
    try:
        bundle = load_settings_bundle(Path(args.bundle))
        local_export = load_mcm_export(Path(args.local_export))
        local_manifest = load_manifest(Path(args.local_manifest))
        runtime_differences = compare_profile(bundle["runtime_profile"], local_manifest)
        settings_differences = compare_settings(bundle, local_export)
    except ManifestError as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    differences = [f"Mod-Profil: {item}" for item in runtime_differences]
    differences.extend(settings_differences)
    if not differences:
        print(f"SETTINGS PASSEN: {bundle['bundle_name']} (Mods, Versionen und ausgewaehlte Werte).")
        return 0
    print(f"SETTINGS WEICHEN AB: {bundle['bundle_name']} ({len(differences)} Abweichung(en)):")
    for difference in differences:
        print(f"  - {difference}")
    return 1


def command_settings_prepare(args: argparse.Namespace) -> int:
    import_path = Path(args.output)
    rollback_path = Path(args.rollback_output)
    if import_path.resolve() == rollback_path.resolve():
        print("FEHLER: Import- und Rollback-Datei muessen unterschiedliche Pfade haben.", file=sys.stderr)
        return 2
    try:
        bundle = load_settings_bundle(Path(args.bundle))
        local_manifest = load_manifest(Path(args.local_manifest))
        local_export = load_mcm_export(Path(args.local_export))
        import_payload, rollback_payload, runtime_differences = prepare_settings_imports(
            bundle, local_manifest, local_export
        )
        if runtime_differences:
            print("ABBRUCH: Erst das Mod-Profil angleichen; Settings werden nicht vorbereitet:")
            for difference in runtime_differences:
                print(f"  - {difference}")
            return 1
        assert import_payload is not None and rollback_payload is not None

        if import_path.exists() or rollback_path.exists():
            existing = [str(path) for path in (import_path, rollback_path) if path.exists()]
            raise ManifestError("Zieldatei existiert bereits: " + ", ".join(existing))
        write_json_new(import_path, import_payload)
        try:
            write_json_new(rollback_path, rollback_payload)
        except Exception:
            # Remove only the new import file created by this invocation.
            import_path.unlink(missing_ok=True)
            raise
    except (ManifestError, OSError, ValueError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2

    print(f"Import-Vorschau erstellt: {import_path}")
    print(f"Lokaler Rollback fuer dieselben Kategorien: {rollback_path}")
    print("Noch nichts angewendet. Importiere nur nach Pruefung und ausdruecklicher Bestaetigung.")
    print("Das Sandbox-MCM-Bridge-Mod schreibt nur MCM-Kategorien in MCMs eigenes Mod-SaveData.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Isaac-Mod-Manifeste und Saves-freie Mod-Profile erstellen und pruefen."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create", help="Manifest der aktuell geladenen Mods erstellen")
    create.add_argument("--mods-dir", required=True, help="Isaac-Mods-Ordner")
    create.add_argument("--log", required=True, help="aktuelles Spiel-log.txt mit LOADED MOD-Zeilen")
    create.add_argument(
        "--repentogon-dir",
        help="Repentogon-Installationsordner (Standard: <Mods-Ordner-Elternordner>\\Repentogon)",
    )
    create.add_argument(
        "--repentogon-version",
        help="verifizierte Repentogon-Version manuell angeben; Widerspruch zur Installation wird abgelehnt",
    )
    create.add_argument("--game-version", help="Spielversion ueberschreiben (normalerweise aus dem Log erkannt)")
    create.add_argument("--output", default="mod-manifest.json", help="Zieldatei (JSON)")
    create.set_defaults(func=command_create)

    compare = subparsers.add_parser("compare", help="Host- und Client-Manifeste vergleichen")
    compare.add_argument("--host", required=True, help="Host-Manifest JSON")
    compare.add_argument("--local", required=True, help="lokales Client-Manifest JSON")
    compare.set_defaults(func=command_compare)

    plan = subparsers.add_parser("plan", help="HTML-Pruefplan fuer fehlende/abweichende Mods schreiben")
    plan.add_argument("--host", required=True, help="Host-Manifest JSON")
    plan.add_argument("--local", required=True, help="lokales Client-Manifest JSON")
    plan.add_argument("--match-type", choices=("friend", "public", "quick"), default="friend")
    plan.add_argument("--output", default="modsync-install-plan.html", help="HTML-Zieldatei")
    plan.set_defaults(func=command_plan)

    profile = subparsers.add_parser("profile", help="Saves-freie Mod-Profile verwalten")
    profile_subparsers = profile.add_subparsers(dest="profile_command", required=True)
    profile_create = profile_subparsers.add_parser(
        "create", help="Mod-Profil aus einem Manifest speichern (ohne Anwenden)"
    )
    profile_create.add_argument("--manifest", required=True, help="zuvor erstelltes Mod-Manifest")
    profile_create.add_argument("--name", required=True, help="Profilname, 1 bis 80 Zeichen")
    profile_create.add_argument("--output", default="mod-profile.json", help="Profil-JSON-Zieldatei")
    profile_create.add_argument(
        "--overwrite", action="store_true", help="bestehendes Profil an diesem Pfad bewusst ersetzen"
    )
    profile_create.set_defaults(func=command_profile_create)

    profile_check = profile_subparsers.add_parser(
        "check", help="gespeichertes Profil mit einem aktuellen Manifest vergleichen"
    )
    profile_check.add_argument("--profile", required=True, help="Mod-Profil JSON")
    profile_check.add_argument("--local", required=True, help="aktuelles lokales Mod-Manifest")
    profile_check.set_defaults(func=command_profile_check)

    settings = subparsers.add_parser(
        "settings", help="explizite MCM-Settings exportieren, vergleichen und vorbereiten"
    )
    settings_subparsers = settings.add_subparsers(dest="settings_command", required=True)

    settings_capture = settings_subparsers.add_parser(
        "capture", help="letzten MCM-Exportmarker aus dem Spiel-Log als JSON erfassen"
    )
    settings_capture.add_argument("--log", required=True, help="Isaac log.txt nach modsyncmcmexport")
    settings_capture.add_argument("--output", required=True, help="Zieldatei fuer den MCM-Export")
    settings_capture.set_defaults(func=command_settings_capture)

    settings_list = settings_subparsers.add_parser(
        "list", help="exportierte MCM-Kategorie/Schluessel-Paare ohne Werte anzeigen"
    )
    settings_list.add_argument("--export", required=True, help="MCM-Export JSON")
    settings_list.set_defaults(func=command_settings_list)

    settings_pack = settings_subparsers.add_parser(
        "pack", help="ausgewaehlte MCM-Kategorien an ein exaktes Mod-Profil binden"
    )
    settings_pack.add_argument("--manifest", required=True, help="Host-Mod-Manifest")
    settings_pack.add_argument("--export", required=True, help="MCM-Export JSON")
    settings_pack.add_argument("--name", required=True, help="Name des Settings-Bundles")
    settings_pack.add_argument(
        "--setting", action="append", required=True,
        help="einzelner MCM-Wert als CATEGORY::SETTING_KEY; mehrfach verwendbar",
    )
    settings_pack.add_argument("--output", required=True, help="neue Settings-Bundle JSON-Datei")
    settings_pack.set_defaults(func=command_settings_pack)

    settings_compare = settings_subparsers.add_parser(
        "compare", help="Settings und Mod-Profil vor einer Uebernahme vergleichen"
    )
    settings_compare.add_argument("--bundle", required=True, help="Host-Settings-Bundle")
    settings_compare.add_argument("--local-export", required=True, help="lokaler MCM-Export JSON")
    settings_compare.add_argument("--local-manifest", required=True, help="aktuelles lokales Mod-Manifest")
    settings_compare.set_defaults(func=command_settings_compare)

    settings_prepare = settings_subparsers.add_parser(
        "prepare", help="Importdaten plus lokalen Rollback vorbereiten, ohne sie anzuwenden"
    )
    settings_prepare.add_argument("--bundle", required=True, help="Host-Settings-Bundle")
    settings_prepare.add_argument("--local-export", required=True, help="lokaler MCM-Export JSON")
    settings_prepare.add_argument("--local-manifest", required=True, help="aktuelles lokales Mod-Manifest")
    settings_prepare.add_argument("--output", required=True, help="MCM-Import JSON")
    settings_prepare.add_argument("--rollback-output", required=True, help="lokaler Settings-Rollback JSON")
    settings_prepare.set_defaults(func=command_settings_prepare)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
