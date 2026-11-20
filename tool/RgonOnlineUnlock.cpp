// ---------------------------------------------------------------------------
//  Repentogon Online Unlock v0.0.2
//
//  Kleines eigenstaendiges Windows-Tool (kein .NET, keine Installation):
//  wendet den experimentellen Online-Patch fuer REPENTOGON an.
//
//  Es patcht die vorhandenen Dateien direkt (kein Austausch, alles reversibel
//  mit Backup):
//    1) Repentogon\isaac-ng.exe
//       Coop-Patch aus Isaac-Online-Modded (xADDBx): die Mod-Bann-Pruefung
//       der Engine wird neutralisiert.
//    2) Repentogon\zhlREPENTOGON.dll  (drei Byte-Patches in der 1.1.3-Datei)
//       a) MenuManager::Update setzt die Menue-ID nur noch fuer Daily Run (4)
//          zurueck, statt fuer 4/19/17/18/21.
//       b) ASMPatchOnlineSelection wird mit RET uebersprungen, damit der
//          ONLINE-Eintrag nicht auf Daily Run gezwungen wird.
//       c) ModManager::ListMods: _modBanStatus wird 0 statt 3.
//
//  Akzeptiert werden ausschliesslich die exakten SHA-256 der geprueften
//  REPENTOGON-1.1.3-Dateien; alles andere wird unveraendert abgelehnt.
//
//  Build: tools\build-gui.ps1  (MSVC, statische CRT -> einzelne EXE)
// ---------------------------------------------------------------------------

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <bcrypt.h>
#include <commdlg.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <cstdarg>
#include <cstdio>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "comdlg32.lib")
#pragma comment(lib, "bcrypt.lib")
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

// --- Steuerelement-IDs ------------------------------------------------------
enum {
    ID_PATH = 1001, ID_BROWSE, ID_CHECK, ID_APPLY, ID_REVERT, ID_PLAY,
    ID_LOG, ID_ST_EXE, ID_ST_DLL, ID_HINT, ID_HEAD
};

static HWND g_hPath = nullptr, g_hLog = nullptr;
static HWND g_hStExe = nullptr, g_hStDll = nullptr;
static HWND g_hBrowse = nullptr, g_hCheck = nullptr;
static HWND g_hApply = nullptr, g_hRevert = nullptr, g_hPlay = nullptr;
static HWND g_hHint = nullptr, g_hHead = nullptr;

static HFONT g_font = nullptr, g_fontBold = nullptr, g_fontMono = nullptr;
static HBRUSH g_bg = nullptr;

static std::wstring gInstall;      // ...\The Binding of Isaac Rebirth
static int g_exeState = -1;        // 0 = original, 1 = gepatcht, 2 = unbekannt
static int g_dllState = -1;        // 0 = patch fehlt, 1 = vollständig gepatcht, 2 = unbekannt
static bool g_cli = false;         // --check/--apply/--revert ohne Fenster
static FILE* g_cliLog = nullptr;   // CLI-Protokoll: Patch-cli.log neben der EXE

// --- Byte-Pattern -----------------------------------------------------------
static const unsigned char kCoopOrig[] = {
    0x83,0xE8,0x02,0x74,0x2A,0x83,0xE8,0x01,0x74,0x1E,0x83,0xE8,
    0x01,0x74,0x12,0x32,0xC0,0x8B,0x4D,0xF4,0x64,0x89,0x0D,0x00,
    0x00,0x00,0x00
};
static const unsigned char kCoopPatched[] = {
    0x83,0xE8,0x02,0x90,0x90,0x83,0xE8,0x01,0x90,0x90,0x83,0xE8,
    0x01,0x90,0x90,0x32,0xC0,0x8B,0x4D,0xF4,0x64,0x89,0x0D,0x00,
    0x00,0x00,0x00
};
static const size_t kCoopLen = sizeof(kCoopOrig);

// zhlREPENTOGON.dll: the menu fix is patched into the existing, exact RE_PENTOGON
// 1.1.3 file instead of shipping a rebuilt DLL. Only these hashes are accepted.
static const wchar_t kUpstreamDllSha256[] = L"5579B2F0CCB83C695F96AF4E1C657F1F3A4E5B24441B4DAC81D9289043CB3CC8"; // untouched 1.1.3
static const wchar_t kV001DllSha256[]     = L"16BB35D3478B9ADAEA307A451FB7591DD266F4B2176094EA563683C9F79F64F9"; // v0.0.1 ban patch
static const wchar_t kFullDllSha256[]     = L"019EBB3CD5532C91CA6D1AE85AA26451C1A54FB4236C83CD48E302C098C031FB"; // ban + menu fix

// MenuManager::Update resets the menu ID. Original: 4, 19, 17, 18, 21.
// Patched form keeps the comparison only for 4, so ONLINE and the lobby menus stay open.
static const unsigned char kMenuResetOrig[] = {
    0x83,0xF8,0x04, 0x74,0x14,
    0x83,0xF8,0x13, 0x74,0x0F,
    0x83,0xF8,0x11, 0x74,0x0A,
    0x83,0xF8,0x12, 0x74,0x05,
    0x83,0xF8,0x15, 0x75,0x07,
    0xC7,0x42,0x40,0x01,0x00,0x00,0x00
};
static const size_t kMenuResetLen = sizeof(kMenuResetOrig);
static const size_t kMenuResetImmOffsets[] = { 7, 12, 17, 22 };

// RVA of ASMPatchOnlineSelection in the tested 1.1.3 DLL. It forces the ONLINE
// cursor onto "Daily Run" and blocks up/down. Patching its first byte to RET
// leaves the option selectable.
static const unsigned long kOnlineSelectionRva = 0x1DBDC0;

