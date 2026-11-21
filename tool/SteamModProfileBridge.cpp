// Experimental, token-free Steam P2P transport for host mod-profile JSON.
// It loads the game's Steam API DLL dynamically; no Steam files are copied.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <bcrypt.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace fs = std::filesystem;
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "user32.lib")
using SteamId = unsigned long long;
using SteamBool = bool;

constexpr int kFriendFlagImmediate = 0x04;
constexpr int kP2PSendReliable = 2;
constexpr int kP2PChannel = 71;
constexpr size_t kMaxProfileBytes = 1024 * 1024;
constexpr char kReadyPrefix[] = "MODSYNC-READY-V1|";
constexpr char kAckPrefix[] = "MODSYNC-ACK-V1|";
constexpr char kProfilePrefix[] = "MODSYNC-PROFILE-V1|";
// Must stay in sync with Runner VERSION / modsync TOOL_VERSION / setup resource.
// Bumped from 0.0.6: the watcher passes the setup version via
// --expected-version. A stale constant made Parse() reject every handshake and
// steam-bridge.ready never appeared.
constexpr char kToolVersion[] = "0.0.19";
constexpr int kDialogDesyncAssistant = 200;
constexpr int kIdcDesyncReason = 1001;
constexpr int kIdcDesyncDetail = 1002;
constexpr int kIdcDesyncAffected = 1003;
constexpr int kIdcResync = 1004;
constexpr int kIdcDismiss = 1005;

struct Options;
struct DesyncFinding;
static void CheckLogForDesync(const Options& options);
static void ShowP2PFailure(const Options& options, const wchar_t* reason);

struct SteamApi {
    HMODULE module = nullptr;
    void* friends = nullptr;
    void* networking = nullptr;
    void* matchmaking = nullptr;
    void* user = nullptr;
    bool initialized = false;

    using InitFn = int(__cdecl*)(const char*, char*);
    using VoidFn = void(__cdecl*)();
    using InterfaceFn = void*(__cdecl*)();
    using HasFriendFn = SteamBool(__cdecl*)(void*, SteamId, int);
    using PersonaNameFn = const char*(__cdecl*)(void*, SteamId);
    using AcceptP2PFn = SteamBool(__cdecl*)(void*, SteamId);
    using SendP2PFn = SteamBool(__cdecl*)(void*, SteamId, const void*, unsigned int, int, int);
    using IsP2PAvailableFn = SteamBool(__cdecl*)(void*, unsigned int*, int);
    using ReadP2PFn = SteamBool(__cdecl*)(void*, void*, unsigned int, unsigned int*, SteamId*, int);
    using UserSteamIdFn = SteamId(__cdecl*)(void*);
    using LobbyOwnerFn = SteamId(__cdecl*)(void*, SteamId);
    using LobbyCountFn = int(__cdecl*)(void*, SteamId);
    using LobbyMemberFn = SteamId(__cdecl*)(void*, SteamId, int);
    using SetLobbyDataFn = SteamBool(__cdecl*)(void*, SteamId, const char*, const char*);
    using GetLobbyDataFn = const char*(__cdecl*)(void*, SteamId, const char*);

    VoidFn runCallbacks = nullptr;
    VoidFn shutdown = nullptr;
    HasFriendFn hasFriend = nullptr;
    PersonaNameFn personaName = nullptr;
    AcceptP2PFn acceptP2P = nullptr;
    SendP2PFn sendP2P = nullptr;
    IsP2PAvailableFn isP2PAvailable = nullptr;
    ReadP2PFn readP2P = nullptr;
    UserSteamIdFn userSteamId = nullptr;
    LobbyOwnerFn lobbyOwner = nullptr;
    LobbyCountFn lobbyCount = nullptr;
    LobbyMemberFn lobbyMember = nullptr;
    SetLobbyDataFn setLobbyData = nullptr;
    GetLobbyDataFn getLobbyData = nullptr;

    template <typename T>
    T Proc(const char* name) {
        auto value = reinterpret_cast<T>(GetProcAddress(module, name));
        if (!value) throw std::runtime_error(std::string("Steam API export missing: ") + name);
        return value;
    }

    void Init(const fs::path& isaacRoot, bool readOnly = false) {
        const auto dll = isaacRoot / L"Repentogon" / L"steam_api.dll";
        const auto dllDirectory = (isaacRoot / L"Repentogon").wstring();
        if (!SetDllDirectoryW(dllDirectory.c_str())) {
            throw std::runtime_error("Could not set the Isaac Steam API DLL search path");
        }
        module = LoadLibraryW(dll.c_str());
        if (!module) throw std::runtime_error("Could not load Repentogon\\steam_api.dll");

        const auto init = Proc<InitFn>("SteamInternal_SteamAPI_Init");
        runCallbacks = Proc<VoidFn>("SteamAPI_RunCallbacks");
        shutdown = Proc<VoidFn>("SteamAPI_Shutdown");
        static const char interfaces[] =
            "SteamUtils010\0SteamFriends017\0SteamNetworking006\0SteamUser023\0SteamMatchMaking009\0\0";
        static const char readOnlyInterfaces[] =
            "SteamUtils010\0SteamFriends017\0SteamUser023\0SteamMatchMaking009\0\0";
        char error[1024]{};
        if (init(readOnly ? readOnlyInterfaces : interfaces, error) != 0) {
            throw std::runtime_error(std::string("SteamAPI init failed: ") + error);
        }
        initialized = true;

        const auto friendsGetter = Proc<InterfaceFn>("SteamAPI_SteamFriends_v017");
        const auto matchmakingGetter = Proc<InterfaceFn>("SteamAPI_SteamMatchmaking_v009");
        const auto userGetter = Proc<InterfaceFn>("SteamAPI_SteamUser_v023");
        friends = friendsGetter();
        if (!readOnly) networking = Proc<InterfaceFn>("SteamAPI_SteamNetworking_v006")();
        matchmaking = matchmakingGetter();
        user = userGetter();
        if (!friends || (!readOnly && !networking) || !matchmaking || !user) throw std::runtime_error("Required Steam interfaces unavailable");

        hasFriend = Proc<HasFriendFn>("SteamAPI_ISteamFriends_HasFriend");
        personaName = Proc<PersonaNameFn>("SteamAPI_ISteamFriends_GetFriendPersonaName");
        if (!readOnly) {
            acceptP2P = Proc<AcceptP2PFn>("SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser");
            sendP2P = Proc<SendP2PFn>("SteamAPI_ISteamNetworking_SendP2PPacket");
            isP2PAvailable = Proc<IsP2PAvailableFn>("SteamAPI_ISteamNetworking_IsP2PPacketAvailable");
            readP2P = Proc<ReadP2PFn>("SteamAPI_ISteamNetworking_ReadP2PPacket");
        }
        userSteamId = Proc<UserSteamIdFn>("SteamAPI_ISteamUser_GetSteamID");
        lobbyOwner = Proc<LobbyOwnerFn>("SteamAPI_ISteamMatchmaking_GetLobbyOwner");
        lobbyCount = Proc<LobbyCountFn>("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers");
        lobbyMember = Proc<LobbyMemberFn>("SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex");
        // Optional lobby-data fallback. Not all Steam API builds export it.
        setLobbyData = reinterpret_cast<SetLobbyDataFn>(GetProcAddress(module, "SteamAPI_ISteamMatchmaking_SetLobbyData"));
        getLobbyData = reinterpret_cast<GetLobbyDataFn>(GetProcAddress(module, "SteamAPI_ISteamMatchmaking_GetLobbyData"));
    }

