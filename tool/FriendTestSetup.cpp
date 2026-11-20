// Self-contained installer for the experimental REPENTOGON friend-test tools.
// It installs local tools, documentation and the verified PATCHED
// zhlREPENTOGON.dll artifact into its own tool folder. It never writes into the
// game directory, and ships no game EXE, mods, saves or Steam credentials.
// v0.0.10: the patch script stops running game processes, clears ReadOnly flags
// and retries DLL writes. v0.0.9 added auto-install, real PowerShell error
// reporting in %LOCALAPPDATA%\IsaacModSync\install.log and an Isaac folder
// picker (-IsaacRoot) when Steam auto-detection fails.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <commdlg.h>
#include <shlobj.h>
#include <shellapi.h>
#include <cwchar>
#include <fstream>
#include <string>
#include <vector>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "comdlg32.lib") // GetOpenFileNameW
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

static std::wstring InstallLogPath() {
    std::wstring directory;
    PWSTR known = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &known))) {
        directory = known;
        CoTaskMemFree(known);
    } else {
        wchar_t expanded[MAX_PATH] = L"";
        if (ExpandEnvironmentStringsW(L"%LOCALAPPDATA%", expanded, MAX_PATH) > 0) directory = expanded;
    }
    if (directory.empty()) directory = L"C:\\";
    const std::wstring modsyncDir = Join(directory, L"IsaacModSync");
    CreateDirectoryW(modsyncDir.c_str(), nullptr);
    return Join(modsyncDir, L"install.log");
}

static std::wstring ReadLogTail(const std::wstring& path, size_t maxChars = 1800) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return L"";
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size)) { CloseHandle(file); return L""; }
    const LONGLONG wanted = size.QuadPart < 8000 ? size.QuadPart : 8000;
    LARGE_INTEGER offset{};
    offset.QuadPart = size.QuadPart - wanted;
    SetFilePointerEx(file, offset, nullptr, FILE_BEGIN);
    std::string bytes(static_cast<size_t>(wanted), '\0');
    DWORD read = 0;
    ReadFile(file, &bytes[0], static_cast<DWORD>(bytes.size()), &read, nullptr);
    CloseHandle(file);
    bytes.resize(read);
    const int wideLength = MultiByteToWideChar(CP_UTF8, 0, bytes.c_str(),
                                               static_cast<int>(bytes.size()), nullptr, 0);
    if (wideLength <= 0) return L"";
    std::wstring text(static_cast<size_t>(wideLength), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, bytes.c_str(), static_cast<int>(bytes.size()),
                        &text[0], wideLength);
    if (!text.empty() && text[0] == 0xFEFF) text.erase(0, 1);
    if (text.size() > maxChars) text = text.substr(text.size() - maxChars);
    const size_t errorPos = text.rfind(L"FEHLER");
    if (errorPos != std::wstring::npos) text = text.substr(errorPos);
    return text;
}