// --- Datei-Helfer -----------------------------------------------------------
static bool ReadBytes(const std::wstring& path, std::vector<unsigned char>& out) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(h, &size)) { CloseHandle(h); return false; }
    out.resize((size_t)size.QuadPart);
    DWORD got = 0;
    bool ok = ReadFile(h, out.data(), (DWORD)out.size(), &got, nullptr) && got == out.size();
    CloseHandle(h);
    return ok;
}

static bool WriteBytes(const std::wstring& path, const std::vector<unsigned char>& data) {
    DWORD attr = GetFileAttributesW(path.c_str());
    if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_READONLY))
        SetFileAttributesW(path.c_str(), attr & ~FILE_ATTRIBUTE_READONLY);

    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    bool ok = WriteFile(h, data.data(), (DWORD)data.size(), &written, nullptr)
              && written == data.size();
    CloseHandle(h);
    return ok;
}

static size_t CountPattern(const std::vector<unsigned char>& hay,
                           const unsigned char* pat, size_t len) {
    size_t count = 0;
    if (hay.size() < len) return 0;
    for (size_t i = 0; i + len <= hay.size(); ++i) {
        if (memcmp(hay.data() + i, pat, len) == 0) { ++count; i += len - 1; }
    }
    return count;
}

static long FindPattern(const std::vector<unsigned char>& hay,
                        const unsigned char* pat, size_t len) {
    if (hay.size() < len) return -1;
    for (size_t i = 0; i + len <= hay.size(); ++i) {
        if (memcmp(hay.data() + i, pat, len) == 0) return (long)i;
    }
    return -1;
}

// Hook-Body von ModManager::ListMods:
//   56 8B F1 E8 <rel32> C7 86 5C 02 02 00 <imm32> 5E C3
// Rueckgabe: Offset der 4 Byte grossen Zahl (imm32) oder -1.
static long FindBanStore(const std::vector<unsigned char>& d) {
    for (size_t i = 0; i + 20 <= d.size(); ++i) {
        if (d[i] != 0x56 || d[i+1] != 0x8B || d[i+2] != 0xF1 || d[i+3] != 0xE8) continue;
        if (d[i+8] != 0xC7 || d[i+9] != 0x86) continue;
        if (d[i+10] != 0x5C || d[i+11] != 0x02 || d[i+12] != 0x02 || d[i+13] != 0x00) continue;
        if (d[i+18] != 0x5E || d[i+19] != 0xC3) continue;
        return (long)(i + 14);
    }
    return -1;
}

static unsigned long ReadU32(const unsigned char* p) {
    unsigned long v = 0;
    memcpy(&v, p, 4);
    return v;
}

static unsigned short ReadU16(const unsigned char* p) {
    unsigned short v = 0;
    memcpy(&v, p, 2);
    return v;
}

// RVA -> Datei-Offset anhand der PE-Sektionskopfdaten.
static long RvaToFileOffset(const std::vector<unsigned char>& d, unsigned long rva) {
    if (d.size() < 0x40 || d[0] != 'M' || d[1] != 'Z') return -1;
    const unsigned long peOff = ReadU32(d.data() + 0x3C);
    if (peOff + 0x18 > d.size()) return -1;
    if (memcmp(d.data() + peOff, "PE\0\0", 4) != 0) return -1;
    const unsigned short sections = ReadU16(d.data() + peOff + 6);
    const unsigned short optSize = ReadU16(d.data() + peOff + 20);
    size_t sec = (size_t)peOff + 24 + optSize;
    for (unsigned i = 0; i < sections; ++i, sec += 40) {
        if (sec + 40 > d.size()) return -1;
        const unsigned long vsize = ReadU32(d.data() + sec + 8);
        const unsigned long vaddr = ReadU32(d.data() + sec + 12);
        const unsigned long rawSize = ReadU32(d.data() + sec + 16);
        const unsigned long rawPtr = ReadU32(d.data() + sec + 20);
        if (rva < vaddr || rva >= vaddr + vsize) continue;
        const unsigned long delta = rva - vaddr;
        if (delta >= rawSize) return -1;
        return (long)((size_t)rawPtr + delta);
    }
    return -1;
}

// Menue-Reset-Filter: nur noch Menue-ID 4 (Daily Run) wird zurueckgesetzt.
static bool PatchMenuReset(std::vector<unsigned char>& d, long& pos) {
    const long found = FindPattern(d, kMenuResetOrig, kMenuResetLen);
    if (found < 0) return false;
    pos = found;
    for (size_t i = 0; i < sizeof(kMenuResetImmOffsets) / sizeof(kMenuResetImmOffsets[0]); ++i) {
        const size_t at = (size_t)found + kMenuResetImmOffsets[i];
        const unsigned char want = kMenuResetOrig[kMenuResetImmOffsets[i]];
        if (d[at] != want) return false;
        d[at] = 4;
    }
    return true;
}

// ASMPatchOnlineSelection: erster Befehl (55 8B EC) wird zu RET.
static bool PatchOnlineSelection(std::vector<unsigned char>& d, long& pos) {
    const long at = RvaToFileOffset(d, kOnlineSelectionRva);
    if (at < 0 || (size_t)at + 3 > d.size()) return false;
    if (d[at] != 0x55 || d[at+1] != 0x8B || d[at+2] != 0xEC) return false;
    pos = at;
    d[at] = 0xC3;
    return true;
}

// Mod-Bann-Status 3 -> 0 (bei bereits 0 unveraendert).
static bool PatchBanStore(std::vector<unsigned char>& d, long& pos) {
    const long at = FindBanStore(d);
    if (at < 0) return false;
    pos = at;
    d[at] = d[at+1] = d[at+2] = d[at+3] = 0;
    return true;
}

