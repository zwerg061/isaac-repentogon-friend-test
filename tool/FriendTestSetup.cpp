// Self-contained installer for the experimental REPENTOGON friend-test tools.
// It installs local tools, documentation and the verified PATCHED
// zhlREPENTOGON.dll artifact into its own tool folder. It never writes into the
// game directory, and ships no game EXE, mods, saves or Steam credentials.
// v0.0.8: the persistent ModSync patch can be activated/deactivated with one
// click via Install-ModSyncPatch.ps1 and fully removed with "--uninstall".

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <cwchar>
#include <string>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib") // RegCreateKeyExW / RegDeleteTreeW
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

enum { IDC_PATH = 1001, IDC_BROWSE, IDC_INSTALL, IDC_RUN_PATCHER, IDC_GUIDE, IDC_STATUS,
       IDC_ACTIVATE = 1007, IDC_DEACTIVATE = 1008 };
enum {
    IDR_PATCHER = 101, IDR_GUIDE = 102, IDR_MODSYNC = 103, IDR_SESSION = 104,
    IDR_STEAMBRIDGE = 105, IDR_APPID = 106, IDR_VERSION = 107, IDR_RESYNC = 108,
    IDR_PATCHED_DLL = 109, IDR_INSTALL_SCRIPT = 110
};

static const wchar_t* const kInstallScriptName = L"Install-ModSyncPatch.ps1";
static const wchar_t* const kUninstallKey =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\IsaacModSyncFriendTest";
static const wchar_t* const kShortcutNames[] = {
    L"Isaac ModSync Friend Test.lnk", L"Isaac Freund-Test Setup.lnk"
};

static HINSTANCE g_instance = nullptr;
static HWND g_path = nullptr, g_status = nullptr;
static HWND g_install = nullptr, g_run = nullptr, g_guide = nullptr;
static HWND g_activate = nullptr, g_deactivate = nullptr;
static HFONT g_font = nullptr, g_bold = nullptr;

static std::wstring Join(const std::wstring& left, const wchar_t* right) {
    std::wstring result = left;
    if (!result.empty() && result.back() != L'\\') result += L'\\';
    result += right;
    return result;
}

static bool Exists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

// CommandLineToArgvW-compatible quoting: wrap in double quotes and escape any
// embedded quotes as well as backslashes directly before the closing quote.
// This keeps paths with spaces (and even a trailing backslash) intact.
static std::wstring QuoteArg(const std::wstring& value) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') { ++slashes; continue; }
        if (ch == L'"') {
            result.append(slashes * 2 + 1, L'\\');
            result += L'"';
        } else {
            result.append(slashes, L'\\');
            result += ch;
        }
        slashes = 0;
    }
    result.append(slashes * 2, L'\\');
    result += L'"';
    return result;
}

static bool WriteResource(int resourceId, const std::wstring& path) {
    HRSRC resource = FindResourceW(g_instance, MAKEINTRESOURCEW(resourceId), RT_RCDATA);
    if (!resource) return false;
    HGLOBAL loaded = LoadResource(g_instance, resource);
    if (!loaded) return false;
    const DWORD size = SizeofResource(g_instance, resource);
    const void* bytes = LockResource(loaded);
    if (!bytes || size == 0) return false;

    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    const bool ok = WriteFile(file, bytes, size, &written, nullptr) && written == size
                 && FlushFileBuffers(file);
    CloseHandle(file);
    if (!ok) DeleteFileW(path.c_str());
    return ok;
}

static std::wstring DefaultFolder() {
    PWSTR documents = nullptr;
    std::wstring result;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Documents, KF_FLAG_CREATE, nullptr, &documents))) {
        result = documents;
        CoTaskMemFree(documents);
    } else {
        wchar_t profile[MAX_PATH] = L"";
        DWORD length = GetEnvironmentVariableW(L"USERPROFILE", profile, MAX_PATH);
        result = length > 0 && length < MAX_PATH ? profile : L".";
        result = Join(result, L"Documents");
    }
    return Join(result, L"Isaac-Freund-Test-Tools");
}