    ~SteamApi() {
        if (initialized && shutdown) shutdown();
        if (module) FreeLibrary(module);
    }

    std::string FriendName(SteamId id) const {
        const char* name = personaName(friends, id);
        return name ? name : "Steam-Freund";
    }

    std::vector<SteamId> LobbyMembers(SteamId lobby) const {
        const int count = lobbyCount(matchmaking, lobby);
        if (count < 1 || count > 250) return {};
        std::vector<SteamId> result;
        for (int i = 0; i < count; ++i) {
            const SteamId id = lobbyMember(matchmaking, lobby, i);
            if (id) result.push_back(id);
        }
        return result;
    }

    bool IsLobbyMember(SteamId lobby, SteamId id) const {
        const auto members = LobbyMembers(lobby);
        return id && std::find(members.begin(), members.end(), id) != members.end();
    }

    bool IsFriendInLobby(SteamId lobby, SteamId peer) const {
        return peer && hasFriend(friends, peer, kFriendFlagImmediate) && IsLobbyMember(lobby, peer);
    }

    void AcceptLobbyFriends(SteamId lobby) const {
        for (SteamId peer : LobbyMembers(lobby)) {
            if (peer != userSteamId(user) && IsFriendInLobby(lobby, peer)) acceptP2P(networking, peer);
        }
    }

    bool Send(SteamId id, const std::string& data) const {
        return sendP2P(networking, id, data.data(), static_cast<unsigned int>(data.size()), kP2PSendReliable, kP2PChannel);
    }

    bool Receive(SteamId& sender, std::string& data) const {
        unsigned int size = 0;
        if (!isP2PAvailable(networking, &size, kP2PChannel) || !size) return false;
        if (size > kMaxProfileBytes + 64) {
            throw std::runtime_error("Received oversized Steam P2P packet; aborting without processing");
        }
        std::vector<char> buffer(size);
        unsigned int read = 0;
        if (!readP2P(networking, buffer.data(), size, &read, &sender, kP2PChannel) || !read) return false;
        data.assign(buffer.data(), read);
        return true;
    }

    void Pump() const { runCallbacks(); }
};

struct Options {
    std::string mode;
    std::string expectedVersion;
    fs::path isaacRoot;
    fs::path resyncScript;
    fs::path gameLogPath;
    fs::path sessionRoot;
    fs::path profilePath;
    fs::path logPath;
    DWORD gamePid = 0;
    SteamId lobbyId = 0;
    int timeoutSeconds = 1800;
};

static std::string NarrowAscii(const wchar_t* value) {
    std::string result;
    while (*value) {
        if (*value > 0x7f) throw std::runtime_error("Mode must be ASCII");
        result.push_back(static_cast<char>(*value++));
    }
    return result;
}