static bool Sha256Bytes(const std::vector<unsigned char>& data, std::wstring& result) {
    if (data.size() > 0xFFFFFFFFu) return false;
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    DWORD objectLength = 0, hashLength = 0, bytesWritten = 0;
    bool ok = false;

    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return false;
    if (BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&objectLength,
                          sizeof(objectLength), &bytesWritten, 0) != 0) goto cleanup;
    if (BCryptGetProperty(algorithm, BCRYPT_HASH_LENGTH, (PUCHAR)&hashLength,
                          sizeof(hashLength), &bytesWritten, 0) != 0) goto cleanup;

    {
        std::vector<UCHAR> object(objectLength);
        std::vector<UCHAR> digest(hashLength);
        if (BCryptCreateHash(algorithm, &hash, object.data(), objectLength, nullptr, 0, 0) != 0) goto cleanup;
        if (BCryptHashData(hash, (PUCHAR)data.data(), (ULONG)data.size(), 0) != 0) goto cleanup;
        if (BCryptFinishHash(hash, digest.data(), hashLength, 0) != 0) goto cleanup;

        wchar_t hex[65] = L"";
        for (DWORD i = 0; i < hashLength; ++i) {
            swprintf_s(hex + i * 2, 3, L"%02X", digest[i]);
        }
        result = hex;
        ok = true;
    }

cleanup:
    if (hash) BCryptDestroyHash(hash);
    if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

static bool IsUpstreamDllHash(const std::wstring& hash) {
    return _wcsicmp(hash.c_str(), kUpstreamDllSha256) == 0;
}

static bool IsV001DllHash(const std::wstring& hash) {
    return _wcsicmp(hash.c_str(), kV001DllSha256) == 0;
}

static bool IsFullDllHash(const std::wstring& hash) {
    return _wcsicmp(hash.c_str(), kFullDllSha256) == 0;
}

// Jede Datei, aus der ein geprueftes Backup stammen darf.
static bool IsKnownDllHash(const std::wstring& hash) {
    return IsUpstreamDllHash(hash) || IsV001DllHash(hash) || IsFullDllHash(hash);
}

// --- Pfade ------------------------------------------------------------------
static std::wstring ExeDir() {
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    std::wstring p(buf);
    size_t slash = p.find_last_of(L"\\/");
    return slash == std::wstring::npos ? p : p.substr(0, slash);
}

static std::wstring BackupDir() { return ExeDir() + L"\\backup"; }

static std::wstring Join(const std::wstring& a, const wchar_t* b) {
    std::wstring r = a;
    if (!r.empty() && r.back() != L'\\') r += L'\\';
    r += b;
    return r;
}

static bool FileExists(const std::wstring& p) {
    DWORD a = GetFileAttributesW(p.c_str());
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static bool IsValidInstall(const std::wstring& dir) {
    return FileExists(Join(Join(dir, L"Repentogon"), L"isaac-ng.exe"))
        && FileExists(Join(Join(dir, L"Repentogon"), L"zhlREPENTOGON.dll"));
}

static bool GameRunning() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    bool found = false;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, L"isaac-ng.exe") == 0 ||
                _wcsicmp(pe.szExeFile, L"REPENTOGONLauncher.exe") == 0) { found = true; break; }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return found;
}

// --- Steam-Installation suchen ---------------------------------------------
static std::wstring ReadRegString(HKEY root, const wchar_t* sub, const wchar_t* name) {
    HKEY hk;
    if (RegOpenKeyExW(root, sub, 0, KEY_READ, &hk) != ERROR_SUCCESS) return L"";
    wchar_t buf[1024];
    DWORD type = 0, size = sizeof(buf);
    std::wstring out;
    if (RegQueryValueExW(hk, name, nullptr, &type, (LPBYTE)buf, &size) == ERROR_SUCCESS
        && (type == REG_SZ || type == REG_EXPAND_SZ)) {
        buf[(size / sizeof(wchar_t)) - 1] = 0;
        out = buf;
    }
    RegCloseKey(hk);
    return out;
}