static void SetStatus(const wchar_t* text) {
    if (g_status) SetWindowTextW(g_status, text);
}

// Silent launch of Install-ModSyncPatch.ps1. The script is NEVER called from
// Install(); only the two GUI buttons and the --uninstall CLI path call this.
static bool RunPatchScript(const std::wstring& script, const std::wstring& toolsRoot,
                           const wchar_t* action) {
    const std::wstring command = L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File "
                               + QuoteArg(script) + L" -Action " + action
                               + L" -ToolsRoot " + QuoteArg(toolsRoot);
    std::wstring mutableCommand = command; // CreateProcessW may modify the buffer

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(nullptr, &mutableCommand[0], nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
        return false;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return exitCode == 0;
}

static std::wstring OwnPath() {
    std::wstring buffer(MAX_PATH, L'\0');
    for (;;) {
        const DWORD length = GetModuleFileNameW(g_instance, &buffer[0], (DWORD)buffer.size());
        if (length == 0) return std::wstring();
        if (length < buffer.size() - 1) { buffer.resize(length); return buffer; }
        if (buffer.size() >= 32768) return std::wstring();
        buffer.resize(buffer.size() * 2);
    }
}

static std::wstring DirectoryOf(const std::wstring& path) {
    const size_t pos = path.find_last_of(L"\\/");
    return pos == std::wstring::npos ? std::wstring() : path.substr(0, pos + 1);
}

static bool SetUninstallValue(HKEY key, const wchar_t* name, const std::wstring& value) {
    return RegSetValueExW(key, name, 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(value.c_str()),
                          (DWORD)((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

static bool RegisterUninstallEntry(const std::wstring& setupPath) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kUninstallKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
                        &key, nullptr) != ERROR_SUCCESS) {
        return false;
    }
    const std::wstring quoted = QuoteArg(setupPath);
    const std::wstring uninstallCommand = quoted + L" --uninstall";
    bool ok = true;
    ok = SetUninstallValue(key, L"DisplayName", L"Isaac ModSync Friend Test") && ok;
    ok = SetUninstallValue(key, L"DisplayVersion", L"0.0.8") && ok;
    ok = SetUninstallValue(key, L"UninstallString", uninstallCommand) && ok;
    ok = SetUninstallValue(key, L"QuietUninstallString", uninstallCommand) && ok;
    ok = SetUninstallValue(key, L"DisplayIcon", setupPath) && ok;
    RegCloseKey(key);
    return ok;
}

static void RemoveUninstallEntry() {
    RegDeleteTreeW(HKEY_CURRENT_USER, kUninstallKey);
}

static void RemoveShortcutIn(REFKNOWNFOLDERID folderId, const wchar_t* name) {
    PWSTR folder = nullptr;
    if (FAILED(SHGetKnownFolderPath(folderId, 0, nullptr, &folder))) return;
    const std::wstring path = Join(folder, name);
    CoTaskMemFree(folder);
    DeleteFileW(path.c_str());
}

static void RemoveStartMenuShortcuts() {
    for (const wchar_t* name : kShortcutNames) {
        RemoveShortcutIn(FOLDERID_Programs, name);
        RemoveShortcutIn(FOLDERID_StartMenu, name);
    }
    // Also clean up a dedicated Start-menu folder, if one was created.
    PWSTR programs = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs))) return;
    const std::wstring folder = Join(programs, L"Isaac ModSync Friend Test");
    CoTaskMemFree(programs);

    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW(Join(folder, L"*.lnk").c_str(), &found);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            DeleteFileW(Join(folder, found.cFileName).c_str());
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }
    RemoveDirectoryW(folder.c_str());
}

static bool UninstallFromCommandLine() {
    const std::wstring exe = OwnPath();
    const std::wstring folder = DirectoryOf(exe);
    const std::wstring script = Join(folder, kInstallScriptName);
    bool ok = true;
    if (!folder.empty() && Exists(script)) {
        ok = RunPatchScript(script, folder, L"Uninstall");
    }
    // Always remove the Apps & Features entry and the Start-menu link, even if
    // the script was moved away or reported an error.
    RemoveUninstallEntry();
    RemoveStartMenuShortcuts();
    return ok;
}