static Options Parse(int argc, wchar_t** argv) {
    Options result;
    for (int i = 1; i < argc; ++i) {
        const std::wstring key = argv[i];
        if (key == L"--mode" && i + 1 < argc) result.mode = NarrowAscii(argv[++i]);
        else if (key == L"--expected-version" && i + 1 < argc) result.expectedVersion = NarrowAscii(argv[++i]);
        else if (key == L"--resync-script" && i + 1 < argc) result.resyncScript = argv[++i];
        else if (key == L"--game-log" && i + 1 < argc) result.gameLogPath = argv[++i];
        else if (key == L"--isaac-root" && i + 1 < argc) result.isaacRoot = argv[++i];
        else if (key == L"--session" && i + 1 < argc) result.sessionRoot = argv[++i];
        else if (key == L"--profile" && i + 1 < argc) result.profilePath = argv[++i];
        else if (key == L"--log" && i + 1 < argc) result.logPath = argv[++i];
        else if (key == L"--game-pid" && i + 1 < argc) {
            const std::wstring value = argv[++i];
            if (value.empty() || value.size() > 10 || !std::all_of(value.begin(), value.end(), [](wchar_t ch) { return ch >= L'0' && ch <= L'9'; }))
                throw std::runtime_error("Invalid game PID");
            errno = 0;
            const unsigned long long parsed = _wcstoui64(value.c_str(), nullptr, 10);
            if (!parsed || parsed > (std::numeric_limits<DWORD>::max)() || errno == ERANGE) throw std::runtime_error("Invalid game PID");
            result.gamePid = static_cast<DWORD>(parsed);
        }
        else if (key == L"--lobby-id" && i + 1 < argc) {
            const std::wstring value = argv[++i];
            if (value.empty() || value.size() > 20 || !std::all_of(value.begin(), value.end(), [](wchar_t ch) { return ch >= L'0' && ch <= L'9'; })) {
                throw std::runtime_error("Invalid lobby ID");
            }
            errno = 0;
            result.lobbyId = _wcstoui64(value.c_str(), nullptr, 10);
            if (!result.lobbyId || errno == ERANGE) throw std::runtime_error("Invalid lobby ID");
        }
        else if (key == L"--timeout" && i + 1 < argc) result.timeoutSeconds = _wtoi(argv[++i]);
        else if (key == L"--help" || key == L"-h") {
            std::wcout << L"READ-ONLY: SteamModProfileBridge --mode inspect --isaac-root <Isaac> --game-pid <pid> --log <current log> [--timeout seconds]\n"
                          L"FREUND-TEST v" << kToolVersion << L": --mode host|client --isaac-root <Isaac> --session <TEMP session> --lobby-id <id> [--profile <host profile>] [--expected-version <version>]\n";
            std::wcout.flush();
            std::exit(0);
        } else {
            throw std::runtime_error("Unknown or incomplete command-line argument");
        }
    }
    if (result.mode == "inspect") {
        if (result.isaacRoot.empty() || result.logPath.empty() || !result.gamePid || !result.sessionRoot.empty() ||
            !result.profilePath.empty() || result.lobbyId) throw std::runtime_error("Inspect requires only --isaac-root --game-pid --log");
    } else if ((result.mode != "host" && result.mode != "client") || result.isaacRoot.empty() || result.sessionRoot.empty() || !result.lobbyId) {
        throw std::runtime_error("Required arguments: --mode host|client --isaac-root --session --lobby-id");
    }
    if (result.mode == "host" && result.profilePath.empty()) throw std::runtime_error("Host mode requires --profile");
    if (result.timeoutSeconds < 30 || result.timeoutSeconds > 86400) throw std::runtime_error("Timeout must be 30..86400 seconds");
    if (!result.expectedVersion.empty() && result.expectedVersion != kToolVersion) {
        throw std::runtime_error("Versionskonflikt: Runner erwartet v" + result.expectedVersion +
                                 ", Companion ist v" + kToolVersion + ". Kein Profil gesendet.");
    }
    return result;
}