static std::vector<std::wstring> SteamLibraries() {
    std::vector<std::wstring> libs;
    std::wstring steam = ReadRegString(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", L"SteamPath");
    if (steam.empty())
        steam = ReadRegString(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WOW6432Node\\Valve\\Steam", L"InstallPath");
    if (!steam.empty()) {
        for (auto& c : steam) if (c == L'/') c = L'\\';
        libs.push_back(steam);

        // libraryfolders.vdf naiv nach "path" durchsuchen
        std::vector<unsigned char> raw;
        std::wstring vdf = Join(Join(steam, L"steamapps"), L"libraryfolders.vdf");
        if (ReadBytes(vdf, raw)) {
            std::string s(raw.begin(), raw.end());
            size_t pos = 0;
            while ((pos = s.find("\"path\"", pos)) != std::string::npos) {
                size_t q1 = s.find('"', pos + 6);
                if (q1 == std::string::npos) break;
                size_t q2 = s.find('"', q1 + 1);
                if (q2 == std::string::npos) break;
                std::string val = s.substr(q1 + 1, q2 - q1 - 1);
                std::wstring w(val.begin(), val.end());
                for (auto& c : w) if (c == L'/') c = L'\\';
                libs.push_back(w);
                pos = q2 + 1;
            }
        }
    }
    return libs;
}

static std::wstring DetectInstall() {
    const wchar_t* gameRel = L"steamapps\\common\\The Binding of Isaac Rebirth";
    for (auto& lib : SteamLibraries()) {
        std::wstring cand = Join(lib, gameRel);
        if (IsValidInstall(cand)) return cand;
    }
    const wchar_t* fallback[] = {
        L"C:\\Program Files (x86)\\Steam\\steamapps\\common\\The Binding of Isaac Rebirth"
    };
    for (auto f : fallback) {
        if (IsValidInstall(f)) return f;
    }
    return L"";
}

// --- Log / Status -----------------------------------------------------------
static void Log(const wchar_t* fmt, ...) {
    wchar_t buf[4096];
    va_list ap;
    va_start(ap, fmt);
    _vsnwprintf_s(buf, _TRUNCATE, fmt, ap);
    va_end(ap);

    if (!g_hLog) {
        if (g_cliLog) {
            fwprintf(g_cliLog, L"%s\n", buf);
            fflush(g_cliLog);
        }
        return;
    }

    std::wstring line = buf;
    line += L"\r\n";
    int len = GetWindowTextLengthW(g_hLog);
    SendMessageW(g_hLog, EM_SETSEL, (WPARAM)len, (LPARAM)len);
    SendMessageW(g_hLog, EM_REPLACESEL, FALSE, (LPARAM)line.c_str());
}

// Meldungen: im Fenster als Dialog, in der CLI nur ins Protokoll.
static void Report(const wchar_t* text, const wchar_t* title, UINT flags) {
    if (g_cli) {
        if (g_cliLog) {
            fwprintf(g_cliLog, L"%s: %s\n", title, text);
            fflush(g_cliLog);
        }
        return;
    }
    MessageBoxW(nullptr, text, title, flags);
}

static bool g_backupExe = false, g_backupDll = false;

static void UpdateButtons() {
    bool valid = IsValidInstall(gInstall);
    EnableWindow(g_hApply, valid);
    EnableWindow(g_hCheck, valid);
    g_backupExe = FileExists(Join(BackupDir(), L"isaac-ng.exe"));
    g_backupDll = FileExists(Join(BackupDir(), L"zhlREPENTOGON.dll"));
    EnableWindow(g_hRevert, g_backupExe || g_backupDll);
}

static void RefreshStatus(bool verbose) {
    g_exeState = -1;
    g_dllState = -1;

    if (!IsValidInstall(gInstall)) {
        SetWindowTextW(g_hStExe, L"EXE:  Installation nicht gefunden");
        SetWindowTextW(g_hStDll, L"DLL:  Installation nicht gefunden");
        UpdateButtons();
        return;
    }

    const std::wstring exe = Join(Join(gInstall, L"Repentogon"), L"isaac-ng.exe");
    const std::wstring dll = Join(Join(gInstall, L"Repentogon"), L"zhlREPENTOGON.dll");

    std::vector<unsigned char> exeBytes, dllBytes;
    if (!ReadBytes(exe, exeBytes)) { SetWindowTextW(g_hStExe, L"EXE:  nicht lesbar"); }
    else {
        size_t orig = CountPattern(exeBytes, kCoopOrig, kCoopLen);
        size_t pat  = CountPattern(exeBytes, kCoopPatched, kCoopLen);
        if (pat == 1 && orig == 0) {
            g_exeState = 1;
            SetWindowTextW(g_hStExe, L"EXE:  gepatcht  \x2714");
            if (verbose) Log(L"EXE  : gepatcht (Coop-Patch aktiv).");
        } else if (orig == 1 && pat == 0) {
            g_exeState = 0;
            SetWindowTextW(g_hStExe, L"EXE:  original (nicht gepatcht)");
        } else {
            g_exeState = 2;
            SetWindowTextW(g_hStExe, L"EXE:  unbekannte Version");
            if (verbose) Log(L"EXE  : Muster passt nicht (orig=%zu, patched=%zu).", orig, pat);
        }
    }

    if (!ReadBytes(dll, dllBytes)) { SetWindowTextW(g_hStDll, L"DLL:  nicht lesbar"); }
    else {
        std::wstring dllHash;
        if (!Sha256Bytes(dllBytes, dllHash)) {
            g_dllState = 2;
            SetWindowTextW(g_hStDll, L"DLL:  Hash-PrÃ¼fung fehlgeschlagen");
        } else if (IsFullDllHash(dllHash)) {
            g_dllState = 1;
            SetWindowTextW(g_hStDll, L"DLL:  Online-MenÃ¼-Fix + Mod-Bann-Fix aktiv  \x2714");
            if (verbose) Log(L"DLL  : MenÃ¼-Fix aktiv (SHA-256 geprÃ¼ft).");
        } else if (IsUpstreamDllHash(dllHash)) {
            g_dllState = 0;
            SetWindowTextW(g_hStDll, L"DLL:  REPENTOGON 1.1.3 original; Patch fehlt");
            if (verbose) Log(L"DLL  : unverÃ¤nderte REPENTOGON 1.1.3; MenÃ¼-Fix fehlt.");
        } else if (IsV001DllHash(dllHash)) {
            g_dllState = 0;
            SetWindowTextW(g_hStDll, L"DLL:  v0.0.1 Ban-Fix; MenÃ¼-Fix fehlt");
            if (verbose) Log(L"DLL  : alter Mod-Bann-Fix erkannt; MenÃ¼-Fix fehlt.");
        } else {
            g_dllState = 2;
            SetWindowTextW(g_hStDll, L"DLL:  nicht unterstÃ¼tzte REPENTOGON-Datei");
            if (verbose) Log(L"DLL  : SHA-256 unbekannt (%s); nichts Ã¤ndern.", dllHash.c_str());
        }
    }

    UpdateButtons();
    InvalidateRect(g_hStExe, nullptr, TRUE);
    InvalidateRect(g_hStDll, nullptr, TRUE);
}

// --- Aktionen ---------------------------------------------------------------
static bool DoApply() {
    if (!IsValidInstall(gInstall)) { Report(L"Keine gÃ¼ltige REPENTOGON-Installation gewÃ¤hlt.", L"Fehler", MB_ICONERROR); return false; }
    if (GameRunning()) { Report(L"Spiel oder Launcher lÃ¤uft noch. Bitte schlieÃŸen und erneut versuchen.", L"Spiel lÃ¤uft", MB_ICONWARNING); return false; }

    const std::wstring exe = Join(Join(gInstall, L"Repentogon"), L"isaac-ng.exe");
    const std::wstring dll = Join(Join(gInstall, L"Repentogon"), L"zhlREPENTOGON.dll");
    const std::wstring backupExe = Join(BackupDir(), L"isaac-ng.exe");
    const std::wstring backupDll = Join(BackupDir(), L"zhlREPENTOGON.dll");
    std::vector<unsigned char> exeBytes, dllBytes;

    // Fail closed on every input before writing either target file.
    if (!ReadBytes(exe, exeBytes)) { Log(L"FEHLER: %s nicht lesbar.", exe.c_str()); return false; }
    const size_t orig = CountPattern(exeBytes, kCoopOrig, kCoopLen);
    const size_t patched = CountPattern(exeBytes, kCoopPatched, kCoopLen);
    const bool exeNeedsPatch = orig == 1 && patched == 0;
    const bool exeAlreadyPatched = patched == 1 && orig == 0;
    if (!exeNeedsPatch && !exeAlreadyPatched) {
        Log(L"FEHLER: EXE-Muster passt nicht (orig=%zu, patched=%zu).", orig, patched);
        Report(L"Unbekannte isaac-ng.exe-Version. Es wurde nichts geÃ¤ndert.", L"Nicht unterstÃ¼tzt", MB_ICONERROR);
        return false;
    }

    if (!ReadBytes(dll, dllBytes)) { Log(L"FEHLER: %s nicht lesbar.", dll.c_str()); return false; }
    std::wstring dllHash;
    if (!Sha256Bytes(dllBytes, dllHash)) { Log(L"FEHLER: DLL-SHA-256 konnte nicht berechnet werden."); return false; }
    const bool dllAlreadyPatched = IsFullDllHash(dllHash);
    if (!dllAlreadyPatched && !IsUpstreamDllHash(dllHash) && !IsV001DllHash(dllHash)) {
        Log(L"FEHLER: Nicht unterstÃ¼tzte REPENTOGON-DLL (SHA-256 %s).", dllHash.c_str());
        Report(L"Diese zhlREPENTOGON.dll gehÃ¶rt nicht zum geprÃ¼ften REPENTOGON-1.1.3-Build. Es wurde nichts geÃ¤ndert.", L"Nicht unterstÃ¼tzt", MB_ICONERROR);
        return false;
    }

    // Patch-Ergebnis im Speicher bilden und gegen den geprÃ¼ften Hash abgleichen.
    std::vector<unsigned char> patchedDll = dllBytes;
    long menuPos = -1, onlinePos = -1, banPos = -1;
    if (!dllAlreadyPatched) {
        if (!PatchMenuReset(patchedDll, menuPos)) {
            Log(L"FEHLER: MenÃ¼-Reset-Filter (4/19/17/18/21) nicht gefunden.");
            Report(L"Der erwartete MenÃ¼-Filter in zhlREPENTOGON.dll fehlt. Es wurde nichts geÃ¤ndert.", L"Nicht unterstÃ¼tzt", MB_ICONERROR);
            return false;
        }
        if (!PatchOnlineSelection(patchedDll, onlinePos)) {
            Log(L"FEHLER: ASMPatchOnlineSelection bei RVA 0x%lX nicht gefunden.", kOnlineSelectionRva);
            Report(L"Die erwartete Online-Auswahl in zhlREPENTOGON.dll fehlt. Es wurde nichts geÃ¤ndert.", L"Nicht unterstÃ¼tzt", MB_ICONERROR);
            return false;
        }
        if (!PatchBanStore(patchedDll, banPos)) {
            Log(L"FEHLER: ModManager::ListMods-Signatur fehlt.");
            Report(L"Das erwartete REPENTOGON-DLL-Muster fehlt. Es wurde nichts geÃ¤ndert.", L"Nicht unterstÃ¼tzt", MB_ICONERROR);
            return false;
        }
        std::wstring resultHash;
        if (!Sha256Bytes(patchedDll, resultHash) || !IsFullDllHash(resultHash)) {
            Log(L"FEHLER: Patch-Ergebnis hat unerwarteten SHA-256 (%s).", resultHash.c_str());
            Report(L"Das Patch-Ergebnis entspricht nicht der geprÃ¼ften Datei. Es wurde nichts geÃ¤ndert.", L"Nicht unterstÃ¼tzt", MB_ICONERROR);
            return false;
        }
    }

    if (!CreateDirectoryW(BackupDir().c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) {
        Log(L"FEHLER: Backup-Ordner konnte nicht erstellt werden.");
        Report(L"Backup-Ordner konnte nicht erstellt werden. Es wurde nichts geÃ¤ndert.", L"Backup-Fehler", MB_ICONERROR);
        return false;
    }
    if (FileExists(backupExe)) {
        std::vector<unsigned char> backupBytes;
        if (!ReadBytes(backupExe, backupBytes)
            || (CountPattern(backupBytes, kCoopOrig, kCoopLen) != 1 && CountPattern(backupBytes, kCoopPatched, kCoopLen) != 1)) {
            Log(L"FEHLER: Vorhandenes EXE-Backup passt nicht zur unterstÃ¼tzten Version.");
            Report(L"Das vorhandene EXE-Backup wird nicht Ã¼berschrieben; Version nicht erkannt.", L"Backup-Konflikt", MB_ICONERROR);
            return false;
        }
    }
    if (FileExists(backupDll)) {
        std::vector<unsigned char> backupBytes;
        std::wstring backupHash;
        if (!ReadBytes(backupDll, backupBytes) || !Sha256Bytes(backupBytes, backupHash)
            || !IsKnownDllHash(backupHash)) {
            Log(L"FEHLER: Vorhandenes DLL-Backup ist keine geprÃ¼fte REPENTOGON-1.1.3-Datei.");
            Report(L"Das vorhandene DLL-Backup wird nicht Ã¼berschrieben; Version nicht erkannt.", L"Backup-Konflikt", MB_ICONERROR);
            return false;
        }
    }
    bool createdBackupExe = false;
    if (!FileExists(backupExe)) {
        if (!CopyFileW(exe.c_str(), backupExe.c_str(), TRUE)) {
            Log(L"FEHLER: EXE-Backup konnte nicht erstellt werden (Win32 %lu).", GetLastError());
            Report(L"EXE-Backup konnte nicht erstellt werden. Es wurde nichts geÃ¤ndert.", L"Backup-Fehler", MB_ICONERROR);
            return false;
        }
        createdBackupExe = true;
    }
    if (!dllAlreadyPatched && !FileExists(backupDll) && !CopyFileW(dll.c_str(), backupDll.c_str(), TRUE)) {
        Log(L"FEHLER: DLL-Backup konnte nicht erstellt werden (Win32 %lu).", GetLastError());
        if (createdBackupExe) DeleteFileW(backupExe.c_str());
        Report(L"DLL-Backup konnte nicht erstellt werden. Es wurde nichts geÃ¤ndert.", L"Backup-Fehler", MB_ICONERROR);
        return false;
    }

    const std::vector<unsigned char> oldExeBytes = exeBytes;
    const std::vector<unsigned char> oldDllBytes = dllBytes;
    if (exeNeedsPatch) {
        const long pos = FindPattern(exeBytes, kCoopOrig, kCoopLen);
        if (pos < 0) { Log(L"FEHLER: EXE-Signatur verschwand nach der PrÃ¼fung."); return false; }
        memcpy(exeBytes.data() + pos, kCoopPatched, kCoopLen);
        if (!WriteBytes(exe, exeBytes)) {
            WriteBytes(exe, oldExeBytes);
            Log(L"FEHLER: EXE konnte nicht geschrieben werden; Wiederherstellung versucht.");
            return false;
        }
        Log(L"EXE  : Coop-Patch angewendet (Offset 0x%lX).", pos);
    } else {
        Log(L"EXE  : Coop-Patch war bereits aktiv.");
    }

    if (!dllAlreadyPatched) {
        if (!WriteBytes(dll, patchedDll)) {
            const DWORD error = GetLastError();
            if (exeNeedsPatch) WriteBytes(exe, oldExeBytes);
            Log(L"FEHLER: zhlREPENTOGON.dll konnte nicht geschrieben werden (Win32 %lu).", error);
            Report(L"Die DLL konnte nicht geschrieben werden. Die EXE wurde nach MÃ¶glichkeit zurÃ¼ckgesetzt; Backups bleiben erhalten.", L"Patch-Fehler", MB_ICONERROR);
            return false;
        }
        std::vector<unsigned char> installedDll;
        std::wstring installedHash;
        if (!ReadBytes(dll, installedDll) || !Sha256Bytes(installedDll, installedHash) || !IsFullDllHash(installedHash)) {
            WriteBytes(dll, oldDllBytes);
            if (exeNeedsPatch) WriteBytes(exe, oldExeBytes);
            Log(L"FEHLER: geschriebene DLL stimmt nicht mit dem geprÃ¼ften Ergebnis Ã¼berein; Rollback versucht.");
            Report(L"Die gepatchte DLL stimmt nicht mit dem geprÃ¼ften Ergebnis Ã¼berein. Rollback wurde versucht.", L"Patch-Fehler", MB_ICONERROR);
            return false;
        }
        Log(L"DLL  : Menue-Reset-Filter gepatcht (Offset 0x%lX).", menuPos);
        Log(L"DLL  : Online-Auswahl entsperrt (Offset 0x%lX).", onlinePos);
        Log(L"DLL  : Mod-Bann-Status 3 -> 0 (Offset 0x%lX).", banPos);
    } else {
        Log(L"DLL  : MenÃ¼-Fix war bereits aktiv.");
    }

    Log(L"Fertig. Backups f\u00FCr Zur\u00FCcksetzen: %s", BackupDir().c_str());
    Log(L"");
    Log(L"Online starten: Spiel \u00FCber den REPENTOGON-Launcher starten;");
    Log(L"Online-Men\u00FC Ã¶ffnen, Friend Match sichtbar ausw\u00E4hlen und erst dann bestÃ¤tigen.");
    RefreshStatus(true);
    return true;
}

static bool DoRevert() {
    if (GameRunning()) { Report(L"Das Spiel l\u00E4uft noch. Bitte schlie\u00DFen und erneut versuchen.", L"Spiel l\u00E4uft", MB_ICONWARNING); return false; }
    if (!g_backupExe && !g_backupDll) {
        Report(L"Keine Backups gefunden.\nEs wurde nichts ver\u00E4ndert.", L"Zur\u00FCcksetzen", MB_ICONINFORMATION);
        return false;
    }

    Log(L"--- Zur\u00FCcksetzen ---");
    const std::wstring exe = Join(Join(gInstall, L"Repentogon"), L"isaac-ng.exe");
    const std::wstring dll = Join(Join(gInstall, L"Repentogon"), L"zhlREPENTOGON.dll");

    if (g_backupExe) {
        if (CopyFileW(Join(BackupDir(), L"isaac-ng.exe").c_str(), exe.c_str(), FALSE))
            Log(L"EXE  : Original wiederhergestellt.");
        else Log(L"FEHLER: EXE konnte nicht wiederhergestellt werden (%lu).", GetLastError());
    }
    if (g_backupDll) {
        if (CopyFileW(Join(BackupDir(), L"zhlREPENTOGON.dll").c_str(), dll.c_str(), FALSE))
            Log(L"DLL  : Original wiederhergestellt.");
        else Log(L"FEHLER: DLL konnte nicht wiederhergestellt werden (%lu).", GetLastError());
    }
    RefreshStatus(true);
    return true;
}

static void DoPlay() {
    const wchar_t* cand[] = {
        L"C:\\Program Files\\REPENTOGONLauncher\\REPENTOGONLauncher.exe"
    };
    for (auto c : cand) {
        if (FileExists(c)) {
            Log(L"Starte Launcher: %s", c);
            ShellExecuteW(nullptr, L"open", c, nullptr, nullptr, SW_SHOWNORMAL);
            return;
        }
    }
    Log(L"Launcher nicht gefunden. Bitte das Spiel normal \u00FCber den Repentogon-Launcher starten.");
}

// --- Fenster -----------------------------------------------------------------
static void Layout(HWND hwnd) {
    RECT rc;
    GetClientRect(hwnd, &rc);
    int w = rc.right, h = rc.bottom;
    int pad = 14;

    MoveWindow(g_hHead, pad, pad, w - 2 * pad, 26, TRUE);
    MoveWindow(g_hPath, pad, pad + 30, w - 2 * pad - 96, 24, TRUE);
    MoveWindow(g_hBrowse, w - pad - 90, pad + 30, 90, 24, TRUE);

    MoveWindow(g_hStExe, pad + 4, pad + 62, w - 2 * pad, 20, TRUE);
    MoveWindow(g_hStDll, pad + 4, pad + 84, w - 2 * pad, 20, TRUE);

    int by = pad + 112;
    MoveWindow(g_hCheck, pad, by, 108, 30, TRUE);
    MoveWindow(g_hApply, pad + 116, by, 148, 30, TRUE);
    MoveWindow(g_hRevert, pad + 272, by, 120, 30, TRUE);

    MoveWindow(g_hHint, pad, by + 38, w - 2 * pad, 34, TRUE);

    int logTop = by + 78;
    MoveWindow(g_hLog, pad, logTop, w - 2 * pad, h - logTop - pad - 38, TRUE);
    MoveWindow(g_hPlay, pad, h - pad - 30, 190, 30, TRUE);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_bg = CreateSolidBrush(RGB(250, 250, 252));
        g_font = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                             DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
        g_fontBold = CreateFontW(-17, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                                 OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                 DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
        g_fontMono = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                                 OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                 FIXED_PITCH | FF_MODERN, L"Consolas");

        g_hHead = CreateWindowExW(0, L"STATIC", L"Repentogon Online-Patch v0.0.2 (experimentell)",
                                  WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, (HMENU)ID_HEAD, nullptr, nullptr);

        g_hPath = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                  WS_CHILD | WS_VISIBLE | ES_READONLY | ES_AUTOHSCROLL,
                                  0, 0, 0, 0, hwnd, (HMENU)ID_PATH, nullptr, nullptr);
        g_hBrowse = CreateWindowExW(0, L"BUTTON", L"Durchsuchen\u2026",
                                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                    0, 0, 0, 0, hwnd, (HMENU)ID_BROWSE, nullptr, nullptr);

        g_hStExe = CreateWindowExW(0, L"STATIC", L"EXE:  \u2026", WS_CHILD | WS_VISIBLE,
                                   0, 0, 0, 0, hwnd, (HMENU)ID_ST_EXE, nullptr, nullptr);
        g_hStDll = CreateWindowExW(0, L"STATIC", L"DLL:  \u2026", WS_CHILD | WS_VISIBLE,
                                   0, 0, 0, 0, hwnd, (HMENU)ID_ST_DLL, nullptr, nullptr);

        g_hCheck = CreateWindowExW(0, L"BUTTON", L"Pr\u00FCfen", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                   0, 0, 0, 0, hwnd, (HMENU)ID_CHECK, nullptr, nullptr);
        g_hApply = CreateWindowExW(0, L"BUTTON", L"Patch anwenden", WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON,
                                   0, 0, 0, 0, hwnd, (HMENU)ID_APPLY, nullptr, nullptr);
        g_hRevert = CreateWindowExW(0, L"BUTTON", L"Zur\u00FCcksetzen", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                    0, 0, 0, 0, hwnd, (HMENU)ID_REVERT, nullptr, nullptr);

        g_hHint = CreateWindowExW(0, L"STATIC",
                                  L"Experimentell: stabiler Lobby-Start ist nicht bestaetigt. Backups liegen neben der EXE; Zuruecksetzen stellt sie wieder her.",
                                  WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, (HMENU)ID_HINT, nullptr, nullptr);

        g_hLog = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                 WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                 0, 0, 0, 0, hwnd, (HMENU)ID_LOG, nullptr, nullptr);

        g_hPlay = CreateWindowExW(0, L"BUTTON", L"Launcher starten", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                  0, 0, 0, 0, hwnd, (HMENU)ID_PLAY, nullptr, nullptr);

        for (HWND h : {g_hHead, g_hPath, g_hBrowse, g_hStExe, g_hStDll,
                       g_hCheck, g_hApply, g_hRevert, g_hHint, g_hLog, g_hPlay})
            SendMessageW(h, WM_SETFONT, (WPARAM)(h == g_hHead ? g_fontBold
                                              : h == g_hLog ? g_fontMono : g_font), TRUE);

        gInstall = DetectInstall();
        if (gInstall.empty()) {
            wchar_t buf[MAX_PATH] = L"G:\\SteamLibrary\\steamapps\\common\\The Binding of Isaac Rebirth";
            SetWindowTextW(g_hPath, buf);
            gInstall = buf;
        } else {
            SetWindowTextW(g_hPath, gInstall.c_str());
        }

        Log(L"Repentogon Online-Patch v0.0.2 (experimentell)");
        Log(L"Patcht vorhandene Dateien in place: Coop-Patch (isaac-ng.exe) und");
        Log(L"drei Byte-Patches in zhlREPENTOGON.dll (1.1.3). Alles ist umkehrbar.");
        Log(L"Hinweis: Ein stabiler Lobby-Start mit Repentogon ist nicht bestaetigt.");
        Log(L"");
        if (gInstall.empty()) Log(L"Keine Installation automatisch gefunden \u2013 bitte \u00FCber \u201EDurchsuchen\u2026\u201C w\u00E4hlen.");
        else Log(L"Installation: %s", gInstall.c_str());

        RefreshStatus(true);
        return 0;
    }

    case WM_SIZE:
        Layout(hwnd);
        return 0;

    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        HWND ctl = (HWND)lp;
        SetBkColor(dc, RGB(250, 250, 252));

        if (ctl == g_hStExe || ctl == g_hStDll) {
            int st = (ctl == g_hStExe) ? g_exeState : g_dllState;
            if (st == 1)      SetTextColor(dc, RGB(22, 130, 60));
            else if (st == 0) SetTextColor(dc, RGB(170, 90, 0));
            else if (st == 2) SetTextColor(dc, RGB(170, 30, 30));
            else              SetTextColor(dc, RGB(90, 90, 90));
        } else if (ctl == g_hHead) {
            SetTextColor(dc, RGB(30, 30, 40));
        } else {
            SetTextColor(dc, RGB(70, 70, 80));
        }
        return (LRESULT)g_bg;
    }

    case WM_CTLCOLOREDIT: {
        HDC dc = (HDC)wp;
        SetBkColor(dc, RGB(255, 255, 255));
        SetTextColor(dc, RGB(30, 30, 35));
        return (LRESULT)GetStockObject(WHITE_BRUSH);
    }

    case WM_COMMAND: {
        switch (LOWORD(wp)) {
        case ID_BROWSE: {
            BROWSEINFOW bi{};
            bi.lpszTitle = L"Ordner \u201EThe Binding of Isaac Rebirth\u201C w\u00E4hlen";
            bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
            LPITEMIDLIST pidl = SHBrowseForFolderW(&bi);
            if (pidl) {
                wchar_t buf[MAX_PATH] = L"";
                if (SHGetPathFromIDListW(pidl, buf)) {
                    std::wstring pick = buf;
                    // auch Auswahl des Repentogon-Unterordners akzeptieren
                    if (IsValidInstall(pick)) { gInstall = pick; }
                    else if (IsValidInstall(pick + L"\\..")) { gInstall = pick + L"\\.."; }
                    else {
                        MessageBoxW(hwnd, L"Im gew\u00E4hlten Ordner wurde keine Repentogon-Installation gefunden\n(Repentogon\\isaac-ng.exe + zhlREPENTOGON.dll).", L"Ung\u00FCltiger Ordner", MB_ICONWARNING);
                    }
                    SetWindowTextW(g_hPath, gInstall.c_str());
                    Log(L"");
                    Log(L"Installation: %s", gInstall.c_str());
                    RefreshStatus(true);
                }
                CoTaskMemFree(pidl);
            }
            return 0;
        }
        case ID_CHECK:
            RefreshStatus(true);
            return 0;
        case ID_APPLY:
            (void)DoApply();
            return 0;
        case ID_REVERT:
            (void)DoRevert();
            return 0;
        case ID_PLAY:
            DoPlay();
            return 0;
        }
        return 0;
    }

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE inst, HINSTANCE, PWSTR, int show) {
    // Optional headless mode for verification:
    //   Patch.exe --check <install> | --apply <install> | --revert <install>
    std::wstring cliCommand, cliDir;
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv) {
        for (int i = 1; i < argc; ++i) {
            const std::wstring arg = argv[i];
            if (arg == L"--check" || arg == L"--apply" || arg == L"--revert") {
                cliCommand = arg;
                if (i + 1 < argc) cliDir = argv[i + 1];
            }
        }
        LocalFree(argv);
    }
    if (!cliCommand.empty()) {
        g_cli = true;
        gInstall = cliDir;
        const std::wstring cliLogPath = Join(ExeDir(), L"Patch-cli.log");
        _wfopen_s(&g_cliLog, cliLogPath.c_str(), L"w, ccs=UTF-8");
        Log(L"Repentogon Online-Patch v0.0.2 (CLI: %s)", cliCommand.c_str());
        Log(L"Installation: %s", gInstall.c_str());
        RefreshStatus(true);
        Log(L"EXE-Status: %d (0=original, 1=gepatcht, 2=unbekannt)", g_exeState);
        Log(L"DLL-Status: %d (0=Patch fehlt, 1=gepatcht, 2=unbekannt)", g_dllState);
        int cliExit = 0;
        if (!IsValidInstall(gInstall)) {
            Report(L"Keine gültige REPENTOGON-Installation.", L"Fehler", MB_ICONERROR);
            cliExit = 2;
        } else {
            bool ok = true;
            if (cliCommand == L"--apply") ok = DoApply();
            else if (cliCommand == L"--revert") ok = DoRevert();
            Log(L"Ergebnis: %s", ok ? L"OK" : L"FEHLER");
            cliExit = ok ? 0 : 1;
        }
        if (g_cliLog) { fclose(g_cliLog); g_cliLog = nullptr; }
        return cliExit;
    }

    SetProcessDPIAware();
    INITCOMMONCONTROLSEX icc{ sizeof(icc), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&icc);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    wc.hbrBackground = CreateSolidBrush(RGB(250, 250, 252));
    wc.lpszClassName = L"RgonOnlineUnlockWnd";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"Repentogon Online-Patch v0.0.2 (experimentell)",
                                WS_OVERLAPPEDWINDOW,
                                CW_USEDEFAULT, CW_USEDEFAULT, 700, 560,
                                nullptr, nullptr, inst, nullptr);
    if (!hwnd) return 1;

    ShowWindow(hwnd, show);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(hwnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return 0;
}