static void UpdateInstalledButtons() {
    wchar_t buffer[MAX_PATH * 4] = L"";
    GetWindowTextW(g_path, buffer, _countof(buffer));
    const std::wstring folder = buffer;
    const bool installed = Exists(Join(folder, L"Patch.exe"))
                        && Exists(Join(folder, L"setup-freundestest-de.txt"))
                        && Exists(Join(folder, L"modsync.py"))
                        && Exists(Join(folder, L"Run-TempModProfile.ps1"))
                        && Exists(Join(folder, L"SteamModProfileBridge.exe"))
                        && Exists(Join(folder, L"steam_appid.txt"))
                        && Exists(Join(folder, L"zhlREPENTOGON.dll"));
    EnableWindow(g_run, installed);
    EnableWindow(g_guide, installed);
    const bool patchReady = installed && Exists(Join(folder, kInstallScriptName));
    EnableWindow(g_activate, patchReady);
    EnableWindow(g_deactivate, patchReady);
}

static void ChooseFolder(HWND owner) {
    BROWSEINFOW browse{};
    wchar_t displayName[MAX_PATH] = L"";
    browse.hwndOwner = owner;
    browse.pszDisplayName = displayName;
    browse.lpszTitle = L"Installationsordner f\u00FCr Patch.exe ausw\u00E4hlen";
    browse.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
    LPITEMIDLIST item = SHBrowseForFolderW(&browse);
    if (!item) return;
    wchar_t folder[MAX_PATH] = L"";
    if (SHGetPathFromIDListW(item, folder)) {
        SetWindowTextW(g_path, folder);
        SetStatus(L"Gew\u00E4hlten Ordner pr\u00FCfen und dann installieren.");
        UpdateInstalledButtons();
    }
    CoTaskMemFree(item);
}

