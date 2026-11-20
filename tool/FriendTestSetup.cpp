// Self-contained installer for the experimental REPENTOGON friend-test tools.
// It installs only Patch.exe and a text guide. It does not ship game files,
// REPENTOGON binaries, mods, saves, or Steam credentials.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <string>

#pragma comment(lib, "comctl32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

enum { IDC_PATH = 1001, IDC_BROWSE, IDC_INSTALL, IDC_RUN_PATCHER, IDC_GUIDE, IDC_STATUS };
enum { IDR_PATCHER = 101, IDR_GUIDE = 102, IDR_MODSYNC = 103 };

static HINSTANCE g_instance = nullptr;
static HWND g_path = nullptr, g_status = nullptr;
static HWND g_install = nullptr, g_run = nullptr, g_guide = nullptr;
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
    SetWindowTextW(g_status, text);
}

static void UpdateInstalledButtons() {
    wchar_t buffer[MAX_PATH * 4] = L"";
    GetWindowTextW(g_path, buffer, _countof(buffer));
    const std::wstring folder = buffer;
    const bool installed = Exists(Join(folder, L"Patch.exe"))
                        && Exists(Join(folder, L"setup-freundestest-de.txt"))
                        && Exists(Join(folder, L"modsync.py"));
    EnableWindow(g_run, installed);
    EnableWindow(g_guide, installed);
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
    if (Exists(patcherPath) || Exists(guidePath) || Exists(modsyncPath)) {
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

    SetStatus(L"Installiere Patch.exe und die Test-Anleitung...");
    EnableWindow(g_install, FALSE);
    const bool patcherOk = WriteResource(IDR_PATCHER, patcherPath);
    const bool guideOk = patcherOk && WriteResource(IDR_GUIDE, guidePath);
    const bool modsyncOk = guideOk && WriteResource(IDR_MODSYNC, modsyncPath);
    if (!modsyncOk) {
        if (patcherOk) DeleteFileW(patcherPath.c_str());
        if (guideOk) DeleteFileW(guidePath.c_str());
        SetStatus(L"Installation fehlgeschlagen; unvollst\u00E4ndige Datei wurde entfernt.");
        EnableWindow(g_install, TRUE);
        MessageBoxW(owner,
            L"Die Dateien konnten nicht vollst\u00E4ndig geschrieben werden.\n"
            L"Es wurde keine bestehende Datei ersetzt.",
            L"Installationsfehler", MB_ICONERROR);
        return;
    }

    SetStatus(L"Fertig. Patch.exe enth\u00E4lt Pr\u00FCfen, Patch anwenden und Zur\u00FCcksetzen.");
    EnableWindow(g_install, TRUE);
    UpdateInstalledButtons();
    MessageBoxW(owner,
        L"Installation abgeschlossen.\n\n"
        L"Patch.exe, modsync.py und die Anleitung wurden installiert.\n"
        L"Patch.exe sichert die vorhandenen Spiel-Dateien und bietet Zur\u00FCcksetzen an.\n\n"
        L"Keine Spiel-EXE, REPENTOGON-Binaries, Workshop-Mods, Saves oder Steam-Zugangsdaten sind enthalten.",
        L"Fertig", MB_ICONINFORMATION);
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
    MoveWindow(GetDlgItem(window, 1102), pad, 50, width - 2 * pad, 52, TRUE);
    MoveWindow(g_path, pad, 116, width - 2 * pad - 108, 26, TRUE);
    MoveWindow(GetDlgItem(window, IDC_BROWSE), width - pad - 100, 116, 100, 26, TRUE);
    MoveWindow(GetDlgItem(window, 1103), pad, 154, width - 2 * pad, 54, TRUE);
    MoveWindow(g_install, pad, 222, 130, 32, TRUE);
    MoveWindow(g_run, pad + 140, 222, 150, 32, TRUE);
    MoveWindow(g_guide, pad + 300, 222, 150, 32, TRUE);
    MoveWindow(g_status, pad, 270, width - 2 * pad, 36, TRUE);
    MoveWindow(GetDlgItem(window, 1104), pad, 318, width - 2 * pad, 22, TRUE);
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

        HWND header = CreateWindowExW(0, L"STATIC", L"Isaac Repentogon Freund-Test – Setup v0.0.2",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1101, g_instance, nullptr);
        HWND warning = CreateWindowExW(0, L"STATIC",
            L"Installiert nur Patch.exe und eine Anleitung.\n"
            L"Experimentell: Eine funktionierende Online-Verbindung ist nicht best\u00E4tigt.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1102, g_instance, nullptr);
        g_path = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", DefaultFolder().c_str(),
            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL, 0, 0, 0, 0, window, (HMENU)IDC_PATH, g_instance, nullptr);
        HWND browse = CreateWindowExW(0, L"BUTTON", L"Durchsuchen...",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_BROWSE, g_instance, nullptr);
        HWND contents = CreateWindowExW(0, L"STATIC",
            L"Enthalten: Patch.exe (Pr\u00FCfen / Patch / Zur\u00FCcksetzen), gepr\u00FCfte REPENTOGON-1.1.3-Men\u00FC-DLL,\n"
            L"modsync.py und Anleitung. Keine Isaac-EXE, Workshop-Mods, Saves oder Steam-Daten.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1103, g_instance, nullptr);
        g_install = CreateWindowExW(0, L"BUTTON", L"Installieren",
            WS_CHILD | WS_VISIBLE | BS_DEFPUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_INSTALL, g_instance, nullptr);
        g_run = CreateWindowExW(0, L"BUTTON", L"Patch.exe starten",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_RUN_PATCHER, g_instance, nullptr);
        g_guide = CreateWindowExW(0, L"BUTTON", L"Anleitung \u00F6ffnen",
            WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, window, (HMENU)IDC_GUIDE, g_instance, nullptr);
        g_status = CreateWindowExW(0, L"STATIC", L"Bitte einen Zielordner pr\u00FCfen.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)IDC_STATUS, g_instance, nullptr);
        HWND footer = CreateWindowExW(0, L"STATIC",
            L"Nur f\u00FCr eigene Installationen und mit Zustimmung beider Spieler.",
            WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, window, (HMENU)1104, g_instance, nullptr);

        for (HWND control : { header, warning, g_path, browse, contents, g_install, g_run, g_guide, g_status, footer })
            SendMessageW(control, WM_SETFONT, (WPARAM)(control == header ? g_bold : g_font), TRUE);
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

    WNDCLASSEXW cls{};
    cls.cbSize = sizeof(cls);
    cls.lpfnWndProc = WindowProc;
    cls.hInstance = instance;
    cls.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    cls.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    cls.lpszClassName = L"IsaacFriendTestSetupWindow";
    if (!RegisterClassExW(&cls)) return 1;

    RECT rect{ 0, 0, 680, 370 };
    AdjustWindowRect(&rect, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX, FALSE);
    HWND window = CreateWindowExW(0, cls.lpszClassName,
        L"Isaac Repentogon Freund-Test Setup v0.0.2 (experimentell)",
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
