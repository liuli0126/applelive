// Portable entry shared by the top-level button and the original OBS executable.
// No capture/encoder code belongs here: prepare the local profile, make the dock
// reachable, then resume OBS so CEF's first navigation cannot race the server.
#include <winsock2.h>
#include <windows.h>
#include <tlhelp32.h>
#include <shellapi.h>
#include <filesystem>
#include <string>
#include <vector>
#include <stdexcept>
#include <cwctype>
namespace fs = std::filesystem;

static std::wstring quote(const std::wstring &value) {
    std::wstring out = L"\"";
    size_t slashes = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') { ++slashes; continue; }
        out.append(slashes * (ch == L'\"' ? 2 : 1), L'\\');
        slashes = 0;
        if (ch == L'\"') out += L'\\';
        out += ch;
    }
    out.append(slashes * 2, L'\\');
    return out + L"\"";
}
static fs::path executable() {
    std::vector<wchar_t> buffer(32768);
    DWORD n = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (!n || n == buffer.size()) throw std::runtime_error("executable path");
    return fs::path(std::wstring(buffer.data(), n));
}
static unsigned short port(const wchar_t *key, unsigned short fallback) {
    wchar_t value[16]{};
    if (!GetEnvironmentVariableW(key, value, 16)) return fallback;
    int parsed = _wtoi(value);
    return parsed > 1024 && parsed < 65536 ? static_cast<unsigned short>(parsed) : fallback;
}
static DWORD find_process(const fs::path &file) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry{sizeof(entry)};
    DWORD found = 0;
    if (Process32FirstW(snapshot, &entry)) do {
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
        if (!process) continue;
        wchar_t path[32768]; DWORD size = 32768;
        if (QueryFullProcessImageNameW(process, 0, path, &size) &&
            _wcsicmp(path, file.c_str()) == 0) found = entry.th32ProcessID;
        CloseHandle(process);
        if (found) break;
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return found;
}
static BOOL CALLBACK focus_window(HWND window, LPARAM pid) {
    DWORD owner = 0; GetWindowThreadProcessId(window, &owner);
    if (owner == static_cast<DWORD>(pid) && IsWindowVisible(window) && !GetWindow(window, GW_OWNER)) {
        ShowWindow(window, SW_RESTORE); SetForegroundWindow(window); return FALSE;
    }
    return TRUE;
}
struct WindowBrand { DWORD pid; HICON icon; };
static BOOL CALLBACK brand_window(HWND window, LPARAM value) {
    auto context = reinterpret_cast<WindowBrand *>(value);
    DWORD pid=0; GetWindowThreadProcessId(window,&pid);
    if (pid != context->pid || !IsWindowVisible(window) || GetWindow(window,GW_OWNER)) return TRUE;
    wchar_t title[2048]{}, className[128]{};
    GetWindowTextW(window,title,2048); GetClassNameW(window,className,128);
    if (wcsncmp(className,L"Qt",2) != 0) return TRUE;
    std::wstring text(title);
    if (text.rfind(L"OBS ",0)==0) { text=L"福煋OBS"+text.substr(3); SetWindowTextW(window,text.c_str()); }
    if (text.rfind(L"福煋OBS",0)!=0) return TRUE;
    DWORD_PTR result=0;
    SendMessageTimeoutW(window,WM_SETICON,ICON_BIG,reinterpret_cast<LPARAM>(context->icon),SMTO_ABORTIFHUNG,200,&result);
    SendMessageTimeoutW(window,WM_SETICON,ICON_SMALL,reinterpret_cast<LPARAM>(context->icon),SMTO_ABORTIFHUNG,200,&result);
    return TRUE;
}
static bool free_port(unsigned short number) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;
    BOOL exclusive = TRUE;
    setsockopt(s, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, reinterpret_cast<char *>(&exclusive), sizeof(exclusive));
    sockaddr_in addr{}; addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = htons(number);
    bool ok = bind(s, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0;
    closesocket(s); return ok;
}
static bool dock_ready(unsigned short number) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return false;
    DWORD timeout = 300;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char *>(&timeout), sizeof(timeout));
    sockaddr_in addr{}; addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = htons(number);
    bool ready = false;
    if (connect(s, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0) {
        std::string request = "GET / HTTP/1.1\r\nHost: 127.0.0.1:" + std::to_string(number) + "\r\nConnection: close\r\n\r\n";
        send(s, request.data(), static_cast<int>(request.size()), 0);
        char response[128]{};
        int n = recv(s, response, sizeof(response)-1, 0);
        ready = n > 12 && std::string(response, n).find(" 200 ") != std::string::npos;
    }
    closesocket(s); return ready;
}
static PROCESS_INFORMATION launch(const fs::path &file, const std::vector<std::wstring> &args,
                                  const fs::path &cwd, DWORD flags, HANDLE log = nullptr) {
    std::wstring command = quote(file.wstring());
    for (const auto &arg : args) command += L" " + quote(arg);
    STARTUPINFOW startup{sizeof(startup)};
    if (log) {
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdOutput = startup.hStdError = log;
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    }
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(file.c_str(), command.data(), nullptr, nullptr, log != nullptr,
                        flags, nullptr, cwd.c_str(), &startup, &process))
        throw std::runtime_error("CreateProcess");
    return process;
}
static void close_process(PROCESS_INFORMATION &process) {
    if (process.hThread) CloseHandle(process.hThread);
    if (process.hProcess) CloseHandle(process.hProcess);
    process = {};
}
static void fail(const std::wstring &message) {
    MessageBoxW(nullptr, message.c_str(), L"福煋OBS", MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    fs::path root, host;
    HANDLE mutex = nullptr, log = nullptr;
    PROCESS_INFORMATION obs{}, helper{};
    bool resumed = false, winsock = false;
    try {
        root = executable().parent_path();
        for (int i = 0; i < 4; ++i) {
            if (fs::is_regular_file(root / L"portable_mode.txt") &&
                fs::is_regular_file(root / L"bin/64bit/AppleLiveOBS.exe")) break;
            root = root.parent_path();
        }
        host = (root / L"bin/64bit/AppleLiveOBS.exe").make_preferred();
        fs::path plugin = root / L"data/obs-plugins/AppleLive";
        if (!fs::is_regular_file(host) || !fs::is_regular_file(plugin / L"install_or_update.ps1")) {
            fail(L"文件不完整。请将整个压缩包解压到本地文件夹，再打开福煋OBS.exe。"); return 1;
        }
        std::wstring normalized = root.wstring();
        unsigned long long hash = 14695981039346656037ull;
        for (wchar_t ch : normalized) { hash ^= towlower(ch); hash *= 1099511628211ull; }
        std::wstring key = L"Local\\AppleLiveStartup-" + std::to_wstring(hash);
        mutex = CreateMutexW(nullptr, FALSE, key.c_str());
        if (!mutex) throw std::runtime_error("mutex");
        if (WaitForSingleObject(mutex, 0) != WAIT_OBJECT_0) {
            if (DWORD pid = find_process(host)) EnumWindows(focus_window, static_cast<LPARAM>(pid));
            CloseHandle(mutex); return 0;
        }
        if (DWORD pid = find_process(host)) {
            EnumWindows(focus_window, static_cast<LPARAM>(pid)); CloseHandle(mutex); return 0;
        }
        WSADATA data{};
        if (WSAStartup(MAKEWORD(2,2), &data)) throw std::runtime_error("WSAStartup");
        winsock = true;
        auto dock = port(L"APPLELIVE_TEST_DOCK_PORT", 18765);
        auto control = port(L"APPLELIVE_TEST_CONTROL_PORT", 28766);
        if (!free_port(dock) || !free_port(control)) {
            fail(L"另一套 OBS 或 福煋OBS 正在运行。请先关闭它，再打开本文件夹中的福煋OBS.exe。");
            WSACleanup(); CloseHandle(mutex); return 2;
        }
        fs::create_directories(root / L"config");
        SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
        log = CreateFileW((root / L"config/applelive-startup.log").c_str(), GENERIC_WRITE,
                          FILE_SHARE_READ, &security, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (log == INVALID_HANDLE_VALUE) { log = nullptr; throw std::runtime_error("log path not writable"); }
        wchar_t system[MAX_PATH]; GetSystemDirectoryW(system, MAX_PATH);
        auto powershell = fs::path(system) / L"WindowsPowerShell/v1.0/powershell.exe";
        auto prepare = launch(powershell, {L"-NoProfile", L"-NonInteractive", L"-ExecutionPolicy", L"Bypass",
            L"-File", (plugin / L"install_or_update.ps1").wstring(), L"-ObsRoot", root.wstring(),
            L"-ConfigRoot", (root / L"config/obs-studio").wstring(), L"-Embedded", L"-NoElevation", L"-NoLaunch"},
            root, CREATE_NO_WINDOW, log);
        DWORD wait = WaitForSingleObject(prepare.hProcess, 45000), exit = 1;
        if (wait == WAIT_TIMEOUT) TerminateProcess(prepare.hProcess, 1);
        GetExitCodeProcess(prepare.hProcess, &exit); close_process(prepare);
        CloseHandle(log); log = nullptr;
        if (wait != WAIT_OBJECT_0 || exit) {
            fail(L"自动配置未完成。请将整个文件夹放在可写的位置后重试。\n\n错误记录：" +
                 (root / L"config/applelive-startup.log").wstring());
            WSACleanup(); CloseHandle(mutex); return 3;
        }
        SetEnvironmentVariableW(L"APPLELIVE_DOCK_PRESTARTED", L"1");
        std::vector<std::wstring> args{L"--portable", L"--disable-updater"};
        int count = 0; auto argv = CommandLineToArgvW(GetCommandLineW(), &count);
        for (int i=1; argv && i<count; ++i) args.push_back(argv[i]);
        if (argv) LocalFree(argv);
        obs = launch(host, args, host.parent_path(), CREATE_SUSPENDED);
        helper = launch(plugin / L"AppleLiveDock.exe", {L"--directory", plugin.wstring(),
            L"--port", std::to_wstring(dock), L"--obs-pid", std::to_wstring(obs.dwProcessId)},
            plugin, CREATE_NO_WINDOW);
        ULONGLONG deadline = GetTickCount64() + 30000;
        bool ready = false;
        while (GetTickCount64() < deadline) {
            if (WaitForSingleObject(helper.hProcess, 0) == WAIT_OBJECT_0) break;
            if (dock_ready(dock)) { ready = true; break; }
            Sleep(150);
        }
        if (!ready) throw std::runtime_error("dock did not start");
        if (ResumeThread(obs.hThread) == static_cast<DWORD>(-1)) throw std::runtime_error("ResumeThread");
        resumed = true;
        close_process(helper); CloseHandle(mutex); mutex=nullptr; WSACleanup(); winsock=false;
        WindowBrand brand{obs.dwProcessId, static_cast<HICON>(LoadImageW(GetModuleHandleW(nullptr),MAKEINTRESOURCEW(1),IMAGE_ICON,32,32,0))};
        while (WaitForSingleObject(obs.hProcess,1000)==WAIT_TIMEOUT) EnumWindows(brand_window,reinterpret_cast<LPARAM>(&brand));
        if (brand.icon) DestroyIcon(brand.icon);
        close_process(obs);
        return 0;
    } catch (...) {
        // A suspended child has never touched the scene/profile. Only stop our
        // own failed startup; a running OBS/user stream must not be terminated.
        if (obs.hProcess && !resumed) TerminateProcess(obs.hProcess, 1);
        close_process(obs); close_process(helper);
        if (log) CloseHandle(log);
        if (mutex) CloseHandle(mutex);
        if (winsock) WSACleanup();
        fail(L"福煋OBS 启动未完成。请完整解压后重试；若仍失败，将 config 文件夹中的 applelive-startup.log 发给我们。");
        return 4;
    }
}