static void Install(HWND owner) {
    wchar_t buffer[MAX_PATH * 4] = L"";
    GetWindowTextW(g_path, buffer, _countof(buffer));
    std::wstring folder = buffer;
    while (!folder.empty() && folder.back() == L' ') folder.pop_back();
    while (folder.size() > 3 && folder.back() == L'\\') folder.pop_back();
    if (folder.empty()) {
        MessageBoxW(owner, L"Bitte zuerst einen Installationsordner w\u00E4hlen.", L"Ordner fehlt", MB_ICONWARNING);
        return;
    }

    const std::wstring patcherPath = Join(folder, L"Patch.exe");
    const std::wstring guidePath = Join(folder, L"setup-freundestest-de.txt");
    const std::wstring modsyncPath = Join(folder, L"modsync.py");
    const std::wstring sessionPath = Join(folder, L"Run-TempModProfile.ps1");
    const std::wstring bridgePath = Join(folder, L"SteamModProfileBridge.exe");
    const std::wstring appIdPath = Join(folder, L"steam_appid.txt");
    const std::wstring versionPath = Join(folder, L"VERSION");
    const std::wstring resyncPath = Join(folder, L"Resync-ProfileAndSaveData.ps1");
    const std::wstring patchedDllPath = Join(folder, L"zhlREPENTOGON.dll");
    const std::wstring installScriptPath = Join(folder, kInstallScriptName);
    if (Exists(patcherPath) || Exists(guidePath) || Exists(modsyncPath) || Exists(sessionPath) ||
        Exists(bridgePath) || Exists(appIdPath) || Exists(versionPath) || Exists(resyncPath) ||
        Exists(patchedDllPath) || Exists(installScriptPath)) {
        MessageBoxW(owner,
            L"Im ausgew\u00E4hlten Ordner gibt es bereits eine oder mehrere Zieldateien.\n"
            L"Es wird nichts \u00FCberschrieben. Bitte einen leeren Ordner w\u00E4hlen.",
            L"Dateien vorhanden", MB_ICONWARNING);
        return;
    }

    int result = SHCreateDirectoryExW(owner, folder.c_str(), nullptr);
    if (result != ERROR_SUCCESS && result != ERROR_ALREADY_EXISTS && result != ERROR_FILE_EXISTS) {
        MessageBoxW(owner, L"Der Zielordner konnte nicht erstellt werden.", L"Installationsfehler", MB_ICONERROR);
        return;
    }

    SetStatus(L"Installiere Patch.exe, Mod-Werkzeuge und das Patch-Skript...");
    EnableWindow(g_install, FALSE);
    const bool patcherOk = WriteResource(IDR_PATCHER, patcherPath);
    const bool guideOk = patcherOk && WriteResource(IDR_GUIDE, guidePath);
    const bool modsyncOk = guideOk && WriteResource(IDR_MODSYNC, modsyncPath);
    const bool sessionOk = modsyncOk && WriteResource(IDR_SESSION, sessionPath);
    const bool bridgeOk = sessionOk && WriteResource(IDR_STEAMBRIDGE, bridgePath);
    const bool appIdOk = bridgeOk && WriteResource(IDR_APPID, appIdPath);
    const bool versionOk = appIdOk && WriteResource(IDR_VERSION, versionPath);
    const bool resyncOk = versionOk && WriteResource(IDR_RESYNC, resyncPath);
    const bool patchedDllOk = resyncOk && WriteResource(IDR_PATCHED_DLL, patchedDllPath);
    const bool installScriptOk = patchedDllOk && WriteResource(IDR_INSTALL_SCRIPT, installScriptPath);
    if (!installScriptOk) {
        if (patcherOk) DeleteFileW(patcherPath.c_str());
        if (guideOk) DeleteFileW(guidePath.c_str());
        if (modsyncOk) DeleteFileW(modsyncPath.c_str());
        if (sessionOk) DeleteFileW(sessionPath.c_str());
        if (bridgeOk) DeleteFileW(bridgePath.c_str());
        if (appIdOk) DeleteFileW(appIdPath.c_str());
        if (versionOk) DeleteFileW(versionPath.c_str());
        if (resyncOk) DeleteFileW(resyncPath.c_str());
        if (patchedDllOk) DeleteFileW(patchedDllPath.c_str());
        if (installScriptOk) DeleteFileW(installScriptPath.c_str());
        SetStatus(L"Installation fehlgeschlagen; unvollst\u00E4ndige Dateien wurden entfernt.");
        EnableWindow(g_install, TRUE);
        MessageBoxW(owner,
            L"Die Dateien konnten nicht vollst\u00E4ndig geschrieben werden.\n"
            L"Es wurde keine bestehende Datei ersetzt.",
            L"Installationsfehler", MB_ICONERROR);
        return;
    }

    const bool registered = RegisterUninstallEntry(OwnPath());
    SetStatus(registered
        ? L"Fertig. Patch dauerhaft aktivierbar; Werkzeuge und Uninstall-Eintrag installiert."
        : L"Fertig. Patch dauerhaft aktivierbar; Apps-&-Features-Eintrag fehlt.");
    EnableWindow(g_install, TRUE);
    UpdateInstalledButtons();
    MessageBoxW(owner,
        L"Installation abgeschlossen.\n\n"
        L"Patch.exe, Mod-Sync-Runner, Steam-P2P-Companion, Anleitung, das Patch-Skript\n"
        L"und die gepatchte zhlREPENTOGON.dll liegen in diesem Werkzeugordner.\n\n"
        L"Mit \"Patch aktivieren\" wird der Patch dauerhaft aktiviert; mit\n"
        L"\"Patch abschalten und deinstallieren\" wird er wieder komplett entfernt.\n"
        L"Die Deinstallation geht auch \u00FCber Apps & Features (Setup.exe --uninstall).\n\n"
        L"Keine Spiel-EXE, Workshop-Mods, Saves oder Steam-Zugangsdaten sind enthalten.",
        L"Fertig", MB_ICONINFORMATION);
}

