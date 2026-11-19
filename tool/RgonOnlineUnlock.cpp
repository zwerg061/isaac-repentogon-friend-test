// ---------------------------------------------------------------------------
//  Repentogon Online Unlock v0.0.1
//
//  Kleines eigenstaendiges Windows-Tool (kein .NET, keine Installation):
//  wendet den experimentellen Online-Co-op-Patch fuer REPENTOGON an.
//
//  Es wendet zwei Patches an (beide reversibel, mit Backup):
//    1) Repentogon\isaac-ng.exe
//       Coop-Patch aus Isaac-Online-Modded (xADDBx): die Mod-Bann-Pruefung
//       der Engine wird neutralisiert.
//    2) Repentogon\zhlREPENTOGON.dll
//       Repentogon setzt in ModManager::ListMods hart _modBanStatus = 3.
//       Der Patch setzt den gespeicherten Wert auf 0 (Offset 0x2025C).
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
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <string>
#include <vector>
#include <cstdarg>
#include <cstdio>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
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
static int g_dllState = -1;        // 0 = ban 3, 1 = ban 0, 2 = unbekannt

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

    std::wstring line = buf;
    line += L"\r\n";
    int len = GetWindowTextLengthW(g_hLog);
    SendMessageW(g_hLog, EM_SETSEL, (WPARAM)len, (LPARAM)len);
    SendMessageW(g_hLog, EM_REPLACESEL, FALSE, (LPARAM)line.c_str());
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
        long pos = FindBanStore(dllBytes);
        if (pos < 0) {
            g_dllState = 2;
            SetWindowTextW(g_hStDll, L"DLL:  unbekannte Version");
            if (verbose) Log(L"DLL  : Hook-Muster von ModManager::ListMods nicht gefunden.");
        } else {
            int val = (int)dllBytes[pos] | ((int)dllBytes[pos+1] << 8)
                    | ((int)dllBytes[pos+2] << 16) | ((int)dllBytes[pos+3] << 24);
            if (val == 0) {
                g_dllState = 1;
                SetWindowTextW(g_hStDll, L"DLL:  gepatcht (Mod-Bann-Status = 0)  \x2714");
                if (verbose) Log(L"DLL  : gepatcht (Ban-Status 0, Offset 0x%lX).", pos);
            } else if (val == 3) {
                g_dllState = 0;
                SetWindowTextW(g_hStDll, L"DLL:  original (Mod-Bann-Status = 3)");
            } else {
                g_dllState = 2;
                wchar_t buf[128];
                swprintf_s(buf, L"DLL:  unerwarteter Wert %d", val);
                SetWindowTextW(g_hStDll, buf);
            }
        }
    }

    UpdateButtons();
    InvalidateRect(g_hStExe, nullptr, TRUE);
    InvalidateRect(g_hStDll, nullptr, TRUE);
}

