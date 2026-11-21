#!/usr/bin/env python3
"""Create, compare, and safely apply local Isaac mod profiles.

This tool never downloads or copies mod content. Profile application only toggles
REPENTOGON's per-mod disable.it markers after exact local hash/version checks.
It records mods loaded according to the game's log, their order, and file hashes.

Examples:
  python tools/modsync.py create --mods-dir "...\\mods" --log "...\\log.txt" \
      --output host-mods.json
  python tools/modsync.py compare --host host-mods.json --local client-mods.json
  python tools/modsync.py profile create --manifest host-mods.json \
      --name "Co-op set" --output coop-profile.json
  python tools/modsync.py profile apply --profile coop-profile.json \
      --local-manifest client-mods.json --mods-dir "...\\mods" \
      --rollback-output client-mod-state-before.json --apply
  python tools/modsync.py profile stage --profile coop-profile.json \
      --local-manifest client-mods.json --mods-dir "...\\mods" \
      --output "%TEMP%\\IsaacModSyncSessions\\<session-id>"
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from bisect import bisect_right
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4


FORMAT = "isaac-mod-sync-manifest"
SCHEMA_VERSION = 1
PROFILE_FORMAT = "isaac-mod-profile"
PROFILE_SCHEMA_VERSION = 1
TOOL_VERSION = "0.0.6"
SAVEDATA_SESSION_FORMAT = "isaac-modsync-savedata-session"
DESYNC_MONITOR_VERSION = "0.0.6"
PROFILE_ROLLBACK_FORMAT = "isaac-mod-profile-rollback"
PROFILE_ROLLBACK_SCHEMA_VERSION = 1
SESSION_FORMAT = "isaac-mod-profile-session"
SESSION_SCHEMA_VERSION = 1
ISAAC_APP_ID = "250900"
LOBBY_OBSERVER_FOLDER = "zz_modsync_lobby_exit_observer"
LOBBY_OBSERVER_NAME = "ModSync Lobby Exit Observer"
LOBBY_OBSERVER_METADATA = """<?xml version="1.0" encoding="UTF-8"?>
<metadata><name>ModSync Lobby Exit Observer</name><version>0.0.6</version></metadata>
"""
LOBBY_OBSERVER_LUA = r'''-- Temporary session observer. It logs lobby-menu transitions only;
-- it does not change gameplay, send network data, or close the game.
local observer = RegisterMod("ModSync Lobby Exit Observer", 1)
local seenOnlineLobby = false
local progress = {
    phase = "idle",
    percent = 0,
    message = "Isaac ModSync",
}
Isaac.DebugString("[modsync-lobby] observer ready")

local function renderProgress()
    if type(Isaac) ~= "table" or type(Isaac.RenderScaledText) ~= "function" then
        return
    end
    local percent = math.floor(math.max(0, math.min(100, tonumber(progress.percent) or 0)))
    local phaseText = tostring(progress.phase or "idle")
    local text = string.format("[ModSync] %s %.0f%%", phaseText, percent)
    local okRender, errRender = pcall(function()
        Isaac.RenderScaledText(text, 0.5, 0.5, 0.05, { 1, 1, 1, 1 })
    end)
    if not okRender then
        Isaac.DebugString("[modsync-lobby] progress render failed: " .. tostring(errRender))
    end
end

local function onUpdate()
    if type(MenuManager) ~= "table" or type(MainMenuType) ~= "table" then
        return
    end
    local activeOk, active = pcall(MenuManager.IsActive)
    if not activeOk or not active then
        return
    end
    local menuOk, menu = pcall(MenuManager.GetActiveMenu)
    if not menuOk then
        return
    end
    if menu == MainMenuType.ONLINELOBBY then
        if not seenOnlineLobby then
            Isaac.DebugString("[modsync-lobby] lobby-menu-enter=" .. tostring(menu))
        end
        seenOnlineLobby = true
        renderProgress()
        return
    end
    -- Any active main-menu section other than the lobby after the lobby was seen
    -- means the user backed out or returned from a run to the menu.
    if seenOnlineLobby then
        seenOnlineLobby = false
        Isaac.DebugString("[modsync-lobby] lobby-menu-exit=" .. tostring(menu))
    end
end

observer:AddCallback(ModCallbacks.MC_MAIN_MENU_RENDER, onUpdate)

-- === Isaac Desync Monitor (temporary helper, v0.0.6) ===
-- Writes diagnostic markers only. It never changes gameplay or contacts Steam.
local EXPECTED_ORDER = { @@EXPECTED_ORDER@@ }
local EXPECTED_HASHES = {
@@EXPECTED_HASHES@@
}
local monitor = RegisterMod("ModSync Desync Monitor", 1)
local lastSignature = nil
local function fnv1a(text)
    local hash = 2166136261
    for i = 1, #text do
        hash = (hash * 16777619) % 4294967296
        hash = math.floor(hash) % 4294967296
        hash = (hash + string.byte(text, i)) % 4294967296
    end
    return string.format("%08x", hash)
end
local function poolChecksum()
    local ok, result = pcall(function()
        local config = Isaac.GetItemConfig()
        local parts = {}
        for id = 1, 732 do
            local entry = config:GetCollectible(id)
            if entry then parts[#parts + 1] = tostring(entry.Name or id) end
        end
        return fnv1a(table.concat(parts, "|"))
    end)
    return ok and result or "unavailable"
end
local function loadedFilesChecksum()
    local ok, files = pcall(function()
        if type(Debug) ~= "table" or type(Debug.ListLoadedFiles) ~= "function" then return {} end
        return Debug.ListLoadedFiles() or {}
    end)
    if not ok then return "unavailable" end
    local names = {}
    for _, path in ipairs(files) do names[#names + 1] = tostring(path) end
    table.sort(names)
    return fnv1a(table.concat(names, "|")), names
end
local function checkLoadOrder()
    local checksum, names = loadedFilesChecksum()
    if checksum == "unavailable" then return end
    local found = {}
    for _, path in ipairs(names) do
        for _, expected in ipairs(EXPECTED_ORDER) do
            if tostring(path):find(tostring(expected), 1, true) then found[expected] = true end
        end
    end
    local missing = {}
    for _, expected in ipairs(EXPECTED_ORDER) do
        if not found[expected] then missing[#missing + 1] = tostring(expected) end
    end
    if #missing > 0 then
        Isaac.DebugString("[modsync-desync] reason=mod-load-order severity=critical affected="
            .. tostring(missing[1]) .. " checksum=" .. tostring(checksum))
    end
end
local function sampleState()
    local ok, seed, stage, room = pcall(function()
        local game = Game()
        return tostring(game:GetSeeds():GetStartSeed()), tostring(game:GetLevel():GetStage()),
            tostring(game:GetLevel():GetCurrentRoomIndex())
    end)
    if not ok then return nil end
    return seed .. "/" .. stage .. "/" .. room
end
local function onDesyncCheck()
    if type(Game) ~= "function" or not Game():IsLoaded() then return end
    local signature = sampleState()
    if not signature then return end
    if lastSignature and signature ~= lastSignature then
        Isaac.DebugString("[modsync-desync] reason=room-transition signature=" .. signature
            .. " pool=" .. poolChecksum())
    end
    lastSignature = signature
end
monitor:AddCallback(ModCallbacks.MC_POST_MODS_LOADED, checkLoadOrder)
monitor:AddCallback(ModCallbacks.MC_POST_UPDATE, onDesyncCheck)
Isaac.DebugString("[modsync-desync] monitor ready version=" .. tostring(@@DESYNC_VERSION@@)
    .. " expected_mods=" .. tostring(#EXPECTED_ORDER))
'''
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
METADATA_FILENAME = "metadata.xml"
CONTENT_SUFFIXES = {".lua", ".xml", ".anm2", ".png", ".stb"}
# Dateiendungen, die in einem Workshop-Mod nie ausfuehrbar sein duerfen.
DANGEROUS_EXTENSIONS = {
    ".exe", ".dll", ".bat", ".cmd", ".ps1", ".vbs", ".scr", ".jar", ".com",
    ".pif", ".msi", ".hta", ".js", ".jse", ".wsf", ".wsh", ".cpl", ".gadget",
}
SECURITY_REPORT_FORMAT = "isaac-mod-security-report"
SECURITY_REPORT_SCHEMA_VERSION = 1


class ManifestError(Exception):
    pass


# ---------------------------------------------------------------------------
# ModSecurityScanner: rein, deterministisch, ohne externe Abhaengigkeiten.
# Die Lua-Analyse arbeitet auf einer "bereinigten" Kopie, in der String- und
# Kommentar-Inhalte durch Leerzeichen ersetzt werden (Zeilen/u. a. Laengen
# bleiben erhalten). So werden datatype Inhalte - z. B. FiendFolio's
# 240.000-Zeilen-Glueckswunsch-Text mit dem Scherz "os.execute" - nicht als
# ausfuehrbarer Code fehlinterpretiert.
# ---------------------------------------------------------------------------

_LUA_SHORT_STRING_RE = re.compile(r'"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'')
_LUA_LONG_COMMENT_RE = re.compile(r"--\[(=*)\[[\s\S]*?\]\1\]")
_LUA_LONG_BRACKET_RE = re.compile(r"\[(=*)\[[\s\S]*?\]\1\]")
_LUA_LINE_COMMENT_RE = re.compile(r"--[^\n]*")
_LUA_STRING_LITERAL_RE = re.compile(r'"((?:\\.|[^"\\])*)"|\'((?:\\.|[^\'\\])*)\'')
_LUA_LOAD_CALL_RE = re.compile(r"(?<![\w.:])(?:loadstring|load)\s*\(")
_LUA_REQUIRE_RE = re.compile(r"\brequire\s*\(\s*([^\n)]{0,120})")
_LUA_REQUIRE_DEFINITION_RE = re.compile(r"(?:local\s+)?function\s+$")
# 'require(dir .. "enums")' ist ein normaler, mod-lokaler Modulpfad: der
# dynamische Anteil ist ein Verzeichnis-Prefix, keine externe Eingabe.
_LUA_REQUIRE_LOCAL_PATH_RE = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\s*\.\.\s*[\"']"
    r"|[\"'][^\"']*[\"']\s*\.\.\s*[A-Za-z_][A-Za-z0-9_]*"
)
_LUA_STATIC_LONG_BRACKET_RE = re.compile(r"\[=*\[")
_LUA_IO_CALL_RE = re.compile(r"\bio\.(?:open|lines|output)\s*\(", re.IGNORECASE)
_LUA_BASE64_RE = re.compile(r"[A-Za-z0-9+/]{81,}={0,2}")
_LUA_HEX_RE = re.compile(r"(?:0[xX])?[0-9A-Fa-f]{81,}")
# Billiger Vorfilter: Dateien ohne jeden relevanten Token brauchen nicht
# bereinigt und mehrfach durchsucht zu werden.
_LUA_INTEREST_RE = re.compile(
    r"os\.execute|io\.popen|package\.loadlib|loadstring|\bload\s*\(|\brequire\s*\("
    r"|\bio\.(?:open|lines|output)\s*\(|debug\.(?:getregistry|setmetatable)"
    r"|[A-Za-z0-9+/]{81,}",
    re.IGNORECASE,
)
_LUA_DANGEROUS_CALLS = (
    (re.compile(r"\bos\.execute\s*\("), "Aufruf von os.execute (Befehlsausfuehrung)"),
    (re.compile(r"\bio\.popen\s*\("), "Aufruf von io.popen (Prozessausfuehrung)"),
    (re.compile(r"\bpackage\.loadlib\s*\("), "Aufruf von package.loadlib (native Bibliothek)"),
    (
        re.compile(r"\bdebug\.(?:getregistry|setmetatable)\s*\("),
        "Missbrauch von debug.getregistry/debug.setmetatable",
    ),
)


def _mod_rel(path: Path, root: Path) -> str:
    """Relative, plattformunabhaengige Pfadangabe innerhalb des Mod-Ordners."""
    return os.path.relpath(str(path), str(root)).replace("\\", "/")


def _iter_mod_files(mod_dir: Path):
    """Liefert (relativer Pfad, Path, ist Symlink); folgt keinen Symlink-Verzeichnissen."""
    root = Path(mod_dir)
    if root.is_symlink():
        yield _mod_rel(root, root), root, True
        return
    if not root.is_dir():
        return
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        base = Path(dirpath)
        base_rel = os.path.relpath(dirpath, str(root)).replace("\\", "/")
        prefix = "" if base_rel == "." else base_rel + "/"
        kept: list[str] = []
        for name in dirnames:
            child = base / name
            if child.is_symlink():
                yield prefix + name, child, True
            else:
                kept.append(name)
        dirnames[:] = kept
        for name in filenames:
            child = base / name
            yield prefix + name, child, child.is_symlink()


def _scan_mod_entries(mod_dir: Path) -> tuple[list[str], list[str], int]:
    """Ein einziger Durchlauf fuer gefaehrliche Dateien, Lua und Dateizahl."""
    dangerous: list[str] = []
    findings: list[tuple[str, int, str]] = []
    scanned = 0
    for rel, path, is_link in _iter_mod_files(mod_dir):
        scanned += 1
        if is_link or path.suffix.casefold() in DANGEROUS_EXTENSIONS:
            dangerous.append(rel)
            continue
        if path.suffix.casefold() != ".lua":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            findings.append((rel, 0, f"Lua-Datei nicht lesbar: {exc}"))
            continue
        findings.extend(_scan_lua_text(text, rel))
    findings.sort(key=lambda item: (item[0], item[1], item[2]))
    formatted = [
        f"{file}:{line}: {message}" if line else f"{file}: {message}"
        for file, line, message in findings
    ]
    return sorted(dangerous), formatted, scanned


def scan_dangerous_files(mod_dir: Path) -> list[str]:
    """Findet rekursiv gefaehrliche Dateiendungen und alle symbolischen Links.

    Rueckgabe: relative Pfade (positionunabhaengig sortiert). Symlinks werden
    unabhaengig von ihrer Endung gemeldet; Symlink-Verzeichnisse werden nicht
    betreten.
    """
    findings: list[str] = []
    for rel, path, is_link in _iter_mod_files(mod_dir):
        if is_link or path.suffix.casefold() in DANGEROUS_EXTENSIONS:
            findings.append(rel)
    return sorted(findings)


def _blank(text: str) -> str:
    """Ersetzt Zeichen durch Leerzeichen, behaelt aber Zeilenumbrueche."""
    return re.sub(r"[^\n]", " ", text)


def _blank_match(match: re.Match[str]) -> str:
    return _blank(match.group(0))


def _mask_short_string(match: re.Match[str]) -> str:
    value = match.group(0)
    if len(value) <= 2:
        return value
    return value[0] + _blank(value[1:-1]) + value[-1]


def _mask_long_string(match: re.Match[str]) -> str:
    value = match.group(0)
    delimiter_len = len(match.group(1)) + 2  # z. B. '[==['
    if len(value) <= 2 * delimiter_len:
        return value
    return value[:delimiter_len] + _blank(value[delimiter_len:-delimiter_len]) + value[-delimiter_len:]


def _sanitize_lua(text: str) -> str:
    """Maskiert Lua-Strings/Kommentare, ohne Zeilennummern zu verschieben."""
    code = _LUA_SHORT_STRING_RE.sub(_mask_short_string, text)
    code = _LUA_LONG_COMMENT_RE.sub(_blank_match, code)
    code = _LUA_LONG_BRACKET_RE.sub(_mask_long_string, code)
    code = _LUA_LINE_COMMENT_RE.sub(_blank_match, code)
    return code


def _line_starts(text: str) -> list[int]:
    return [0] + [match.end() for match in re.finditer(r"\n", text)]


def _lua_string_values(text: str) -> list[str]:
    values: list[str] = []
    for match in _LUA_STRING_LITERAL_RE.finditer(text):
        raw = match.group(1) if match.group(1) is not None else match.group(2)
        values.append(raw.replace("\\\\", "\\").replace('\\"', '"').replace("\\'", "'"))
    return values


def _is_local_identifier(code: str, name: str) -> bool:
    """Ist der Name eine lokale Variable/Parameter dieser Lua-Datei?"""
    escaped = re.escape(name)
    if re.search(rf"\blocal\s+{escaped}\b", code):
        return True
    if re.search(rf"\bfunction\s+[A-Za-z_][\w.:]*\s*\([^)\n]*\b{escaped}\b", code):
        return True
    return False


def _path_is_outside(value: str) -> bool:
    """Erkennt typische Pfade ausserhalb des Mod-Ordners."""
    candidate = value.strip()
    if not candidate:
        return False
    if re.match(r"^[A-Za-z]:[\\/]", candidate):  # C:\..., D:/...
        return True
    if candidate.startswith("\\\\") or candidate.startswith("//"):  # UNC
        return True
    if re.search(r"%[A-Za-z_][A-Za-z0-9_]*%", candidate):  # %APPDATA%, %TEMP%, ...
        return True
    normalized = candidate.replace("\\", "/")
    if normalized.startswith("/") or normalized.startswith("~/"):  # /etc/, ~/...
        return True
    parts = normalized.split("/")
    if ".." in parts:  # ../ oder foo/../bar
        return True
    return False


def _scan_lua_text(text: str, rel: str) -> list[tuple[str, int, str]]:
    """Analysiert eine Lua-Quelle; Rueckgabe (Datei, Zeile, deutsche Meldung)."""
    if not _LUA_INTEREST_RE.search(text):
        return []
    findings: list[tuple[str, int, str]] = []
    code = _sanitize_lua(text)
    starts = _line_starts(code)
    raw_lines = text.splitlines()

    for pattern, message in _LUA_DANGEROUS_CALLS:
        for match in pattern.finditer(code):
            line = bisect_right(starts, match.start())
            findings.append((rel, line, f"{message} (unerlaubter Aufruf)."))

    for match in _LUA_REQUIRE_RE.finditer(code):
        line = bisect_right(starts, match.start())
        line_prefix = code[starts[line - 1]:match.start()]
        if _LUA_REQUIRE_DEFINITION_RE.search(line_prefix):
            continue  # 'local function require(file, ...)' ist eine Definition
        argument = match.group(1).lstrip()
        if argument[:1] in ('"', "'") or _LUA_STATIC_LONG_BRACKET_RE.match(argument):
            continue  # statischer Modulname wie require("mcm") - voellig normal
        if _LUA_REQUIRE_LOCAL_PATH_RE.match(argument):
            continue  # mod-lokales Verzeichnis + Modulname
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", argument) and _is_local_identifier(code, argument):
            continue  # lokale Variable oder Funktionsparameter dieser Datei
        findings.append((rel, line, "require() mit dynamischem Modulpfad (Nachladen fremden Codes)."))

    for match in _LUA_IO_CALL_RE.finditer(code):
        line = bisect_right(starts, match.start())
        raw_line = raw_lines[line - 1] if 0 < line <= len(raw_lines) else ""
        suspicious = [value for value in _lua_string_values(raw_line) if _path_is_outside(value)]
        if not suspicious and any(
            token in raw_line for token in ("%APPDATA%", "os.getenv", "/etc/", "C:\\", "C:/")
        ):
            suspicious = ["dynamischer Pfad"]
        if suspicious:
            findings.append((
                rel,
                line,
                f"Dateizugriff ausserhalb des Mod-Ordners ({suspicious[0]}).",
            ))

    # Base64/Hex-Shellcode in Verbindung mit loadstring()/load(): die Zeilen
    # werden im Rohtext geprueft (der Code-Text hat Strings ja maskiert).
    for match in _LUA_LOAD_CALL_RE.finditer(code):
        line = bisect_right(starts, match.start())
        call_name = "loadstring" if "loadstring" in match.group(0) else "load"
        found: tuple[int, str] | None = None
        for offset in range(max(0, line - 5), min(len(raw_lines), line + 1)):
            raw_line = raw_lines[offset]
            base64 = _LUA_BASE64_RE.search(raw_line)
            hexcode = _LUA_HEX_RE.search(raw_line)
            hit = base64 or hexcode
            if hit:
                found = (offset + 1, "Base64" if base64 else "Hex")
                break
        if found:
            findings.append((
                rel,
                found[0],
                f"Verschleierter Code: langer {found[1]}-String in Verbindung mit {call_name}().",
            ))

    # Mehrfachmeldungen derselben Zeile/Sache vermeiden.
    return sorted(set(findings), key=lambda item: (item[0], item[1], item[2]))


def scan_lua_sources(mod_dir: Path) -> list[str]:
    """Meldet gefaehrliche Lua-Konstrukte als 'Datei:Zeile: Meldung'."""
    findings: list[tuple[str, int, str]] = []
    for rel, path, is_link in _iter_mod_files(mod_dir):
        if is_link or path.suffix.casefold() != ".lua":
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            findings.append((rel, 0, f"Lua-Datei nicht lesbar: {exc}"))
            continue
        findings.extend(_scan_lua_text(text, rel))
    findings.sort(key=lambda item: (item[0], item[1], item[2]))
    return [
        f"{rel}:{line}: {message}" if line else f"{rel}: {message}"
        for rel, line, message in findings
    ]


def scan_mod_security(mod_dir: Path) -> dict[str, Any]:
    """Gesamtscan eines Mods; ANY Finding blockiert."""
    dangerous, lua_findings, scanned_files = _scan_mod_entries(mod_dir)
    findings = dangerous + lua_findings
    return {
        "status": "blocked" if findings else "ok",
        "findings": findings,
        "scanned_files": scanned_files,
    }


def defender_scan(path: Path) -> dict[str, Any]:
    """Optionaler Windows-Defender-Einzelscan. Bei Fehlern fail-open."""
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    candidates = [
        Path(program_files) / "Windows Defender" / "MpCmdRun.exe",
        Path(r"C:\Program Files\Windows Defender\MpCmdRun.exe"),
    ]
    seen: set[str] = set()
    for executable in candidates:
        key = str(executable).casefold()
        if key in seen or not executable.is_file():
            continue
        seen.add(key)
        try:
            result = subprocess.run(
                [str(executable), "-Scan", "-ScanType", "3", "-File", str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=120,
                check=False,
            )
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return {"ran": False, "exit_code": None, "clean": True}
        return {
            "ran": True,
            "exit_code": result.returncode,
            "clean": result.returncode == 0,
        }
    return {"ran": False, "exit_code": None, "clean": True}


class LobbyLogTracker:
    """Interpret complete lines from one *fresh* Isaac log as untrusted hints.

    The caller must start at the beginning of the current game session, reset
    on log replacement/truncation, and verify any candidate through Steam. A
    menu transition does not establish lobby membership or prove a lobby ended.
    This parser does not perform I/O or contact Steam.
    """

    JOINED = re.compile(r"^\[INFO\] - Successfully joined lobby ([0-9]{10,20})\s*$")
    ENTERED = re.compile(r"^\[INFO\] - Lua Debug: \[modsync-lobby\] lobby-menu-enter=17\s*$")
    EXITED = re.compile(r"^\[INFO\] - Lua Debug: \[modsync-lobby\] lobby-menu-exit=([0-9]+)\s*$")
    MAX_PARTIAL = 65536

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self._pending = b""
        self.candidate_lobby: int | None = None
        self.menu_active = False

    def feed(self, chunk: bytes) -> list[tuple[str, int | None]]:
        """Consume bytes, emitting events only after a complete newline."""
        if not isinstance(chunk, bytes):
            raise TypeError("Lobby log input must be bytes")
        data = self._pending + chunk
        lines = data.split(b"\n")
        self._pending = lines.pop()
        if len(self._pending) > self.MAX_PARTIAL or any(len(line) > self.MAX_PARTIAL for line in lines):
            self.reset()
            raise ManifestError("Ueberlange Lobby-Logzeile; Logzustand verworfen.")
        events: list[tuple[str, int | None]] = []
        for raw in lines:
            line = raw.decode("utf-8", errors="replace").rstrip("\r")
            joined = self.JOINED.fullmatch(line)
            if joined:
                candidate = int(joined.group(1))
                if 0 < candidate <= (1 << 64) - 1:
                    self.candidate_lobby = candidate
                    self.menu_active = False
                    events.append(("lobby_candidate", candidate))
            elif self.ENTERED.fullmatch(line):
                self.menu_active = True
                events.append(("lobby_menu_enter", self.candidate_lobby))
            elif self.EXITED.fullmatch(line) and self.menu_active:
                self.menu_active = False
                events.append(("lobby_menu_exit", self.candidate_lobby))
                self.candidate_lobby = None
        return events


def parse_loaded_mods(log_path: Path, allow_empty: bool = False) -> tuple[list[str], str | None]:
    """Return the latest enabled-mod list in its logged order and game version.

    LOADED MOD describes discovered folders, including disabled ones. When the
    game prints its explicit enabled block, that block is authoritative. Older
    or synthetic logs without such a block retain the legacy discovery fallback.
    """
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
    # Ein Vanilla-Start (--repentogonoff) hinterlaesst einen `begin list mods`
    # ohne REPENTOGON-Enabled-Block. Das darf den LAUNCH nicht mit Exit 2
    # abbrechen: bevorzugt wird der letzte vollstaendige Block, sonst der
    # letzte Block mit LOADED-MOD-Entdeckungen.
    boundaries = [0] + starts + [len(lines)]
    blocks = [lines[boundaries[i]:boundaries[i + 1]] for i in range(len(boundaries) - 1)]

    def has_complete_enabled(block: list[str]) -> bool:
        has_start = any("-- enabled mods start --" in line.casefold() for line in block)
        has_end = any("-- enabled mods end --" in line.casefold() for line in block)
        return has_start and has_end

    complete_blocks = [block for block in reversed(blocks) if has_complete_enabled(block)]
    if complete_blocks:
        current_list = complete_blocks[0]
    else:
        discovery_blocks = [
            block for block in reversed(blocks)
            if any("LOADED MOD" in line.upper() for line in block)
        ]
        current_list = discovery_blocks[0] if discovery_blocks else blocks[-1]
    enabled_starts = [i for i, line in enumerate(current_list) if "-- enabled mods start --" in line.casefold()]
    discovery_lines = current_list[:enabled_starts[-1]] if enabled_starts else current_list
    for line in discovery_lines:
        if "LOADED MOD" not in line.upper():
            continue
        match = LOADED_MOD_RE.search(line)
        if not match:
            continue
        folder = match.group("folder").strip()
        key = folder.casefold()
        # This temporary monitor is injected identically by both session
        # runners, but it is not part of the host's gameplay mod profile.
        if key == LOBBY_OBSERVER_FOLDER.casefold():
            continue
        if key not in seen:
            seen.add(key)
            folders.append(folder)

    if enabled_starts:
        start = enabled_starts[-1]
        ends = [i for i in range(start + 1, len(current_list))
                if "-- enabled mods end --" in current_list[i].casefold()]
        if not ends:
            raise ManifestError("Aktivierte Mod-Liste im Spiel-Log ist unvollstaendig; bitte erneut nach Spielstart erfassen.")
        discovered = {folder.casefold(): folder for folder in folders}
        enabled: list[str] = []
        enabled_seen: set[str] = set()
        for line in current_list[start + 1:ends[0]]:
            folder = line.strip()
            if not folder:
                continue
            key = folder.casefold()
            if key == LOBBY_OBSERVER_FOLDER.casefold():
                continue
            if key in enabled_seen:
                raise ManifestError(f"Doppelter Eintrag in aktivierter Mod-Liste: {folder}")
            if key not in discovered:
                raise ManifestError(f"Aktivierter Mod hat keinen passenden LOADED-MOD-Pfad: {folder}")
            enabled_seen.add(key)
            enabled.append(discovered[key])
        folders = enabled

    if not folders and not allow_empty:
        raise ManifestError(
            "Im Log wurden keine aktivierten Mods mit passenden Mod-Pfaden gefunden. "
            "Starte das Spiel mit den gewuenschten Mods und verwende dessen aktuelles log.txt "
            "(oder nutze --allow-empty fuer eine lokale Versionspruefung)."
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
    """Hash regular mod content files deterministically; ignore caches/logs/VCS metadata.

    Isaac normalizes ``metadata.xml`` while loading a mod (reformatting and
    extending the document), so the raw metadata file must not participate in
    the content digest. Otherwise the engine's automatic normalization surfaces
    as a false hash mismatch. All actual mod content files (``.lua``,
    ``Content-*.xml``, ``.anm2``, ``.png``, ``.stb``) are hashed strictly.
    """
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
            if (
                path.is_symlink()
                or path.name.casefold() == METADATA_FILENAME.casefold()
                or (path.parent == mod_dir and path.name.casefold() == "disable.it")
                or path.suffix.casefold() not in CONTENT_SUFFIXES
            ):
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


def sha256_file(path: Path) -> str | None:
    """SHA-256 of a build artifact, or None when the file is absent."""
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise ManifestError(f"Kann Build-Datei nicht hashen: {path}: {exc}") from exc
    return digest.hexdigest()


def load_order_keys(manifest_or_profile: dict[str, Any]) -> list[str]:
    """Canonical mod identity list in the exact order recorded by the game log."""
    stored_order = manifest_or_profile.get("load_order")
    if isinstance(stored_order, list) and stored_order:
        return [str(value) for value in stored_order]
    mods = manifest_or_profile.get("mods") or manifest_or_profile.get("mod_set") or []
    return [mod_key(mod) for mod in mods]


def load_order_digest(keys: list[str]) -> str:
    payload = json.dumps(keys, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def capture_build_hashes(repentogon_dir: Path) -> dict[str, str | None]:
    """Hash the two binaries that actually determine deterministic gameplay."""
    rgon = repentogon_dir.resolve()
    return {
        "game_build_sha256": sha256_file(rgon.parent / "isaac-ng.exe"),
        "repentogon_build_sha256": sha256_file(rgon / "zhlREPENTOGON.dll"),
    }


def anti_desync_checks(profile: dict[str, Any], local: dict[str, Any]) -> dict[str, Any]:
    """Fail closed on every driver of an Isaac online-coop desync.

    Checks: exact load order + order digest, game/REPENTOGON build hashes,
    version equality and profile tool version. Returns a machine-readable
    summary that the runner prints before it starts the game.
    """
    problems: list[str] = []
    warnings: list[str] = []
    checks: list[dict[str, str]] = []

    host_order = load_order_keys(profile)
    local_order = load_order_keys(local)
    host_order_digest = profile.get("load_order_sha256") or load_order_digest(host_order)
    local_order_digest_value = local.get("load_order_sha256") or load_order_digest(local_order)
    if host_order != local_order:
        problems.append(
            "Mod-Ladereihenfolge weicht ab (Host: %s / Client: %s)"
            % (", ".join(host_order) or "-", ", ".join(local_order) or "-")
        )
    if host_order_digest != local_order_digest_value:
        problems.append("Ladereihenfolge-Hash weicht ab")
    checks.append({"name": "load_order", "status": "ok" if host_order == local_order else "mismatch"})

    for label, key in (
        ("Game-Build-Hash", "game_build_sha256"),
        ("REPENTOGON-Build-Hash", "repentogon_build_sha256"),
    ):
        host_hash = profile.get(key)
        local_hash = local.get(key)
        if host_hash and local_hash and host_hash == local_hash:
            status = "ok"
        elif not host_hash and not local_hash:
            # Fixture/old manifests without build artifacts: warn, do not block.
            status = "unavailable"
            warnings.append(f"{label} auf beiden Seiten nicht verfuegbar (keine Build-Datei im Manifest).")
        else:
            status = "mismatch"
            problems.append(f"{label} fehlt oder weicht ab (Host={host_hash}, Client={local_hash})")
        checks.append({"name": key, "status": status})

    for label, key in (("Spielversion", "game_version"), ("REPENTOGON-Version", "repentogon_version")):
        if profile.get(key) != local.get(key):
            problems.append(f"{label} weicht ab (Host={profile.get(key)!r}, Client={local.get(key)!r})")
    if profile.get("tool_version") != TOOL_VERSION:
        problems.append(f"Tool-Version {profile.get('tool_version')!r} != {TOOL_VERSION}")

    result = {
        "status": "ok" if not problems else "blocked",
        "tool_version": TOOL_VERSION,
        "load_order": host_order,
        "load_order_sha256": host_order_digest,
        "checks": checks,
        "problems": problems,
        "warnings": warnings,
    }
    if problems:
        raise ManifestError(
            "Anti-Desync-Pruefung blockiert den Start:\n  - " + "\n  - ".join(problems)
        )
    return result


def build_observer_lua(expected_order: list[str], expected_hashes: dict[str, str]) -> str:
    """Generate the temporary helper mod with embedded anti-desync expectations."""
    order_lua = ", ".join(json.dumps(value, ensure_ascii=False) for value in expected_order)
    hashes_lua = "\n".join(
        "  [%s] = %s," % (json.dumps(key, ensure_ascii=False), json.dumps(value))
        for key, value in sorted(expected_hashes.items())
    )
    return (
        LOBBY_OBSERVER_LUA.replace("@@EXPECTED_ORDER@@", order_lua)
        .replace("@@EXPECTED_HASHES@@", hashes_lua)
        .replace("@@DESYNC_VERSION@@", json.dumps(DESYNC_MONITOR_VERSION))
    )


def stage_savedata(session_root: Path, mod_folders: list[str]) -> dict[str, Any]:
    """Create an isolated, deterministic mod-SaveData tree for the temp session.

    Both players get the same fresh data directory, so no local persistentgamedata
    from an earlier run can desync the co-op session. The runner junctions the
    game's real data folder to this tree for the duration of the session.
    """
    data_root = session_root / "data"
    data_root.mkdir(parents=True, exist_ok=False)
    digests: dict[str, str] = {}
    for folder in mod_folders:
        child = safe_mod_child(data_root, folder)
        child.mkdir()
        digests[folder] = hashlib.sha256(b"").hexdigest()  # empty, identical on both sides
    manifest = {
        "format": SAVEDATA_SESSION_FORMAT,
        "schema_version": 1,
        "savedata_sha256": load_order_digest([f"{k}:{v}" for k, v in sorted(digests.items())]),
        "mods": digests,
    }
    write_json_new(session_root / "savedata-manifest.json", manifest)
    return manifest


def build_manifest(
    mods_dir: Path,
    log_path: Path,
    repentogon_version: str | None = None,
    game_version_override: str | None = None,
    repentogon_dir: Path | None = None,
    allow_empty: bool = False,
    skip_security: bool = False,
) -> dict[str, Any]:
    mods_root = mods_dir.resolve()
    if not mods_root.is_dir():
        raise ManifestError(f"Mods-Ordner nicht gefunden: {mods_dir}")
    folders, detected_game_version = parse_loaded_mods(log_path, allow_empty)
    game_version = game_version_override or detected_game_version
    if not game_version:
        raise ManifestError("Spielversion nicht im Log gefunden; nutze --game-version.")

    rgon_root = repentogon_dir.resolve() if repentogon_dir else mods_root.parent / "Repentogon"
    build_hashes = capture_build_hashes(rgon_root)
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
        if not skip_security:
            security = scan_mod_security(mod_dir)
            if security["status"] == "blocked":
                details = "\n  - ".join(security["findings"][:10])
                raise ManifestError(
                    f"Mod {folder} wurde vor der Manifest-Aufnahme aus Sicherheitsgruenden abgelehnt:\n  - {details}"
                )
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
        "load_order_sha256": load_order_digest([mod_key(mod) for mod in mods]),
        **build_hashes,
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
        "tool_version": TOOL_VERSION,
        "profile_name": profile_name,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "game_version": manifest.get("game_version"),
        "repentogon_version": manifest.get("repentogon_version"),
        "load_order_sha256": manifest.get("load_order_sha256") or load_order_digest(load_order),
        "game_build_sha256": manifest.get("game_build_sha256"),
        "repentogon_build_sha256": manifest.get("repentogon_build_sha256"),
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
    if data.get("tool_version") != TOOL_VERSION:
        raise ManifestError(
            f"Versionskonflikt: Profil v{data.get('tool_version')} passt nicht zu modsync v{TOOL_VERSION}: {path}"
        )
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
            # Python considers True == 1; Lua/JSON do not. Compare JSON types as
            # well as values so a boolean/number mismatch cannot be a false pass.
            elif not same_json_value(current_categories[category][setting_key], expected_value):
                differences.append(f"MCM-Setting unterscheidet sich: {category}::{setting_key}")
    return differences


def same_json_value(left: Any, right: Any) -> bool:
    """Strict recursive comparison of settings; booleans are not numbers."""
    if isinstance(left, bool) or isinstance(right, bool):
        return type(left) is bool and type(right) is bool and left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(same_json_value(left[key], right[key]) for key in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(same_json_value(a, b) for a, b in zip(left, right))
    return left == right


def compatible_json_shape(expected: Any, current: Any) -> bool:
    """Reject replacing a local setting with an incompatible JSON type/shape."""
    if isinstance(expected, bool) or isinstance(current, bool):
        return type(expected) is bool and type(current) is bool
    if isinstance(expected, (int, float)) and isinstance(current, (int, float)):
        return True
    if type(expected) is not type(current):
        return False
    if isinstance(expected, dict):
        return expected.keys() == current.keys() and all(
            compatible_json_shape(expected[key], current[key]) for key in expected
        )
    if isinstance(expected, list):
        return len(expected) == len(current) and all(
            compatible_json_shape(a, b) for a, b in zip(expected, current)
        )
    return True


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
    for category, selected_values in bundle["mcm_categories"].items():
        for setting_key, host_value in selected_values.items():
            if not compatible_json_shape(host_value, current_categories[category][setting_key]):
                raise ManifestError(
                    f"MCM-Setting hat einen inkompatiblen Werttyp oder Aufbau: {category}::{setting_key}"
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


def scan_all_mods(mods_dir: Path, include_defender: bool = False) -> dict[str, Any]:
    """Scant jeden Mod im Ordner und liefert einen maschinenlesbaren Report."""
    root = Path(mods_dir)
    if not root.is_dir():
        raise ManifestError(f"Mods-Ordner nicht gefunden: {mods_dir}")
    mods: dict[str, dict[str, Any]] = {}
    blocked = 0
    for child in sorted(root.iterdir(), key=lambda item: item.name.casefold()):
        if child.name.startswith(".") or child.is_symlink() or not child.is_dir():
            continue
        result = scan_mod_security(child)
        if include_defender and result["status"] == "ok":
            defender = defender_scan(child)
            result["defender"] = defender
            if not defender["clean"]:
                result["status"] = "blocked"
                result["findings"].append("Windows Defender hat eine Bedrohung gemeldet.")
        mods[child.name] = result
        if result["status"] == "blocked":
            blocked += 1
    status = "blocked" if blocked else "ok"
    return {
        "format": SECURITY_REPORT_FORMAT,
        "schema_version": SECURITY_REPORT_SCHEMA_VERSION,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "mods_dir": str(root.resolve()),
        "status": status,
        "summary": {
            "mods": len(mods),
            "clean": len(mods) - blocked,
            "blocked": blocked,
            "findings": sum(len(item["findings"]) for item in mods.values()),
        },
        "mods": mods,
    }


def command_security_scan(args: argparse.Namespace) -> int:
    """Report ueber alle Mods; Exit 2 bei ANY Finding, sonst 0."""
    try:
        report = scan_all_mods(
            Path(args.mods_dir),
            include_defender=bool(getattr(args, "defender", False)),
        )
        if args.output:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(
                json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
            )
    except (ManifestError, OSError, ValueError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    if not args.output:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return 2 if report["status"] == "blocked" else 0
    print(
        f"Sicherheits-Scan: {report['summary']['mods']} Mods, "
        f"{report['summary']['clean']} sauber, {report['summary']['blocked']} blockiert, "
        f"{report['summary']['findings']} Befund(e)."
    )
    for name, result in report["mods"].items():
        if result["status"] == "blocked":
            print(f"BLOCKIERT {name}:", file=sys.stderr)
            for finding in result["findings"]:
                print(f"  - {finding}", file=sys.stderr)
    print(f"JSON-Report: {args.output}")
    return 2 if report["status"] == "blocked" else 0


def command_create(args: argparse.Namespace) -> int:
    try:
        manifest = build_manifest(
            Path(args.mods_dir),
            Path(args.log),
            args.repentogon_version,
            args.game_version,
            Path(args.repentogon_dir) if args.repentogon_dir else None,
            args.allow_empty,
            skip_security=getattr(args, "skip_security", False),
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


def safe_mod_child(mods_root: Path, folder: str) -> Path:
    """Resolve one direct child mod folder without accepting traversal or links."""
    validate_mod_folder_name(folder)
    child = mods_root / folder
    if child.is_symlink():
        raise ManifestError(f"Symbolischer Link als Mod-Ordner wird nicht veraendert: {folder}")
    try:
        child.resolve().relative_to(mods_root.resolve())
    except ValueError as exc:
        raise ManifestError(f"Mod-Ordner liegt ausserhalb des Mods-Verzeichnisses: {folder}") from exc
    return child


def validate_mod_folder_name(folder: str) -> None:
    """Accept only a safe single Windows/portable directory name."""
    if (
        not isinstance(folder, str)
        or not folder
        or folder in {".", ".."}
        or folder.endswith((".", " "))
        or any(ord(char) < 32 or char in '<>:"/\\|?*' for char in folder)
    ):
        raise ManifestError(f"Unsicherer Mod-Ordnername: {folder!r}")
    device_name = folder.split(".", 1)[0].upper()
    if device_name in {"CON", "PRN", "AUX", "NUL"} or re.fullmatch(r"(?:COM|LPT)[1-9]", device_name):
        raise ManifestError(f"Reservierter Windows-Mod-Ordnername: {folder!r}")


def scan_installed_mods(mods_dir: Path) -> tuple[Path, dict[str, dict[str, Any]]]:
    """Find local mod folders and their REPENTOGON disable.it state."""
    try:
        mods_root = mods_dir.resolve(strict=True)
    except OSError as exc:
        raise ManifestError(f"Mods-Ordner nicht gefunden: {mods_dir}: {exc}") from exc
    if not mods_root.is_dir():
        raise ManifestError(f"Mods-Ordner ist kein Verzeichnis: {mods_dir}")

    installed: dict[str, dict[str, Any]] = {}
    try:
        children = sorted(mods_root.iterdir(), key=lambda path: path.name.casefold())
    except OSError as exc:
        raise ManifestError(f"Kann Mods-Ordner nicht lesen: {mods_root}: {exc}") from exc

    for child in children:
        if child.is_symlink() or not child.is_dir():
            continue
        metadata_path = child / "metadata.xml"
        content_path = child / "content"
        if not metadata_path.exists() and not content_path.is_dir():
            continue
        if metadata_path.is_symlink() or content_path.is_symlink():
            raise ManifestError(f"Symbolischer Link in Mod-Metadaten wird nicht verarbeitet: {child.name}")
        metadata = read_metadata(child)
        entry = {
            "folder": child.name,
            "path": child,
            "key": mod_key({"workshop_id": metadata["workshop_id"], "folder": child.name}),
            "name": metadata["name"] or child.name,
            "version": metadata["version"],
            "disabled": False,
            "marker": child / "disable.it",
        }
        marker = entry["marker"]
        if marker.is_symlink():
            raise ManifestError(f"disable.it ist ein symbolischer Link: {child.name}")
        if marker.exists() and not marker.is_file():
            raise ManifestError(f"disable.it ist keine regulaere Datei: {child.name}")
        entry["disabled"] = marker.exists()
        if entry["key"] in installed:
            raise ManifestError(f"Doppelter lokaler Mod-Schluessel: {entry['key']}")
        installed[entry["key"]] = entry
    return mods_root, installed


def profile_apply_plan(
    profile: dict[str, Any], local_manifest: dict[str, Any], mods_dir: Path
) -> tuple[Path, list[dict[str, Any]], list[str]]:
    """Plan an exact host mod set; block all changes on missing/changed mods."""
    expected = profile_to_manifest(profile)
    differences: list[str] = []
    for label, host_value, local_value in (
        ("Spielversion", profile.get("game_version"), local_manifest.get("game_version")),
        ("Repentogon-Version", profile.get("repentogon_version"), local_manifest.get("repentogon_version")),
    ):
        if not host_value or not local_value:
            differences.append(f"{label} fehlt; Kompatibilitaet nicht bestaetigt.")
        elif host_value != local_value:
            differences.append(f"{label} unterschiedlich: Host={host_value!r}, Client={local_value!r}.")

    mods_root, installed = scan_installed_mods(mods_dir)
    host_by_key = {mod_key(mod): mod for mod in expected["mods"]}
    for key, host_mod in host_by_key.items():
        local_mod = installed.get(key)
        label = host_mod.get("name") or host_mod.get("folder") or key
        if local_mod is None:
            differences.append(f"Host-Mod fehlt lokal: {label} ({key}); nichts wurde heruntergeladen.")
            continue
        try:
            digest, _file_count, _total_bytes = digest_mod(local_mod["path"])
        except OSError as exc:
            differences.append(f"Kann Host-Mod nicht pruefen: {label}: {exc}")
            continue
        if digest != host_mod.get("sha256"):
            differences.append(f"Host-Mod weicht lokal ab: {label} ({key}); SHA-256 stimmt nicht.")
        if local_mod.get("version") != host_mod.get("version"):
            differences.append(f"Mod-Version weicht ab: {label} ({key}).")

    plan: list[dict[str, Any]] = []
    for key, local_mod in installed.items():
        should_disable = key not in host_by_key
        plan.append({
            **local_mod,
            "should_disable": should_disable,
            "action": (
                "deaktivieren" if should_disable and not local_mod["disabled"]
                else "aktivieren" if not should_disable and local_mod["disabled"]
                else "unveraendert"
            ),
        })
    return mods_root, plan, differences


def assert_no_mod_symlinks(source: Path) -> None:
    for root, dirs, files in os.walk(source, followlinks=False):
        root_path = Path(root)
        for name in dirs + files:
            if (root_path / name).is_symlink():
                raise ManifestError(f"Mod enthaelt einen symbolischen Link; Temp-Kopie abgelehnt: {root_path / name}")


def find_steamcmd_workshop_root(steamcmd: Path) -> Path:
    return steamcmd.resolve().parent / "steamapps" / "workshop" / "content" / ISAAC_APP_ID


def run_anonymous_workshop_download(steamcmd: Path, workshop_ids: list[str]) -> None:
    """Use SteamCMD's anonymous login only; never read or save Steam credentials."""
    if not workshop_ids:
        return
    steamcmd = steamcmd.resolve(strict=True)
    if not steamcmd.is_file():
        raise ManifestError(f"SteamCMD ist keine Datei: {steamcmd}")
    command = [str(steamcmd), "+login", "anonymous"]
    for workshop_id in sorted(set(workshop_ids)):
        if not workshop_id.isdigit():
            raise ManifestError(f"Ungueltige Workshop-ID; Download abgelehnt: {workshop_id!r}")
        command.extend(("+workshop_download_item", ISAAC_APP_ID, workshop_id, "validate"))
    command.append("+quit")
    try:
        result = subprocess.run(
            command,
            cwd=steamcmd.parent,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=1800,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ManifestError(f"SteamCMD-Workshop-Download fehlgeschlagen: {exc}") from exc
    tail = (result.stdout + "\n" + result.stderr)[-3000:].strip()
    if tail:
        print("SteamCMD (anonyme Anmeldung, nur IDs aus dem Host-Profil):")
        print(tail)
    if result.returncode != 0:
        print(f"WARNUNG: SteamCMD endete mit Exit-Code {result.returncode}; Hash-Pruefung folgt.")


def _validate_profile_source(source: Path, host_mod: dict[str, Any]) -> tuple[str, str | None]:
    if source.is_symlink() or not source.is_dir():
        raise ManifestError(f"Mod-Quelle fehlt oder ist ein Link: {source}")
    metadata_path = source / "metadata.xml"
    if metadata_path.is_symlink():
        raise ManifestError(f"Mod-Metadaten sind ein symbolischer Link: {source}")
    metadata = read_metadata(source)
    source_key = mod_key({"workshop_id": metadata["workshop_id"], "folder": source.name})
    if source_key != mod_key(host_mod):
        raise ManifestError(f"Workshop-ID/Mod-Ordner passt nicht zum Host-Profil: {source}")
    if metadata.get("version") != host_mod.get("version"):
        raise ManifestError(f"Metadaten-Version weicht vom Host-Profil ab: {source}")
    assert_no_mod_symlinks(source)
    digest, _file_count, _total_bytes = digest_mod(source)
    if digest != host_mod.get("sha256"):
        raise ManifestError(f"SHA-256 weicht vom Host-Profil ab: {source}")
    return digest, metadata.get("version")


def _copy_mod_for_session(source: Path, destination: Path) -> None:
    source = source.resolve(strict=True)
    assert_no_mod_symlinks(source)

    def ignored(directory: str, names: list[str]) -> list[str]:
        current = Path(directory)
        ignored_names = []
        for name in names:
            path = current / name
            if path.is_dir() and name.casefold() in IGNORED_DIRS:
                ignored_names.append(name)
            elif path.is_file() and (
                path.suffix.casefold() in IGNORED_SUFFIXES
                or (current == source and name.casefold() == "disable.it")
            ):
                ignored_names.append(name)
        return ignored_names

    shutil.copytree(source, destination, ignore=ignored)


def stage_profile_session(
    profile: dict[str, Any],
    local_manifest: dict[str, Any],
    mods_dir: Path,
    workshop_cache: Path | None,
    steamcmd: Path | None,
    session_root: Path,
) -> tuple[Path, list[dict[str, Any]]]:
    """Copy exact host mods into a fresh temp tree; do not touch the live mods dir."""
    expected = profile_to_manifest(profile)
    anti_desync = anti_desync_checks(profile, local_manifest)

    mods_root, installed = scan_installed_mods(mods_dir)
    temp_root = Path(tempfile.gettempdir()).resolve()
    session_root = session_root.resolve()
    try:
        session_root.relative_to(temp_root)
    except ValueError as exc:
        raise ManifestError(f"Session-Ziel muss unter dem Temp-Ordner liegen: {temp_root}") from exc
    if session_root == temp_root or session_root.exists():
        raise ManifestError(f"Temp-Session-Ziel muss neu und eindeutig sein: {session_root}")

    cache_roots: list[Path] = []
    if workshop_cache is not None:
        cache_roots.append(workshop_cache.resolve())
    if steamcmd is not None:
        cache_roots.append(find_steamcmd_workshop_root(steamcmd))

    source_by_key: dict[str, Path] = {}
    unresolved: list[dict[str, Any]] = []
    blocked: list[str] = []
    for host_mod in expected["mods"]:
        key = mod_key(host_mod)
        try:
            validate_mod_folder_name(host_mod.get("folder"))
        except ManifestError as exc:
            blocked.append(str(exc))
            continue
        candidates: list[Path] = []
        local = installed.get(key)
        if local is not None:
            candidates.append(local["path"])
        workshop_id = host_mod.get("workshop_id")
        if workshop_id:
            candidates.extend(cache_root / str(workshop_id) for cache_root in cache_roots)
        found = None
        for candidate in candidates:
            try:
                _validate_profile_source(candidate, host_mod)
                found = candidate
                break
            except ManifestError:
                continue
        if found is not None:
            source_by_key[key] = found
        else:
            unresolved.append(host_mod)

    download_ids = [str(mod["workshop_id"]) for mod in unresolved if mod.get("workshop_id")]
    if download_ids and steamcmd is not None:
        run_anonymous_workshop_download(steamcmd, download_ids)
        refreshed_root = find_steamcmd_workshop_root(steamcmd)
        for host_mod in unresolved[:]:
            workshop_id = host_mod.get("workshop_id")
            if not workshop_id:
                continue
            candidate = refreshed_root / str(workshop_id)
            try:
                _validate_profile_source(candidate, host_mod)
            except ManifestError:
                continue
            source_by_key[mod_key(host_mod)] = candidate
            unresolved.remove(host_mod)

    if unresolved:
        for host_mod in unresolved:
            label = host_mod.get("name") or host_mod.get("folder")
            if host_mod.get("workshop_id"):
                blocked.append(
                    f"Workshop-Mod nicht verfuegbar/hashfalsch: {label} (ID {host_mod['workshop_id']}). "
                    "SteamCMD mit anonymer Anmeldung konnte ihn nicht verifizieren."
                )
            else:
                blocked.append(f"Lokaler Host-Mod fehlt oder ist veraendert: {label}; kein Workshop-ID-Download moeglich.")
    if blocked:
        raise ManifestError("\n  - " + "\n  - ".join(blocked))

    session_root.parent.mkdir(parents=True, exist_ok=True)
    session_root.mkdir()
    stage_dir = session_root / "mods"
    stage_dir.mkdir()
    staged: list[dict[str, Any]] = []
    try:
        for host_mod in expected["mods"]:
            key = mod_key(host_mod)
            destination = safe_mod_child(stage_dir, str(host_mod["folder"]))
            _copy_mod_for_session(source_by_key[key], destination)
            digest, _file_count, _total_bytes = digest_mod(destination)
            if digest != host_mod["sha256"]:
                raise ManifestError(f"Temp-Kopie nach dem Schreiben nicht hash-identisch: {host_mod.get('name')}")
            staged.append({
                "folder": host_mod["folder"],
                "workshop_id": host_mod.get("workshop_id"),
                "name": host_mod.get("name"),
                "version": host_mod.get("version"),
                "sha256": digest,
            })
        if any(str(mod.get("folder", "")).casefold() == LOBBY_OBSERVER_FOLDER.casefold() for mod in expected["mods"]):
            raise ManifestError(
                f"Host-Profil verwendet den reservierten Temp-Helfer-Ordner {LOBBY_OBSERVER_FOLDER}."
            )
        observer_dir = safe_mod_child(stage_dir, LOBBY_OBSERVER_FOLDER)
        observer_dir.mkdir()
        (observer_dir / "metadata.xml").write_text(LOBBY_OBSERVER_METADATA, encoding="utf-8")
        expected_hashes = {mod_key(mod): mod["sha256"] for mod in expected["mods"]}
        expected_order = [str(mod.get("folder")) for mod in expected["mods"]]
        (observer_dir / "main.lua").write_text(
            build_observer_lua(expected_order, expected_hashes), encoding="utf-8"
        )
        observer_digest, _observer_files, _observer_bytes = digest_mod(observer_dir)
        savedata = stage_savedata(session_root, [str(mod["folder"]) for mod in expected["mods"]])
        staged.append({
            "folder": LOBBY_OBSERVER_FOLDER,
            "workshop_id": None,
            "name": LOBBY_OBSERVER_NAME,
            "version": "0.0.6",
            "sha256": observer_digest,
            "temporary_helper": True,
        })
        session_data = {
            "format": SESSION_FORMAT,
            "schema_version": SESSION_SCHEMA_VERSION,
            "session_id": session_root.name,
            "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "profile_name": profile["profile_name"],
            "host_mod_count": len(expected["mods"]),
            "lobby_exit_observer_count": 1,
            "game_version": profile.get("game_version"),
            "repentogon_version": profile.get("repentogon_version"),
            "anti_desync": anti_desync,
            "savedata_sha256": savedata["savedata_sha256"],
            "mods": staged,
        }
        write_json_new(session_root / "session.json", session_data)
        write_json_new(session_root / "anti-desync.json", anti_desync)
    except Exception:
        shutil.rmtree(session_root, ignore_errors=True)
        raise
    return stage_dir, staged


def marker_bytes(marker: Path) -> bytes | None:
    if marker.is_symlink():
        raise ManifestError(f"disable.it wurde durch einen symbolischen Link ersetzt: {marker}")
    if not marker.exists():
        return None
    if not marker.is_file():
        raise ManifestError(f"disable.it ist keine regulaere Datei: {marker}")
    try:
        return marker.read_bytes()
    except OSError as exc:
        raise ManifestError(f"Kann disable.it nicht lesen: {marker}: {exc}") from exc


def restore_marker(marker: Path, contents: bytes | None) -> None:
    if contents is None:
        marker.unlink(missing_ok=True)
        return
    temporary = marker.with_name(marker.name + ".modsync-tmp")
    if temporary.exists() or temporary.is_symlink():
        raise ManifestError(f"Rollback-Zieldatei existiert bereits: {temporary}")
    try:
        with temporary.open("xb") as stream:
            stream.write(contents)
        os.replace(temporary, marker)
    finally:
        temporary.unlink(missing_ok=True)


def apply_profile_markers(
    plan: list[dict[str, Any]], rollback_path: Path, mods_root: Path
) -> int:
    """Apply enable markers transactionally and create a one-use rollback file."""
    changes = [entry for entry in plan if entry["action"] != "unveraendert"]
    if not changes:
        print("Mod-Aktivierung entspricht bereits dem Host-Profil; nichts zu aendern.")
        return 0
    rollback_path = rollback_path.resolve()
    try:
        rollback_path.relative_to(mods_root.resolve())
    except ValueError:
        pass
    else:
        raise ManifestError("Rollback-Datei muss ausserhalb des Spiel-Mods-Ordners liegen.")

    rollback = {
        "format": PROFILE_ROLLBACK_FORMAT,
        "schema_version": PROFILE_ROLLBACK_SCHEMA_VERSION,
        "created_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "mods_dir": str(mods_root),
        "changes": [],
    }
    for entry in changes:
        marker = entry["marker"]
        original = marker_bytes(marker)
        expected_disabled = entry["should_disable"]
        if (original is not None) != entry["disabled"]:
            raise ManifestError(f"Mod-Status hat sich waehrend der Vorschau geaendert: {entry['folder']}")
        applied = b"" if expected_disabled else None
        rollback["changes"].append({
            "folder": entry["folder"],
            "was_disabled": entry["disabled"],
            "original_marker_base64": base64.b64encode(original).decode("ascii") if original is not None else None,
            "applied_marker_base64": base64.b64encode(applied).decode("ascii") if applied is not None else None,
        })

    write_json_new(rollback_path, rollback)
    changed: list[tuple[Path, bytes | None]] = []
    try:
        for entry, saved in zip(changes, rollback["changes"]):
            marker = entry["marker"]
            original = base64.b64decode(saved["original_marker_base64"]) if saved["original_marker_base64"] is not None else None
            if marker_bytes(marker) != original:
                raise ManifestError(f"Mod-Status hat sich unmittelbar vor dem Schreiben geaendert: {entry['folder']}")
            if entry["should_disable"]:
                with marker.open("xb"):
                    pass
            else:
                marker.unlink()
            changed.append((marker, original))
    except Exception:
        for marker, original in reversed(changed):
            restore_marker(marker, original)
        rollback_path.unlink(missing_ok=True)
        raise
    print(f"Host-Mod-Profil angewendet: {len(changes)} Mod(s) umgeschaltet.")
    print(f"Rueckgaengig-Datei: {rollback_path}")
    print("Es wurden keine Mods heruntergeladen/kopiert und keine Saves/Settings geaendert.")
    return 0


def command_profile_apply(args: argparse.Namespace) -> int:
    try:
        profile = load_profile(Path(args.profile))
        local_manifest = load_manifest(Path(args.local_manifest))
        mods_root, plan, differences = profile_apply_plan(profile, local_manifest, Path(args.mods_dir))
        print(f"Vorschau fuer Host-Profil '{profile['profile_name']}':")
        for entry in plan:
            print(f"  {entry['action']}: {entry['name']} [{entry['folder']}]")
        if differences:
            print("ABBRUCH: Erst die Host-Mods/Versionen angleichen; nichts wurde geaendert:")
            for difference in differences:
                print(f"  - {difference}")
            return 1
        if not args.apply:
            print("Nur Vorschau. Mit --apply anwenden; dabei werden lokale Zusatz-Mods deaktiviert.")
            return 0
        apply_profile_markers(plan, Path(args.rollback_output), mods_root)
    except (ManifestError, OSError, ValueError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    return 0


def command_profile_restore(args: argparse.Namespace) -> int:
    try:
        rollback_path = Path(args.rollback)
        rollback = json.loads(rollback_path.read_text(encoding="utf-8-sig"))
        if not isinstance(rollback, dict) or rollback.get("format") != PROFILE_ROLLBACK_FORMAT:
            raise ManifestError(f"Keine {PROFILE_ROLLBACK_FORMAT}-Datei: {rollback_path}")
        if rollback.get("schema_version") != PROFILE_ROLLBACK_SCHEMA_VERSION:
            raise ManifestError("Nicht unterstuetzte Rollback-Datei-Version.")
        mods_root, installed = scan_installed_mods(Path(args.mods_dir))
        if str(mods_root) != rollback.get("mods_dir"):
            raise ManifestError("Rollback-Datei gehoert zu einem anderen Mods-Ordner.")
        changes = rollback.get("changes")
        if not isinstance(changes, list):
            raise ManifestError("Rollback-Datei enthaelt keine gueltige Aenderungsliste.")

        prepared: list[tuple[Path, bytes | None]] = []
        for change in changes:
            if not isinstance(change, dict) or not isinstance(change.get("folder"), str):
                raise ManifestError("Ungueltiger Eintrag in der Rollback-Datei.")
            folder = change["folder"]
            safe_mod_child(mods_root, folder)
            entry = next((item for item in installed.values() if item["folder"] == folder), None)
            if entry is None:
                raise ManifestError(f"Mod fehlt beim Zuruecksetzen: {folder}")
            applied_encoded = change.get("applied_marker_base64")
            original_encoded = change.get("original_marker_base64")
            applied = base64.b64decode(applied_encoded, validate=True) if applied_encoded is not None else None
            original = base64.b64decode(original_encoded, validate=True) if original_encoded is not None else None
            if marker_bytes(entry["marker"]) != applied:
                raise ManifestError(
                    f"Mod-Status wurde seit dem Anwenden geaendert; Abbruch statt Ueberschreiben: {folder}"
                )
            prepared.append((entry["marker"], original))

        for marker, original in prepared:
            restore_marker(marker, original)
    except (ManifestError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print(f"Mod-Aktivierungszustand aus {rollback_path} wiederhergestellt.")
    print("Die Rollback-Datei bleibt als Nachweis erhalten; sie kann nicht sicher ein zweites Mal angewendet werden.")
    return 0


def command_profile_stage(args: argparse.Namespace) -> int:
    try:
        profile = load_profile(Path(args.profile))
        local_manifest = load_manifest(Path(args.local_manifest))
        workshop_cache = Path(args.workshop_cache) if args.workshop_cache else None
        steamcmd = Path(args.steamcmd) if args.steamcmd else None
        stage_dir, staged = stage_profile_session(
            profile,
            local_manifest,
            Path(args.mods_dir),
            workshop_cache,
            steamcmd,
            Path(args.output),
        )
    except (ManifestError, OSError, ValueError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print(f"Temp-Mod-Set bereit: {stage_dir}")
    print(f"Profil={profile['profile_name']} Host-Mods={len(profile['mod_set'])} Temp-Beobachter=1")
    print("Nur Mods aus diesem Host-Profil wurden in den Temp-Ordner kopiert; Original-Mods blieben unveraendert.")
    print("SteamCMD verwendet ausschliesslich 'anonymous'; es wurden keine Steam-Zugangsdaten gelesen oder gespeichert.")
    return 0


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


def command_lobby_log_scan(args: argparse.Namespace) -> int:
    """Scan a captured log for diagnostic hints, never as authorization."""
    tracker = LobbyLogTracker()
    try:
        with Path(args.log).open("rb") as stream:
            while chunk := stream.read(65536):
                for kind, lobby in tracker.feed(chunk):
                    print(f"{kind}: {lobby if lobby is not None else 'unbekannt'}")
    except (OSError, ManifestError) as exc:
        print(f"FEHLER: {exc}", file=sys.stderr)
        return 2
    print("Nur Log-Hinweise; Lobby-ID und Teilnehmer muessen separat ueber Steam verifiziert werden.")
    return 0


def command_anti_desync_check(args: argparse.Namespace) -> int:
    """Pre-start prevention gate: print a compact report and fail closed."""
    try:
        profile = load_profile(Path(args.profile))
        local = load_manifest(Path(args.local_manifest))
        report = anti_desync_checks(profile, local)
    except (ManifestError, OSError, ValueError) as exc:
        print(f"ANTI-DESYNC BLOCKIERT: {exc}", file=sys.stderr)
        return 2
    print("ANTI-DESYNC OK: Ladereihenfolge, Build-Hashes und Versionen stimmen ueberein.")
    for check in report["checks"]:
        print(f"  - {check['name']}: {check['status']}")
    print(f"  - Mods: {len(report['load_order'])} | Reihenfolge-Hash: {report['load_order_sha256'][:16]}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Isaac-Mod-Manifeste und Saves-freie Mod-Profile erstellen und pruefen."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    anti_desync = subparsers.add_parser(
        "anti-desync-check", help="Anti-Desync-Gate vor dem Spielstart (Reihenfolge, Build-Hashes, Versionen)"
    )
    anti_desync.add_argument("--profile", required=True, help="vertrautes Host-Mod-Profil JSON")
    anti_desync.add_argument("--local-manifest", required=True, help="aktuelles lokales Mod-Manifest")
    anti_desync.set_defaults(func=command_anti_desync_check)
    lobby_log = subparsers.add_parser("lobby-log-scan", help="aufgezeichnetes Spiel-Log lesend auf Lobby-Hinweise pruefen")
    lobby_log.add_argument("--log", required=True, help="aufgezeichnetes Spiel-Log (kein Steam-Zugriff)")
    lobby_log.set_defaults(func=command_lobby_log_scan)
    security = subparsers.add_parser(
        "security-scan", help="alle Mods eines Ordners auf gefaehrliche Dateien und Lua-Malware pruefen"
    )
    security.add_argument("--mods-dir", required=True, help="Isaac-Mods-Ordner")
    security.add_argument("--output", help="JSON-Report-Pfad (ohne Angabe: Ausgabe auf stdout)")
    security.add_argument(
        "--defender", action="store_true",
        help="optionaler Windows-Defender-Einzelscan (fail-open, nie startblockierend)",
    )
    security.set_defaults(func=command_security_scan)
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
    create.add_argument("--allow-empty", action="store_true", help="auch ein Manifest ohne geladene Mods fuer lokale Versionspruefung schreiben")
    create.add_argument(
        "--skip-security", action="store_true",
        help="NUR DIAGNOSE: Sicherheitspruefung vor der Manifest-Aufnahme ueberspringen",
    )
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

    profile_apply = profile_subparsers.add_parser(
        "apply", help="Host-Mods lokal aktivieren und Extras reversibel deaktivieren"
    )
    profile_apply.add_argument("--profile", required=True, help="Host-Mod-Profil JSON")
    profile_apply.add_argument("--local-manifest", required=True, help="lokales Manifest fuer Spiel-/REPENTOGON-Version")
    profile_apply.add_argument("--mods-dir", required=True, help="lokaler Isaac-Mods-Ordner")
    profile_apply.add_argument("--rollback-output", required=True, help="neue Rollback-JSON-Datei ausserhalb des Mods-Ordners")
    profile_apply.add_argument("--apply", action="store_true", help="Vorschau anwenden; ohne Flag wird nichts geaendert")
    profile_apply.set_defaults(func=command_profile_apply)

    profile_restore = profile_subparsers.add_parser(
        "restore", help="vorherige lokale Mod-Aktivierung aus einer Rollback-Datei wiederherstellen"
    )
    profile_restore.add_argument("--rollback", required=True, help="Rollback-JSON aus profile apply")
    profile_restore.add_argument("--mods-dir", required=True, help="derselbe lokale Isaac-Mods-Ordner")
    profile_restore.set_defaults(func=command_profile_restore)

    profile_stage = profile_subparsers.add_parser(
        "stage", help="Host-Mods hash-geprueft in einen temporaeren Session-Ordner kopieren"
    )
    profile_stage.add_argument("--profile", required=True, help="vertrautes Host-Mod-Profil JSON")
    profile_stage.add_argument("--local-manifest", required=True, help="lokales Manifest fuer Spiel-/REPENTOGON-Version")
    profile_stage.add_argument("--mods-dir", required=True, help="lokaler Isaac-Mods-Ordner")
    profile_stage.add_argument("--output", required=True, help="neuer Session-Ordner unter TEMP")
    profile_stage.add_argument("--workshop-cache", help="optionaler Steam Workshop Cache fuer App 250900")
    profile_stage.add_argument("--steamcmd", help="SteamCMD-Dateipfad; nur anonyme Workshop-Downloads")
    profile_stage.set_defaults(func=command_profile_stage)

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