static std::string ReadProfile(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Cannot open host profile");
    std::string data((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    if (data.empty() || data.size() + sizeof(kProfilePrefix) + 64 > kMaxProfileBytes || data.find("\"format\": \"isaac-mod-profile\"") == std::string::npos) {
        throw std::runtime_error("Host profile is empty, oversized, or invalid");
    }
    return data;
}

static std::string NewNonce() {
    unsigned char bytes[16]{};
    if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
        throw std::runtime_error("Secure random nonce generation failed");
    }
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (unsigned char byte : bytes) out << std::setw(2) << static_cast<unsigned int>(byte);
    return out.str();
}

// The log is only a hint, never a source of identity or authorization.
static SteamId ParseJoinedLobby(const std::string& line) {
    constexpr char prefix[] = "[INFO] - Successfully joined lobby ";
    if (line.rfind(prefix, 0) != 0) return 0;
    std::string value = line.substr(sizeof(prefix) - 1);
    if (!value.empty() && value.back() == '\r') value.pop_back();
    while (!value.empty() && value.back() == ' ') value.pop_back();
    if (value.size() < 10 || value.size() > 20 || !std::all_of(value.begin(), value.end(), [](unsigned char ch) { return ch >= '0' && ch <= '9'; })) return 0;
    errno = 0;
    const SteamId id = std::strtoull(value.c_str(), nullptr, 10);
    return errno == ERANGE ? 0 : id;
}

class GameHandle {
    HANDLE handle_ = nullptr;
public:
    GameHandle(DWORD pid, const fs::path& root) {
        handle_ = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
        if (!handle_) throw std::runtime_error("Cannot open the specified Isaac process");
        wchar_t path[32768]{};
        DWORD length = static_cast<DWORD>(sizeof(path) / sizeof(path[0]));
        std::error_code ec;
        const auto expected = root / L"Repentogon" / L"isaac-ng.exe";
        if (!QueryFullProcessImageNameW(handle_, 0, path, &length) || !fs::equivalent(path, expected, ec) || ec) {
            CloseHandle(handle_); handle_ = nullptr;
            throw std::runtime_error("PID is not the expected REPENTOGON game executable");
        }
        if (WaitForSingleObject(handle_, 0) != WAIT_TIMEOUT) {
            CloseHandle(handle_); handle_ = nullptr;
            throw std::runtime_error("Isaac process is not running");
        }
    }
    GameHandle(const GameHandle&) = delete;
    GameHandle& operator=(const GameHandle&) = delete;
    ~GameHandle() { if (handle_) CloseHandle(handle_); }
    bool Running() const { return WaitForSingleObject(handle_, 0) == WAIT_TIMEOUT; }
};

// Read only new bytes after attachment. Detect truncation, replacement, and
// changed preceding bytes. A missed event is preferable to using an old lobby.
class FreshLogReader {
    fs::path path_;
    bool initial_ = true;
    bool haveFile_ = false;
    DWORD volume_ = 0, indexHigh_ = 0, indexLow_ = 0;
    unsigned long long offset_ = 0;
    std::string sample_, partial_;

    static std::string ReadAt(HANDLE file, unsigned long long offset, DWORD bytes) {
        LARGE_INTEGER pos{}; pos.QuadPart = static_cast<LONGLONG>(offset);
        if (!SetFilePointerEx(file, pos, nullptr, FILE_BEGIN)) throw std::runtime_error("Cannot seek game log");
        std::string out(bytes, '\0');
        DWORD read = 0;
        if (bytes && (!ReadFile(file, out.data(), bytes, &read, nullptr) || read != bytes)) throw std::runtime_error("Game log changed while reading");
        return out;
    }
    void RememberSample(HANDLE file) {
        const DWORD length = static_cast<DWORD>((std::min)(offset_, 256ULL));
        sample_ = ReadAt(file, offset_ - length, length);
    }
public:
    explicit FreshLogReader(fs::path path) : path_(std::move(path)) {}
    std::vector<std::string> Poll(bool& reset) {
        reset = false;
        std::vector<std::string> lines;
        HANDLE file = CreateFileW(path_.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) {
            const DWORD error = GetLastError();
            if (error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) throw std::runtime_error("Cannot open game log");
            if (haveFile_) reset = true;
            initial_ = false; haveFile_ = false; offset_ = 0; sample_.clear(); partial_.clear();
            return lines;
        }
        try {
            BY_HANDLE_FILE_INFORMATION info{};
            LARGE_INTEGER length{};
            if (GetFileType(file) != FILE_TYPE_DISK || !GetFileInformationByHandle(file, &info) || !GetFileSizeEx(file, &length) || length.QuadPart < 0)
                throw std::runtime_error("Cannot identify game log");
            const auto size = static_cast<unsigned long long>(length.QuadPart);
            const bool same = haveFile_ && info.dwVolumeSerialNumber == volume_ && info.nFileIndexHigh == indexHigh_ && info.nFileIndexLow == indexLow_;
            if (initial_) {
                // Existing bytes belong to an unknown earlier period, even if a
                // stale lobby ID is still accepted by Steam.
                offset_ = size;
                initial_ = false;
            } else if (!same || size < offset_ || (!sample_.empty() && ReadAt(file, offset_ - sample_.size(), static_cast<DWORD>(sample_.size())) != sample_)) {
                reset = haveFile_;
                offset_ = 0; partial_.clear(); sample_.clear();
            }
            haveFile_ = true;
            volume_ = info.dwVolumeSerialNumber; indexHigh_ = info.nFileIndexHigh; indexLow_ = info.nFileIndexLow;
            const DWORD bytes = static_cast<DWORD>((std::min)(size - offset_, 65536ULL));
            partial_ += ReadAt(file, offset_, bytes);
            offset_ += bytes;
            RememberSample(file);
            size_t newline;
            while ((newline = partial_.find('\n')) != std::string::npos) {
                if (newline > 65536) throw std::runtime_error("Oversized game log line");
                lines.push_back(partial_.substr(0, newline));
                partial_.erase(0, newline + 1);
            }
            if (partial_.size() > 65536) throw std::runtime_error("Oversized game log line");
        } catch (...) { CloseHandle(file); throw; }
        CloseHandle(file);
        return lines;
    }
};

struct LobbySnapshot {
    SteamId self = 0, owner = 0;
    std::vector<SteamId> members;
    std::vector<SteamId> friends;
};

static bool ReadStableLobby(SteamApi& steam, SteamId lobby, LobbySnapshot& result) {
    const SteamId self = steam.userSteamId(steam.user);
    const SteamId owner = steam.lobbyOwner(steam.matchmaking, lobby);
    const int count = steam.lobbyCount(steam.matchmaking, lobby);
    auto members = steam.LobbyMembers(lobby);
    auto next = steam.LobbyMembers(lobby);
    std::sort(members.begin(), members.end());
    std::sort(next.begin(), next.end());
    if (!self || !owner || count < 1 || count > 250 || members.size() != static_cast<size_t>(count) ||
        steam.lobbyCount(steam.matchmaking, lobby) != count || members != next ||
        std::adjacent_find(members.begin(), members.end()) != members.end() ||
        !std::binary_search(members.begin(), members.end(), self) ||
        !std::binary_search(members.begin(), members.end(), owner) ||
        steam.userSteamId(steam.user) != self || steam.lobbyOwner(steam.matchmaking, lobby) != owner) return false;
    result = {};
    result.self = self; result.owner = owner; result.members = members;
    for (SteamId peer : members) {
        if (peer != self && steam.hasFriend(steam.friends, peer, kFriendFlagImmediate)) result.friends.push_back(peer);
    }
    return true;
}

static void PrintLobby(const char* event, SteamId lobby, const LobbySnapshot& state) {
    std::cout << "{\"event\":\"" << event << "\",\"lobby\":\"" << lobby
              << "\",\"role\":\"" << (state.owner == state.self ? "host" : "client")
              << "\",\"owner\":\"" << state.owner << "\",\"members\":[";
    bool first = true;
    for (SteamId id : state.members) {
        if (!first) std::cout << ',';
        first = false;
        const bool isFriend = std::find(state.friends.begin(), state.friends.end(), id) != state.friends.end();
        std::cout << "{\"id\":\"" << id << "\",\"self\":" << (id == state.self ? "true" : "false")
                  << ",\"friend\":" << (isFriend ? "true" : "false") << '}';
    }
    std::cout << "]}" << std::endl;
}

static int InspectLoop(const Options& options, SteamApi& steam, const GameHandle& game, FreshLogReader& log) {
    SteamId candidate = 0;
    bool verified = false;
    LobbySnapshot previous;
    ULONGLONG seenAt = 0;
    const ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(options.timeoutSeconds) * 1000;
    std::cout << "{\"event\":\"watching\",\"read_only\":true}" << std::endl;
    while (game.Running() && GetTickCount64() < deadline) {
        steam.Pump();
        bool reset = false;
        const auto lines = log.Poll(reset);
        if (reset) {
            if (verified) std::cout << "{\"event\":\"lobby_invalidated\",\"reason\":\"log_changed\"}" << std::endl;
            candidate = 0; verified = false;
        }
        for (const auto& line : lines) {
            const SteamId joined = ParseJoinedLobby(line);
            if (!joined) continue;
            if (verified) std::cout << "{\"event\":\"lobby_invalidated\",\"reason\":\"new_join\"}" << std::endl;
            candidate = joined; verified = false; seenAt = GetTickCount64();
        }
        if (candidate) {
            LobbySnapshot current;
            if (ReadStableLobby(steam, candidate, current)) {
                if (!verified || previous.self != current.self || previous.owner != current.owner || previous.members != current.members || previous.friends != current.friends) {
                    PrintLobby("lobby_verified", candidate, current);
                    previous = current;
                }
                verified = true;
            } else if (verified || GetTickCount64() - seenAt > 15000) {
                std::cout << "{\"event\":\"lobby_invalidated\",\"reason\":\"membership_unverified\"}" << std::endl;
                candidate = 0; verified = false;
            }
        }
        Sleep(250);
    }
    std::cout << "{\"event\":\"stopped\",\"reason\":\"" << (game.Running() ? "timeout" : "game_exited") << "\"}" << std::endl;
    return 0;
}

// Chunked lobby-data fallback: P2P packets can be delayed by NAT/firewalls
// while lobby data is replicated reliably by Steam to all members.
constexpr size_t kProfileChunkBytes = 800;

static void WriteProfileToLobbyData(const Options& options, SteamApi& steam, const std::string& profile) {
    if (!steam.setLobbyData) return;
    steam.Pump();
    const size_t chunks = (profile.size() + kProfileChunkBytes - 1) / kProfileChunkBytes;
    char key[64] = {};
    char index[16] = {};
    for (size_t i = 0; i < chunks; ++i) {
        std::snprintf(key, sizeof(key), "modsync_p_%03zu", i);
        const std::string value = profile.substr(i * kProfileChunkBytes, kProfileChunkBytes);
        steam.setLobbyData(steam.matchmaking, options.lobbyId, key, value.c_str());
        steam.Pump();
    }
    std::snprintf(index, sizeof(index), "%zu", chunks);
    steam.setLobbyData(steam.matchmaking, options.lobbyId, "modsync_profile_chunks", index);
    steam.setLobbyData(steam.matchmaking, options.lobbyId, "modsync_profile_version", kToolVersion);
    steam.Pump();
    std::cout << "Host-Profil in Lobby-Data geschrieben (" << chunks << " Chunks).\n";
}

static bool ReadProfileFromLobbyData(const Options& options, SteamApi& steam, std::string& profile) {
    if (!steam.getLobbyData) return false;
    steam.Pump();
    const char* version = steam.getLobbyData(steam.matchmaking, options.lobbyId, "modsync_profile_version");
    if (!version || std::string(version) != kToolVersion) return false;
    const char* countText = steam.getLobbyData(steam.matchmaking, options.lobbyId, "modsync_profile_chunks");
    if (!countText) return false;
    const int count = std::atoi(countText);
    if (count < 1 || count > 2048) return false;
    std::string joined;
    char key[64] = {};
    for (int i = 0; i < count; ++i) {
        std::snprintf(key, sizeof(key), "modsync_p_%03d", i);
        const char* chunk = steam.getLobbyData(steam.matchmaking, options.lobbyId, key);
        if (!chunk || !*chunk) return false;
        joined += chunk;
    }
    if (joined.find("\"format\": \"isaac-mod-profile\"") == std::string::npos) return false;
    profile = std::move(joined);
    return true;
}

static int HostLoop(const Options& options, SteamApi& steam) {
    const std::string profile = ReadProfile(options.profilePath);
    // Publish once at start AND on every loop: a friend who joins 1-5 s later
    // sees the complete profile immediately via lobby data.
    WriteProfileToLobbyData(options, steam, profile);
    std::unordered_map<SteamId, std::string> readyPeers;
    std::unordered_map<SteamId, std::string> ackNonces;
    std::unordered_map<SteamId, DWORD> lastSend;
    const DWORD start = GetTickCount();
    std::cout << "Host bridge wartet auf Client-READY in derselben privaten Lobby.\n";
    CheckLogForDesync(options);

    while ((GetTickCount() - start) < static_cast<DWORD>(options.timeoutSeconds) * 1000) {
        steam.Pump();
        const SteamId self = steam.userSteamId(steam.user);
        if (!steam.IsLobbyMember(options.lobbyId, self) || steam.lobbyOwner(steam.matchmaking, options.lobbyId) != self) {
            ShowP2PFailure(options, L"Unerwarteter Lobby-Abbruch (Host)");
            throw std::runtime_error("Host ist kein Mitglied/Eigentuemer der verifizierten Lobby; kein Profil gesendet.");
        }
        steam.AcceptLobbyFriends(options.lobbyId);
        SteamId sender = 0;
        std::string data;
        while (steam.Receive(sender, data)) {
            if (!steam.IsFriendInLobby(options.lobbyId, sender)) continue;
            if (data.rfind(kReadyPrefix, 0) == 0) {
                const std::string nonce = data.substr(sizeof(kReadyPrefix) - 1);
                if (nonce.size() != 32 || !std::all_of(nonce.begin(), nonce.end(), [](unsigned char ch) {
                    return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');
                })) continue;
                if (!readyPeers.count(sender) || readyPeers[sender] != nonce) {
                    readyPeers[sender] = nonce;
                    ackNonces.erase(sender);
                    lastSend.erase(sender);
                }
                std::cout << "Wartender Steam-Freund erkannt: " << steam.FriendName(sender) << "\n";
            } else if (data.rfind(kAckPrefix, 0) == 0 && readyPeers.count(sender)) {
                const std::string nonce = data.substr(sizeof(kAckPrefix) - 1);
                if (readyPeers[sender] == nonce) {
                    ackNonces[sender] = nonce;
                    std::cout << "Profilbestaetigung von Steam-Freund erhalten: " << steam.FriendName(sender) << "\n";
                }
            }
        }
        for (const auto& [peer, nonce] : readyPeers) {
            if (!steam.IsFriendInLobby(options.lobbyId, peer)) continue;
            if (ackNonces.count(peer) && ackNonces[peer] == nonce) continue;
            const DWORD now = GetTickCount();
            if (lastSend.count(peer) && now - lastSend[peer] < 3000) continue;
            const std::string packet = std::string(kProfilePrefix) + nonce + "\n" + profile;
            if (steam.Send(peer, packet)) {
                lastSend[peer] = now;
                std::cout << "Host-Profil an wartendes Lobby-Mitglied gesendet: " << steam.FriendName(peer) << "\n";
            }
        }
        // Re-publish periodically so a late joiner still finds all chunks.
        {
            static DWORD lastPublish = 0;
            const DWORD now = GetTickCount();
            if (now - lastPublish > 5000) {
                WriteProfileToLobbyData(options, steam, profile);
                lastPublish = now;
            }
        }
        Sleep(250);
    }
    return 0;
}

static int ClientLoop(const Options& options, SteamApi& steam) {
    const fs::path output = options.sessionRoot / L"received-host-profile.json";
    const fs::path senderPath = options.sessionRoot / L"received-host-profile-sender.txt";
    const std::string nonce = NewNonce();
    const std::string ready = std::string(kReadyPrefix) + nonce;
    const DWORD start = GetTickCount();
    DWORD lastReady = 0;
    std::cout << "Client bridge wartet auf das Profil des Lobby-Eigentuemers.\n";
    CheckLogForDesync(options);

    while ((GetTickCount() - start) < static_cast<DWORD>(options.timeoutSeconds) * 1000) {
        steam.Pump();
        const SteamId self = steam.userSteamId(steam.user);
        const SteamId owner = steam.lobbyOwner(steam.matchmaking, options.lobbyId);
        if (!steam.IsLobbyMember(options.lobbyId, self) || owner == self || !steam.IsFriendInLobby(options.lobbyId, owner)) {
            throw std::runtime_error("Lobby-Mitgliedschaft oder Freund-Host nicht verifiziert; keine Anfrage gesendet.");
        }
        steam.AcceptLobbyFriends(options.lobbyId);
        const DWORD now = GetTickCount();
        if (!lastReady || now - lastReady >= 5000) {
            steam.Send(owner, ready);
            lastReady = now;
        }

        // Lobby-data fallback first: independent of P2P/NAT timing.
        std::string lobbyProfile;
        if (ReadProfileFromLobbyData(options, steam, lobbyProfile)) {
            {
                std::ofstream file(output, std::ios::binary | std::ios::trunc);
                if (file) file.write(lobbyProfile.data(), static_cast<std::streamsize>(lobbyProfile.size()));
            }
            {
                std::ofstream file(senderPath, std::ios::binary | std::ios::trunc);
                file << owner << "\n" << steam.FriendName(owner) << "\n(lobby-data)\n";
            }
            std::cout << "Host-Profil via Lobby-Data empfangen.\n";
            return 0;
        }

        SteamId sender = 0;
        std::string data;
        while (steam.Receive(sender, data)) {
            if (sender != owner || steam.lobbyOwner(steam.matchmaking, options.lobbyId) != owner ||
                !steam.IsLobbyMember(options.lobbyId, self) || !steam.IsFriendInLobby(options.lobbyId, owner)) continue;
            if (data.rfind(kProfilePrefix, 0) != 0) continue;
            const size_t newline = data.find('\n', sizeof(kProfilePrefix) - 1);
            if (newline == std::string::npos) continue;
            const std::string profileNonce = data.substr(sizeof(kProfilePrefix) - 1, newline - (sizeof(kProfilePrefix) - 1));
            if (profileNonce != nonce) continue;
            const std::string payload = data.substr(newline + 1);
            if (payload.empty() || payload.size() > kMaxProfileBytes ||
                payload.find("\"format\": \"isaac-mod-profile\"") == std::string::npos) {
                std::cerr << "Host-Profil von " << steam.FriendName(sender) << " verworfen: Format/Laenge ungueltig.\n";
                continue;
            }
            const fs::path temporary = output.wstring() + L".tmp";
            {
                std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
                if (!file) throw std::runtime_error("Cannot create received profile temp file");
                file.write(payload.data(), static_cast<std::streamsize>(payload.size()));
                file.flush();
                if (!file) throw std::runtime_error("Cannot write received profile temp file");
            }
            fs::rename(temporary, output);
            {
                std::ofstream file(senderPath, std::ios::binary | std::ios::trunc);
                file << sender << "\n" << steam.FriendName(sender) << "\n";
            }
            steam.Send(sender, std::string(kAckPrefix) + nonce);
            std::cout << "Host-Profil empfangen.\n";
            return 0;
        }
        Sleep(250);
    }
    ShowP2PFailure(options, L"P2P-Timeout: kein Host-Profil empfangen");
    throw std::runtime_error("Timeout: kein Host-Profil empfangen; keine Mods wurden gestaged.");
}

static bool HasVerifiedLobbyBinding() {
    // Closed friend test v0.0.6: the runner passes a --lobby-id read from the
    // live game log and enforces the two-sided version check. HostLoop and
    // ClientLoop re-verify lobby ownership/membership on every Steam callback
    // before any profile packet is sent, so the binding stays fail-closed if
    // the log ID is stale or the peer is not a friend in that lobby.
    return true;
}

static int __cdecl TestLobbyCount(void*, SteamId lobby) { return lobby == 123 ? 2 : 0; }
static SteamId __cdecl TestLobbyMember(void*, SteamId lobby, int index) {
    if (lobby != 123) return 0;
    return index == 0 ? 111 : (index == 1 ? 222 : 0);
}
static bool __cdecl TestHasFriend(void*, SteamId id, int) { return id == 222 || id == 333; }
static SteamId __cdecl TestSelf(void*) { return 111; }
static SteamId __cdecl TestOwner(void*, SteamId lobby) { return lobby == 123 ? 111 : 0; }
static SteamId __cdecl TestMissingOwner(void*, SteamId) { return 444; }

static void TestFreshLogReader() {
    const auto dir = fs::temp_directory_path() / (L"modsync-lobby-selftest-" + fs::path(NewNonce()).wstring());
    if (!fs::create_directory(dir)) throw std::runtime_error("Cannot create log self-test directory");
    const auto path = dir / L"log.txt";
    const auto old = dir / L"old.txt";
    try {
        { std::ofstream out(path, std::ios::binary); out << "[INFO] - Successfully joined lobby 109775245124237587\n"; }
        FreshLogReader reader(path);
        bool reset = false;
        if (!reader.Poll(reset).empty() || reset) throw std::runtime_error("Stale log was read");
        { std::ofstream out(path, std::ios::binary | std::ios::app); out << "[INFO] - Successfully joined lobby 109775245"; }
        if (!reader.Poll(reset).empty()) throw std::runtime_error("Partial line was read");
        { std::ofstream out(path, std::ios::binary | std::ios::app); out << "124237588\n"; }
        const auto lines = reader.Poll(reset);
        if (lines.size() != 1 || ParseJoinedLobby(lines[0]) != 109775245124237588ULL) throw std::runtime_error("Fresh join not detected");
        fs::rename(path, old);
        { std::ofstream out(path, std::ios::binary); out << "[INFO] - Successfully joined lobby 109775245124237589\n"; }
        const auto replaced = reader.Poll(reset);
        if (!reset || replaced.size() != 1 || ParseJoinedLobby(replaced[0]) != 109775245124237589ULL) throw std::runtime_error("Log replacement not detected");
        fs::remove(path); fs::remove(old); fs::remove(dir);
    } catch (...) {
        std::error_code ec;
        fs::remove(path, ec); fs::remove(old, ec); fs::remove(dir, ec);
        throw;
    }
}

static int OfflineLobbyFilterSelfTest() {
    SteamApi steam;
    steam.lobbyCount = TestLobbyCount;
    steam.lobbyMember = TestLobbyMember;
    steam.hasFriend = TestHasFriend;
    steam.userSteamId = TestSelf;
    steam.lobbyOwner = TestOwner;
    if (!steam.IsLobbyMember(123, 111) || !steam.IsFriendInLobby(123, 222) ||
        steam.IsFriendInLobby(123, 333) || steam.IsFriendInLobby(123, 111) ||
        steam.IsFriendInLobby(456, 222)) {
        std::cerr << "Offline lobby-membership filter self-test failed.\n";
        return 1;
    }
    LobbySnapshot snapshot;
    if (!ReadStableLobby(steam, 123, snapshot) || snapshot.self != 111 || snapshot.owner != 111 ||
        snapshot.members != std::vector<SteamId>{111, 222} || snapshot.friends != std::vector<SteamId>{222})
        throw std::runtime_error("Stable lobby snapshot self-test failed");
    steam.lobbyOwner = TestMissingOwner;
    if (ReadStableLobby(steam, 123, snapshot)) throw std::runtime_error("Missing owner was accepted");
    if (ParseJoinedLobby("[INFO] - Successfully joined lobby 109775245124237587") != 109775245124237587ULL ||
        ParseJoinedLobby("[INFO] - Lua Debug: Successfully joined lobby 109775245124237587") ||
        ParseJoinedLobby("[INFO] - Successfully joined lobby 18446744073709551616") ||
        ParseJoinedLobby("[INFO] - Successfully joined lobby 123")) throw std::runtime_error("Lobby log parser self-test failed");
    TestFreshLogReader();
    std::cout << "Offline lobby membership, log and stale-data self-tests passed; no Steam API used.\n";
    return 0;
}

// === Isaac Desync Assistant ===
struct DesyncFinding {
    bool found = false;
    std::wstring reason;
    std::wstring detail;
    std::wstring affected;
};

static std::wstring Widen(const std::string& value) {
    return std::wstring(value.begin(), value.end());
}

static std::string ReadLogTail(const fs::path& path, size_t limit) {
    std::ifstream input(path, std::ios::binary);
    if (!input) return "";
    input.seekg(0, std::ios::end);
    const auto size = static_cast<size_t>(input.tellg());
    input.seekg(size > limit ? size - limit : 0, std::ios::beg);
    return std::string((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
}

static fs::path DefaultGameLog() {
    wchar_t* profile = nullptr;
    if (!SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Documents, 0, nullptr, &profile)) || !profile) {
        return fs::path();
    }
    const fs::path result = fs::path(profile) / L"My Games" / L"Binding of Isaac Repentance+" / L"log.txt";
    CoTaskMemFree(profile);
    return result;
}

static DesyncFinding AnalyzeLogForDesync(const fs::path& logPath) {
    DesyncFinding finding;
    const std::string text = ReadLogTail(logPath, 256 * 1024);
    size_t cursor = 0;
    while (cursor < text.size()) {
        size_t end = text.find('\n', cursor);
        if (end == std::string::npos) end = text.size();
        const std::string line = text.substr(cursor, end - cursor);
        cursor = end + 1;
        auto field = [&line](const char* key) -> std::wstring {
            const std::string marker(key);
            const size_t at = line.find(marker);
            if (at == std::string::npos) return L"";
            const size_t start = at + marker.size();
            size_t stop = line.find(' ', start);
            if (stop == std::string::npos) stop = line.size();
            return Widen(line.substr(start, stop - start));
        };
        if (line.find("[modsync-desync] reason=mod-load-order") != std::string::npos) {
            finding = {true, L"Abweichende Mod-Ladereihenfolge", Widen(line), field("affected=")};
        } else if (line.find("[modsync-desync] reason=room-transition") != std::string::npos) {
            finding = {true, L"Spiel-Bug beim Raumwechsel", Widen(line), L"Raum-/Level-Zustand"};
        } else if (line.find("[modsync-lobby] lobby-menu-exit=") != std::string::npos) {
            finding = {true, L"Lobby verlassen - moeglicher unerwarteter Abbruch", Widen(line), L"Steam-Freund-Lobby"};
        } else if (line.find("Versionskonflikt") != std::string::npos || line.find("Hash-Mismatch") != std::string::npos) {
            finding = {true, L"Versions- oder Hash-Unterschied", Widen(line), L"Host-Profil / Companion"};
        }
    }
    return finding;
}

static const DesyncFinding* g_desyncFinding = nullptr;
static const Options* g_desyncOptions = nullptr;

static std::wstring Quoted(const std::wstring& value) { return L"\"" + value + L"\""; }

static void LaunchResync() {
    if (!g_desyncOptions) return;
    const Options& options = *g_desyncOptions;
    fs::path script = options.resyncScript;
    if (script.empty()) script = options.isaacRoot / L"Resync-ProfileAndSaveData.ps1";
    fs::path profile = options.profilePath;
    if (profile.empty()) profile = options.sessionRoot / L"received-host-profile.json";
    std::wstring parameters = L"-NoProfile -ExecutionPolicy Bypass -File " + Quoted(script.wstring())
        + L" -IsaacRoot " + Quoted(options.isaacRoot.wstring())
        + L" -Profile " + Quoted(profile.wstring());
    ShellExecuteW(nullptr, L"open", L"powershell.exe", parameters.c_str(), nullptr, SW_SHOWNORMAL);
}

static INT_PTR CALLBACK DesyncDialogProc(HWND window, UINT message, WPARAM wParam, LPARAM) {
    if (message == WM_INITDIALOG) {
        SetDlgItemTextW(window, kIdcDesyncReason, g_desyncFinding ? g_desyncFinding->reason.c_str() : L"Unbekannter Desync");
        SetDlgItemTextW(window, kIdcDesyncDetail, g_desyncFinding ? g_desyncFinding->detail.c_str() : L"");
        SetDlgItemTextW(window, kIdcDesyncAffected, g_desyncFinding ? g_desyncFinding->affected.c_str() : L"");
        return TRUE;
    }
    if (message == WM_COMMAND) {
        if (LOWORD(wParam) == kIdcResync) { LaunchResync(); EndDialog(window, 1); return TRUE; }
        if (LOWORD(wParam) == kIdcDismiss) { EndDialog(window, 2); return TRUE; }
    }
    if (message == WM_CLOSE) { EndDialog(window, 2); return TRUE; }
    return FALSE;
}

static void ShowDesyncAssistant(const DesyncFinding& finding, const Options& options) {
    g_desyncFinding = &finding;
    g_desyncOptions = &options;
    DialogBoxParamW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(kDialogDesyncAssistant),
                    nullptr, DesyncDialogProc, 0);
}