// Silent launch of Install-ModSyncPatch.ps1. stdout and stderr are redirected
// to install.log so a failure can be reported verbatim in the GUI.
static bool RunPatchScript(const std::wstring& script, const std::wstring& toolsRoot,
                           const wchar_t* action, const std::wstring& isaacRoot = L"",
                           std::wstring* errorText = nullptr) {
    std::wstring command = L"powershell.exe -NoProfile -ExecutionPolicy Bypass -File "
                         + QuoteArg(script) + L" -Action " + action
                         + L" -ToolsRoot " + QuoteArg(toolsRoot);
    if (!isaacRoot.empty()) command += L" -IsaacRoot " + QuoteArg(isaacRoot);
    std::wstring mutableCommand = command; // CreateProcessW may modify the buffer

    const std::wstring logPath = InstallLogPath();
    // The PowerShell script writes its own detailed error to this exact file.
    SetEnvironmentVariableW(L"ISAAC_MODSYNC_LOG_PATH", logPath.c_str());
    HANDLE logFile = CreateFileW(logPath.c_str(), FILE_APPEND_DATA | FILE_WRITE_DATA,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL, nullptr);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW | (logFile != INVALID_HANDLE_VALUE ? STARTF_USESTDHANDLES : 0);
    startup.wShowWindow = SW_HIDE;
    if (logFile != INVALID_HANDLE_VALUE) {
        startup.hStdOutput = logFile;
        startup.hStdError = logFile;
    }
    PROCESS_INFORMATION process{};
    const bool created = CreateProcessW(nullptr, &mutableCommand[0], nullptr, nullptr,
                                        logFile != INVALID_HANDLE_VALUE, CREATE_NO_WINDOW,
                                        nullptr, nullptr, &startup, &process);
    if (!created) {
        if (errorText) *errorText = L"powershell.exe konnte nicht gestartet werden (Win32 " +
            std::to_wstring(GetLastError()) + L").";
        if (logFile != INVALID_HANDLE_VALUE) CloseHandle(logFile);
        SetEnvironmentVariableW(L"ISAAC_MODSYNC_LOG_PATH", nullptr);
        return false;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    if (logFile != INVALID_HANDLE_VALUE) CloseHandle(logFile);
    SetEnvironmentVariableW(L"ISAAC_MODSYNC_LOG_PATH", nullptr);
    if (exitCode != 0 && errorText) {
        const std::wstring tail = ReadLogTail(logPath);
        *errorText = tail.empty() ? L"Das Patch-Skript meldete einen Fehler (siehe install.log)."
                                  : tail;
    }
    return exitCode == 0;
}

static std::vector<std::wstring> SteamRoots() {
    std::vector<std::wstring> roots;
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Valve\\Steam", 0, KEY_READ, &key) == ERROR_SUCCESS) {
        wchar_t value[MAX_PATH] = L"";
        DWORD size = sizeof(value);
        if (RegQueryValueExW(key, L"SteamPath", nullptr, nullptr,
                            reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS && value[0]) {
            roots.push_back(value);
        }
        RegCloseKey(key);
    }
    key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\WOW6432Node\\Valve\\Steam", 0, KEY_READ, &key) == ERROR_SUCCESS) {
        wchar_t value[MAX_PATH] = L"";
        DWORD size = sizeof(value);
        if (RegQueryValueExW(key, L"InstallPath", nullptr, nullptr,
                            reinterpret_cast<BYTE*>(value), &size) == ERROR_SUCCESS && value[0]) {
            roots.push_back(value);
        }
        RegCloseKey(key);
    }
    if (!roots.empty()) {
        const std::wstring vdf = Join(roots[0], L"steamapps\\libraryfolders.vdf");
        std::wifstream input(vdf.c_str());
        std::wstring line;
        while (std::getline(input, line)) {
            const size_t pos = line.find(L"\"path\"");
            if (pos == std::wstring::npos) continue;
            const size_t first = line.find(L'\"', pos + 6);
            const size_t second = first == std::wstring::npos ? std::wstring::npos
                                                              : line.find(L'\"', first + 1);
            if (second == std::wstring::npos) continue;
            std::wstring path = line.substr(first + 1, second - first - 1);
            for (size_t i = 0; i + 1 < path.size(); ++i) {
                if (path[i] == L'\\' && path[i + 1] == L'\\') { path.erase(i, 1); --i; }
            }
            if (!path.empty()) roots.push_back(path);
        }
    }
    return roots;
}

static std::wstring FindIsaacRoot() {
    // Hidden automation hook: lets fixture tests drive the real GUI without
    // touching the user's Steam installation.
    wchar_t overridePath[MAX_PATH] = L"";
    if (GetEnvironmentVariableW(L"ISAAC_MODSYNC_TEST_ISAAC_ROOT", overridePath, MAX_PATH) > 0 &&
        Exists(Join(overridePath, L"isaac-ng.exe"))) {
        return overridePath;
    }
    static const wchar_t* const kNames[] = {
        L"The Binding of Isaac Rebirth", L"The Binding of Isaac Afterbirth+",
        L"The Binding of Isaac Repentance", L"The Binding of Isaac Repentance+"
    };
    for (const std::wstring& root : SteamRoots()) {
        for (const wchar_t* name : kNames) {
            const std::wstring candidate = Join(Join(Join(root, L"steamapps"), L"common"), name);
            if (Exists(Join(candidate, L"isaac-ng.exe"))) return candidate;
        }
    }
    return L"";
}