static void RunScriptAction(HWND owner, const wchar_t* action,
                            const wchar_t* startText, const wchar_t* okText,
                            const wchar_t* failText) {
    wchar_t buffer[MAX_PATH * 4] = L"";
    GetWindowTextW(g_path, buffer, _countof(buffer));
    std::wstring folder = buffer;
    while (!folder.empty() && folder.back() == L' ') folder.pop_back();
    while (folder.size() > 3 && folder.back() == L'\\') folder.pop_back();
    const std::wstring script = Join(folder, kInstallScriptName);
    if (folder.empty() || !Exists(script)) {
        SetStatus(L"Install-ModSyncPatch.ps1 fehlt im Zielordner.");
        MessageBoxW(owner,
            L"Das Patch-Skript fehlt im Zielordner. Bitte zuerst installieren.",
            L"Patch", MB_ICONWARNING);
        return;
    }

    EnableWindow(g_activate, FALSE);
    EnableWindow(g_deactivate, FALSE);
    SetStatus(startText);
    const bool ok = RunPatchScript(script, folder, action);
    SetStatus(ok ? okText : failText);
    UpdateInstalledButtons();
    if (!ok) {
        MessageBoxW(owner, L"Das Skript meldete einen Fehler. Details stehen im Statusfeld.",
                    L"Patch", MB_ICONERROR);
    }
}

static void ActivatePatch(HWND owner) {
    RunScriptAction(owner, L"Apply",
        L"Patch wird dauerhaft aktiviert...",
        L"Patch dauerhaft aktiviert.",
        L"Patch-Aktivierung fehlgeschlagen.");
}

static void DeactivatePatch(HWND owner) {
    RunScriptAction(owner, L"Uninstall",
        L"Patch wird deaktiviert und deinstalliert...",
        L"Patch deaktiviert und deinstalliert.",
        L"Deinstallation des Patches fehlgeschlagen.");
}

static void OpenInstalledFile(HWND owner, const wchar_t* filename) {
    wchar_t buffer[MAX_PATH * 4] = L"";
    GetWindowTextW(g_path, buffer, _countof(buffer));
    const std::wstring path = Join(buffer, filename);
    HINSTANCE result = ShellExecuteW(owner, L"open", path.c_str(), nullptr, buffer, SW_SHOWNORMAL);
    if ((INT_PTR)result <= 32) {
        MessageBoxW(owner, L"Die Datei konnte nicht ge\u00F6ffnet werden.", L"Fehler", MB_ICONERROR);
    }
}

static void Layout(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    const int width = client.right;
    const int pad = 18;
    MoveWindow(GetDlgItem(window, 1101), pad, 16, width - 2 * pad, 28, TRUE);
    MoveWindow(GetDlgItem(window, 1102), pad, 50, width - 2 * pad, 68, TRUE);
    MoveWindow(g_path, pad, 126, width - 2 * pad - 108, 26, TRUE);
    MoveWindow(GetDlgItem(window, IDC_BROWSE), width - pad - 100, 126, 100, 26, TRUE);
    MoveWindow(GetDlgItem(window, 1103), pad, 164, width - 2 * pad, 54, TRUE);
    MoveWindow(g_install, pad, 228, 130, 32, TRUE);
    MoveWindow(g_run, pad + 140, 228, 150, 32, TRUE);
    MoveWindow(g_guide, pad + 300, 228, 150, 32, TRUE);
    MoveWindow(g_activate, pad, 270, 210, 32, TRUE);
    MoveWindow(g_deactivate, pad + 220, 270, 260, 32, TRUE);
    MoveWindow(g_status, pad, 314, width - 2 * pad, 44, TRUE);
    MoveWindow(GetDlgItem(window, 1104), pad, 368, width - 2 * pad, 22, TRUE);
}