// --- Aktionen ---------------------------------------------------------------
static void DoApply() {
    if (!IsValidInstall(gInstall)) { MessageBoxW(nullptr, L"Keine g\u00FCltige Repentogon-Installation gew\u00E4hlt.", L"Fehler", MB_ICONERROR); return; }
    if (GameRunning()) { MessageBoxW(nullptr, L"Das Spiel l\u00E4uft noch. Bitte schlie\u00DFen und erneut versuchen.", L"Spiel l\u00E4uft", MB_ICONWARNING); return; }

    CreateDirectoryW(BackupDir().c_str(), nullptr);

    const std::wstring exe = Join(Join(gInstall, L"Repentogon"), L"isaac-ng.exe");
    const std::wstring dll = Join(Join(gInstall, L"Repentogon"), L"zhlREPENTOGON.dll");

    Log(L"--- Patch anwenden ---");

    // 1) EXE
    std::vector<unsigned char> exeBytes;
    if (!ReadBytes(exe, exeBytes)) { Log(L"FEHLER: %s nicht lesbar.", exe.c_str()); return; }
    size_t orig = CountPattern(exeBytes, kCoopOrig, kCoopLen);
    size_t pat  = CountPattern(exeBytes, kCoopPatched, kCoopLen);

    if (pat == 1 && orig == 0) {
        Log(L"EXE  : war bereits gepatcht.");
    } else if (orig == 1 && pat == 0) {
        std::wstring bak = Join(BackupDir(), L"isaac-ng.exe");
        if (!FileExists(bak)) CopyFileW(exe.c_str(), bak.c_str(), FALSE);
        long pos = FindPattern(exeBytes, kCoopOrig, kCoopLen);
        memcpy(exeBytes.data() + pos, kCoopPatched, kCoopLen);
        if (!WriteBytes(exe, exeBytes)) { Log(L"FEHLER: EXE konnte nicht geschrieben werden."); return; }
        Log(L"EXE  : gepatcht (Offset 0x%lX).", pos);
    } else {
        Log(L"FEHLER: EXE-Muster passt nicht (orig=%zu, patched=%zu). Falsche Version?", orig, pat);
        MessageBoxW(nullptr, L"Das erwartete Byte-Muster wurde nicht gefunden.\nVermutlich eine andere Repentogon-Version.\nEs wurde nichts ge\u00E4ndert.", L"Nicht unterst\u00FCtzt", MB_ICONERROR);
        return;
    }

    // 2) DLL
    std::vector<unsigned char> dllBytes;
    if (!ReadBytes(dll, dllBytes)) { Log(L"FEHLER: %s nicht lesbar.", dll.c_str()); return; }
    long banPos = FindBanStore(dllBytes);
    if (banPos < 0) {
        Log(L"FEHLER: DLL-Hook-Muster nicht gefunden.");
        MessageBoxW(nullptr, L"Das erwartete Muster in zhlREPENTOGON.dll wurde nicht gefunden.\nEs wurde nichts ge\u00E4ndert.", L"Nicht unterst\u00FCtzt", MB_ICONERROR);
        return;
    }
    int val = (int)dllBytes[banPos] | ((int)dllBytes[banPos+1] << 8)
            | ((int)dllBytes[banPos+2] << 16) | ((int)dllBytes[banPos+3] << 24);

    if (val == 0) {
        Log(L"DLL  : war bereits gepatcht.");
    } else if (val == 3) {
        std::wstring bak = Join(BackupDir(), L"zhlREPENTOGON.dll");
        if (!FileExists(bak)) CopyFileW(dll.c_str(), bak.c_str(), FALSE);
        dllBytes[banPos] = dllBytes[banPos+1] = dllBytes[banPos+2] = dllBytes[banPos+3] = 0;
        if (!WriteBytes(dll, dllBytes)) { Log(L"FEHLER: DLL konnte nicht geschrieben werden."); return; }
        Log(L"DLL  : gepatcht (Ban-Status 3 -> 0, Offset 0x%lX).", banPos);
    } else {
        Log(L"FEHLER: unerwarteter Wert %d in der DLL.", val);
        MessageBoxW(nullptr, L"Die DLL enth\u00E4lt einen unerwarteten Wert.\nEs wurde nichts ge\u00E4ndert.", L"Nicht unterst\u00FCtzt", MB_ICONERROR);
        return;
    }

    Log(L"Fertig. Backups: %s", BackupDir().c_str());
    Log(L"");
    Log(L"Online starten: Spiel \u00FCber den Repentogon-Launcher starten,");
    Log(L"im Hauptmen\u00FC  ~  dr\u00FCcken und  netstart <SteamID>  eingeben.");
    RefreshStatus(true);
}

static void DoRevert() {
    if (GameRunning()) { MessageBoxW(nullptr, L"Das Spiel l\u00E4uft noch. Bitte schlie\u00DFen und erneut versuchen.", L"Spiel l\u00E4uft", MB_ICONWARNING); return; }
    if (!g_backupExe && !g_backupDll) {
        MessageBoxW(nullptr, L"Keine Backups gefunden.\nEs wurde nichts ver\u00E4ndert.", L"Zur\u00FCcksetzen", MB_ICONINFORMATION);
        return;
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

        g_hHead = CreateWindowExW(0, L"STATIC", L"Repentogon Online-Co-op-Patch v0.0.1 (experimentell)",
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

        Log(L"Repentogon Online-Co-op-Patch v0.0.1 (experimentell)");
        Log(L"Wendet zwei Patches an: Coop-Patch (isaac-ng.exe) und");
        Log(L"Mod-Bann-Status (zhlREPENTOGON.dll). Beides ist umkehrbar.");
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
            DoApply();
            return 0;
        case ID_REVERT:
            DoRevert();
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

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"Repentogon Online-Co-op-Patch v0.0.1 (experimentell)",
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