static void ShowP2PFailure(const Options& options, const wchar_t* reason) {
    DesyncFinding finding;
    finding.found = true;
    finding.reason = reason;
    finding.detail = L"Steam-P2P-Verbindung oder Lobby-Sitzung wurde unerwartet beendet.";
    finding.affected = L"Steam-P2P-Companion / Freund-Lobby";
    ShowDesyncAssistant(finding, options);
}

static void CheckLogForDesync(const Options& options) {
    const fs::path log = options.gameLogPath.empty() ? DefaultGameLog() : options.gameLogPath;
    if (log.empty()) return;
    const DesyncFinding finding = AnalyzeLogForDesync(log);
    if (finding.found) ShowDesyncAssistant(finding, options);
}

static int OfflineDesyncAssistantSelfTest() {
    const fs::path dir = fs::temp_directory_path() / (L"modsync-desync-selftest-" + fs::path(NewNonce()).wstring());
    fs::create_directories(dir);
    const fs::path log = dir / L"log.txt";
    try {
        {
            std::ofstream out(log, std::ios::binary | std::ios::trunc);
            out << "[INFO] - Lua Debug: [modsync-lobby] lobby-menu-enter=17\n";
            out << "[modsync-desync] reason=mod-load-order severity=critical affected=alpha_101 checksum=deadbeef\n";
        }
        const DesyncFinding finding = AnalyzeLogForDesync(log);
        if (!finding.found || finding.reason != L"Abweichende Mod-Ladereihenfolge" || finding.affected != L"alpha_101") {
            throw std::runtime_error("Desync log analysis self-test failed");
        }
        {
            std::ofstream out(log, std::ios::binary | std::ios::trunc);
            out << "[modsync-desync] reason=room-transition signature=1/2/3 pool=abc\n";
        }
        const DesyncFinding room = AnalyzeLogForDesync(log);
        if (!room.found || room.reason != L"Spiel-Bug beim Raumwechsel") {
            throw std::runtime_error("Room transition analysis self-test failed");
        }
    } catch (...) {
        fs::remove_all(dir);
        throw;
    }
    fs::remove_all(dir);
    std::cout << "Offline Desync Assistant log-analysis self-tests passed; no Steam API used.\n";
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc == 2 && std::wstring(argv[1]) == L"--selftest") return OfflineLobbyFilterSelfTest();
        if (argc == 2 && std::wstring(argv[1]) == L"--desync-selftest") return OfflineDesyncAssistantSelfTest();
        const Options options = Parse(argc, argv);
        if (options.mode == "inspect") {
            GameHandle game(options.gamePid, options.isaacRoot);
            FreshLogReader log(options.logPath);
            bool ignored = false;
            log.Poll(ignored); // establish baseline before Steam initialization
            SteamApi steam;
            steam.Init(options.isaacRoot, true);
            return InspectLoop(options, steam, game, log);
        }
        // Freigabe nur mit gueltiger Lobby-ID aus dem Spiel-Log und bestandenem
        // Versions-Check (Parse prueft --expected-version gegen kToolVersion).
        if (!options.lobbyId || !HasVerifiedLobbyBinding()) {
            std::cerr << "Kein verifizierter Lobby-Transfer: Lobby-ID fehlt oder Version passt nicht.\n";
            return 2;
        }
        SteamApi steam;
        steam.Init(options.isaacRoot);
        {
            std::ofstream ready(options.sessionRoot / L"steam-bridge.ready", std::ios::binary | std::ios::trunc);
            if (!ready) throw std::runtime_error("Cannot create Steam bridge ready marker");
            ready << "ready\n";
            std::ofstream version(options.sessionRoot / L"steam-bridge.version", std::ios::binary | std::ios::trunc);
            if (!version) throw std::runtime_error("Cannot create Steam bridge version marker");
            version << kToolVersion << "\n";
        }
        std::cout << "Steam-P2P-Companion v" << kToolVersion << " aktiv (Lobby " << options.lobbyId << ").\n";
        return options.mode == "host" ? HostLoop(options, steam) : ClientLoop(options, steam);
    } catch (const std::exception& error) {
        std::cerr << "SteamModProfileBridge: " << error.what() << "\n";
        return 2;
    }
}