static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
    case WM_CREATE: {
        g_font = CreateFontW(-15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
        g_bold = CreateFontW(-19, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
            DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");

        HWND header = CreateWindowExW(0, L"STATIC", L"Isaac Repentogon Freund-Test \u2013 Setup v0.0.8",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1101, g_instance, nullptr);
        HWND warning = CreateWindowExW(0, L"STATIC",
            L"Installiert nur Patch.exe, lokale Mod-Werkzeuge und eine Anleitung.\n"
            L"Der Patch kann dauerhaft aktiviert und wieder deinstalliert werden.\n"
            L"Experimentell: Eine funktionierende Online-Verbindung ist nicht best\u00E4tigt.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1102, g_instance, nullptr);
        g_path = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", DefaultFolder().c_str(),
            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 0, 0, 0, 0, window, (HMENU)IDC_PATH, g_instance, nullptr);
        HWND browse = CreateWindowExW(0, L"BUTTON", L"Durchsuchen...",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_BROWSE, g_instance, nullptr);
        HWND contents = CreateWindowExW(0, L"STATIC",
            L"Enthalten: Patch.exe, Temp-Mod-Runner, Steam-P2P-Companion, Patch-Skript\n"
            L"und Anleitung. Keine Isaac-EXE, Mods, Saves oder Steam-Zugangsdaten.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1103, g_instance, nullptr);
        g_install = CreateWindowExW(0, L"BUTTON", L"Installieren",
            WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_INSTALL, g_instance, nullptr);
        g_run = CreateWindowExW(0, L"BUTTON", L"Patch.exe starten",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_RUN_PATCHER, g_instance, nullptr);
        g_guide = CreateWindowExW(0, L"BUTTON", L"Anleitung \u00F6ffnen",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_GUIDE, g_instance, nullptr);
        g_activate = CreateWindowExW(0, L"BUTTON", L"Patch aktivieren",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_ACTIVATE, g_instance, nullptr);
        g_deactivate = CreateWindowExW(0, L"BUTTON", L"Patch abschalten && deinstallieren",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_DEACTIVATE, g_instance, nullptr);
        g_status = CreateWindowExW(0, L"STATIC", L"Bitte einen Zielordner pr\u00FCfen.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)IDC_STATUS, g_instance, nullptr);
        HWND footer = CreateWindowExW(0, L"STATIC",
            L"Nur f\u00FCr eigene Installationen und mit Zustimmung beider Spieler.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1104, g_instance, nullptr);

        for (HWND control : { header, warning, g_path, browse, contents, g_install,
                              g_run, g_guide, g_activate, g_deactivate, g_status, footer }) {
            SendMessageW(control, WM_SETFONT, (WPARAM)(control == header ? g_bold : g_font), TRUE);
        }
        UpdateInstalledButtons();
        return 0;
    }
    case WM_SIZE:
        Layout(window);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(wParam)) {
        case IDC_BROWSE: ChooseFolder(window); return 0;
        case IDC_INSTALL: Install(window); return 0;
        case IDC_RUN_PATCHER: OpenInstalledFile(window, L"Patch.exe"); return 0;
        case IDC_GUIDE: OpenInstalledFile(window, L"setup-freundestest-de.txt"); return 0;
        case IDC_ACTIVATE: ActivatePatch(window); return 0;
        case IDC_DEACTIVATE: DeactivatePatch(window); return 0;
        }
        return 0;
    case WM_DESTROY:
        if (g_font) DeleteObject(g_font);
        if (g_bold) DeleteObject(g_bold);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    g_instance = instance;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX controls{ sizeof(controls), ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&controls);

    bool uninstallRequested = false;
    int argc = 0;
    PWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv) {
        for (int i = 1; i < argc; ++i) {
            if (_wcsicmp(argv[i], L"--uninstall") == 0) {
                uninstallRequested = true;
                break;
            }
        }
        LocalFree(argv);
    }
    if (uninstallRequested) {
        const bool ok = UninstallFromCommandLine();
        CoUninitialize();
        return ok ? 0 : 1;
    }

    WNDCLASSEXW cls{};
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = WindowProc;
    cls.hInstance = instance;
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    cls.lpszClassName = L"IsaacFriendTestSetupWindow";
    if (!RegisterClassExW(&cls)) { CoUninitialize(); return 1; }

    RECT rect{ 0, 0, 680, 430 };
    AdjustWindowRect(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, FALSE);
    HWND window = CreateWindowExW(0, cls.lpszClassName,
        L"Isaac Repentogon Freund-Test Setup v0.0.8 (experimentell)",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top,
        nullptr, nullptr, instance, nullptr);
    if (!window) { CoUninitialize(); return 1; }
    ShowWindow(window, show);
    UpdateWindow(window);

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    CoUninitialize();
    return (int)message.wParam;
}