static std::wstring PickIsaacRoot(HWND owner) {
    wchar_t file[MAX_PATH * 2] = L"";
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = owner;
    dialog.lpstrFilter = L"isaac-ng.exe\0isaac-ng.exe\0Alle Dateien\0*.*\0\0";
    dialog.lpstrFile = file;
    dialog.nMaxFile = MAX_PATH * 2;
    dialog.lpstrTitle = L"Bitte isaac-ng.exe der Isaac-Installation ausw\u00E4hlen";
    dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_EXPLORER;
    if (!GetOpenFileNameW(&dialog)) return L"";
    std::wstring selected = file;
    const size_t slash = selected.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"" : selected.substr(0, slash);
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
    ok = SetUninstallValue(key, L"DisplayVersion", L"0.0.10") && ok;
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
    // v0.0.9: activation always works - missing tools are installed on demand.
    EnableWindow(g_activate, TRUE);
    EnableWindow(g_deactivate, TRUE);
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

struct EmbeddedFile { int resource; const wchar_t* name; };

static const EmbeddedFile kEmbeddedFiles[] = {
    { IDR_PATCHER, L"Patch.exe" },
    { IDR_GUIDE, L"setup-freundestest-de.txt" },
    { IDR_MODSYNC, L"modsync.py" },
    { IDR_SESSION, L"Run-TempModProfile.ps1" },
    { IDR_STEAMBRIDGE, L"SteamModProfileBridge.exe" },
    { IDR_APPID, L"steam_appid.txt" },
    { IDR_VERSION, L"VERSION" },
    { IDR_RESYNC, L"Resync-ProfileAndSaveData.ps1" },
    { IDR_PATCHED_DLL, L"zhlREPENTOGON.dll" },
    { IDR_INSTALL_SCRIPT, L"Install-ModSyncPatch.ps1" }
};

static bool ToolsComplete(const std::wstring& folder) {
    for (const EmbeddedFile& file : kEmbeddedFiles) {
        if (!Exists(Join(folder, file.name))) return false;
    }
    return true;
}

static bool DoInstallTools(const std::wstring& folder, bool silent, std::wstring& error) {
    if (folder.empty()) { error = L"Kein Zielordner angegeben."; return false; }
    int result = SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
    if (result != ERROR_SUCCESS && result != ERROR_ALREADY_EXISTS && result != ERROR_FILE_EXISTS) {
        error = L"Zielordner konnte nicht erstellt werden (Win32 " + std::to_wstring(result) + L").";
        return false;
    }
    if (!silent) {
        for (const EmbeddedFile& file : kEmbeddedFiles) {
            if (Exists(Join(folder, file.name))) {
                error = L"Im Zielordner existieren bereits Dateien. Es wird nichts \u00FCberschrieben.";
                return false;
            }
        }
    }
    std::vector<std::wstring> written;
    for (const EmbeddedFile& file : kEmbeddedFiles) {
        const std::wstring path = Join(folder, file.name);
        if (silent && Exists(path)) continue;
        if (!WriteResource(file.resource, path)) {
            for (const std::wstring& done : written) DeleteFileW(done.c_str());
            error = std::wstring(L"Datei konnte nicht geschrieben werden: ") + file.name +
                    L" (Win32 " + std::to_wstring(GetLastError()) + L").";
            return false;
        }
        written.push_back(path);
    }
    return true;
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

    SetStatus(L"Installiere Patch.exe, Mod-Werkzeuge und das Patch-Skript...");
    EnableWindow(g_install, FALSE);
    std::wstring error;
    const bool ok = DoInstallTools(folder, false, error);
    if (!ok) {
        SetStatus(error.c_str());
        MessageBoxW(owner, error.c_str(), L"Installationsfehler", MB_ICONERROR);
        EnableWindow(g_install, TRUE);
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
    if (folder.empty()) {
        MessageBoxW(owner, L"Bitte zuerst einen Zielordner angeben.", L"Patch", MB_ICONWARNING);
        return;
    }

    // One-click: install the embedded tools first if they are not there yet.
    if (!ToolsComplete(folder)) {
        SetStatus(L"Werkzeuge fehlen - installiere eingebettete Dateien automatisch...");
        std::wstring installError;
        if (!DoInstallTools(folder, true, installError)) {
            const std::wstring message = std::wstring(L"Auto-Installation fehlgeschlagen: ") + installError;
            SetStatus(message.c_str());
            MessageBoxW(owner, message.c_str(), L"Patch", MB_ICONERROR);
            return;
        }
        RegisterUninstallEntry(OwnPath());
    }

    const std::wstring script = Join(folder, kInstallScriptName);
    if (!Exists(script)) {
        const std::wstring message = std::wstring(L"Patch-Skript fehlt nach der Installation: ") + script;
        SetStatus(message.c_str());
        MessageBoxW(owner, message.c_str(), L"Patch", MB_ICONERROR);
        return;
    }

    // Locate Isaac; ask for isaac-ng.exe if Steam auto-detection fails.
    std::wstring isaacRoot = FindIsaacRoot();
    if (isaacRoot.empty()) {
        SetStatus(L"Steam-Isaac nicht gefunden - bitte isaac-ng.exe ausw\u00E4hlen.");
        isaacRoot = PickIsaacRoot(owner);
    }
    if (isaacRoot.empty()) {
        const std::wstring message =
            L"Isaac-Ordner konnte nicht gefunden werden. Bitte isaac-ng.exe manuell ausw\u00E4hlen.";
        SetStatus(message.c_str());
        MessageBoxW(owner, message.c_str(), L"Patch", MB_ICONWARNING);
        return;
    }

    EnableWindow(g_activate, FALSE);
    EnableWindow(g_deactivate, FALSE);
    SetStatus(startText);
    std::wstring errorText;
    const bool ok = RunPatchScript(script, folder, action, isaacRoot, &errorText);
    if (ok) {
        SetStatus(okText);
    } else {
        const std::wstring detail = std::wstring(failText) + L"\n" + errorText +
            L"\n\nDetails: %LOCALAPPDATA%\\IsaacModSync\\install.log";
        SetStatus(detail.c_str());
        MessageBoxW(owner, detail.c_str(), L"Patch", MB_ICONERROR);
    }
    UpdateInstalledButtons();
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

        HWND header = CreateWindowExW(0, L"STATIC", L"Isaac Repentogon Freund-Test \u2013 Setup v0.0.10",
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
        L"Isaac Repentogon Freund-Test Setup v0.0.10 (experimentell)",
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
