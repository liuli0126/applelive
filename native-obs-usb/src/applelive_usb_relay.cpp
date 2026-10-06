#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <atomic>
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <filesystem>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "applelive_protocol.h"
#include "plist.h"

namespace {

unsigned short mux_port = 27015;
unsigned short phone_port = 8766;
constexpr unsigned short kDefaultListenPort = 28765;
constexpr std::uint32_t kMuxProtocolVersion = 1;
constexpr std::uint32_t kMuxPlistMessage = 8;

std::atomic<bool> stopping{false};
std::atomic<bool> session_active{false};
std::mutex status_mutex;
std::wstring status_file;

void set_status(const char *state, const char *error = "", int clients = 0)
{
    if (status_file.empty()) return;
    std::lock_guard lock(status_mutex);
    std::ofstream out(std::filesystem::path(status_file + L".tmp"), std::ios::binary | std::ios::trunc);
    if (!out) return;
    out << "{\"state\":\"" << state << "\",\"usb_clients\":" << clients << ",\"error\":\"";
    for (const char *p = error; *p; ++p) {
        if (*p == '\\' || *p == '"') out << '\\';
        out << *p;
    }
    out << "\",\"native\":true}\n";
    out.close();
    MoveFileExW((status_file + L".tmp").c_str(), status_file.c_str(), MOVEFILE_REPLACE_EXISTING);
}

void close_socket(SOCKET &socket)
{
    if (socket != INVALID_SOCKET) {
        shutdown(socket, SD_BOTH);
        closesocket(socket);
        socket = INVALID_SOCKET;
    }
}

bool send_all(SOCKET socket, const void *data, std::size_t size)
{
    const char *bytes = static_cast<const char *>(data);
    while (size) {
        int sent = send(socket, bytes, static_cast<int>(std::min<std::size_t>(size, INT_MAX)), 0);
        if (sent <= 0) return false;
        bytes += sent;
        size -= static_cast<std::size_t>(sent);
    }
    return true;
}

bool recv_all(SOCKET socket, void *data, std::size_t size)
{
    char *bytes = static_cast<char *>(data);
    while (size) {
        int received = recv(socket, bytes, static_cast<int>(std::min<std::size_t>(size, INT_MAX)), 0);
        if (received <= 0) return false;
        bytes += received;
        size -= static_cast<std::size_t>(received);
    }
    return true;
}

std::uint32_t read_le32(const std::uint8_t *bytes)
{
    return static_cast<std::uint32_t>(bytes[0]) | (static_cast<std::uint32_t>(bytes[1]) << 8) |
           (static_cast<std::uint32_t>(bytes[2]) << 16) | (static_cast<std::uint32_t>(bytes[3]) << 24);
}

std::uint32_t read_be32(const std::uint8_t *bytes)
{
    return (static_cast<std::uint32_t>(bytes[0]) << 24) | (static_cast<std::uint32_t>(bytes[1]) << 16) |
           (static_cast<std::uint32_t>(bytes[2]) << 8) | static_cast<std::uint32_t>(bytes[3]);
}

void append_le32(std::vector<std::uint8_t> &out, std::uint32_t value)
{
    out.push_back(static_cast<std::uint8_t>(value));
    out.push_back(static_cast<std::uint8_t>(value >> 8));
    out.push_back(static_cast<std::uint8_t>(value >> 16));
    out.push_back(static_cast<std::uint8_t>(value >> 24));
}

bool mux_request(SOCKET socket, const std::map<std::string, applelive::plist::Value> &values,
                 std::uint32_t tag, applelive::plist::Value &response)
{
    const std::string xml = applelive::plist::xml_request(values);
    std::vector<std::uint8_t> packet;
    append_le32(packet, static_cast<std::uint32_t>(16 + xml.size()));
    append_le32(packet, kMuxProtocolVersion);
    append_le32(packet, kMuxPlistMessage);
    append_le32(packet, tag);
    packet.insert(packet.end(), xml.begin(), xml.end());
    if (!send_all(socket, packet.data(), packet.size())) return false;
    std::uint8_t header[16];
    if (!recv_all(socket, header, sizeof(header))) return false;
    const std::uint32_t length = read_le32(header);
    if (length < 16 || length > 1024 * 1024 || read_le32(header + 4) != 1 ||
        read_le32(header + 8) != 8 || read_le32(header + 12) != tag) return false;
    std::vector<std::uint8_t> body(length - 16);
    if (!recv_all(socket, body.data(), body.size())) return false;
    return applelive::plist::parse(body, response);
}

SOCKET connect_local(unsigned short port)
{
    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) return INVALID_SOCKET;
    DWORD timeout = 1000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    BOOL nodelay = TRUE;
    setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char *>(&nodelay), sizeof(nodelay));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    if (::connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
        close_socket(socket);
        return INVALID_SOCKET;
    }
    return socket;
}

SOCKET connect_phone()
{
    SOCKET list = connect_local(mux_port);
    if (list == INVALID_SOCKET) return INVALID_SOCKET;
    applelive::plist::Value response;
    applelive::plist::Value::Type integer_type = applelive::plist::Value::Type::Integer;
    std::map<std::string, applelive::plist::Value> request;
    request["MessageType"] = {applelive::plist::Value::Type::String, 0, "ListDevices"};
    request["ClientVersionString"] = {applelive::plist::Value::Type::String, 0, "AppleLive/1.0"};
    request["MessageVersion"] = {integer_type, 3};
    request["ProgName"] = {applelive::plist::Value::Type::String, 0, "AppleLive"};
    if (!mux_request(list, request, 1, response)) { close_socket(list); return INVALID_SOCKET; }
    close_socket(list);
    const auto *devices = applelive::plist::get(response, "DeviceList");
    if (!devices || devices->type != applelive::plist::Value::Type::Array) return INVALID_SOCKET;
    std::uint64_t device_id = 0;
    bool found = false;
    for (const auto &device : devices->array) {
        const auto *id = applelive::plist::get(device, "DeviceID");
        const auto *properties = applelive::plist::get(device, "Properties");
        const auto *connection = properties ? applelive::plist::get(*properties, "ConnectionType") : nullptr;
        if (id && id->type == integer_type && connection && connection->string == "USB") {
            device_id = id->integer;
            found = true;
            break;
        }
    }
    if (!found) return INVALID_SOCKET;

    SOCKET connect = connect_local(mux_port);
    if (connect == INVALID_SOCKET) return INVALID_SOCKET;
    request.clear();
    request["MessageType"] = {applelive::plist::Value::Type::String, 0, "Connect"};
    request["ClientVersionString"] = {applelive::plist::Value::Type::String, 0, "AppleLive/1.0"};
    request["DeviceID"] = {integer_type, device_id};
    request["PortNumber"] = {integer_type, static_cast<std::uint64_t>(htons(phone_port))};
    request["ProgName"] = {applelive::plist::Value::Type::String, 0, "AppleLive"};
    if (!mux_request(connect, request, 2, response)) { close_socket(connect); return INVALID_SOCKET; }
    const auto *number = applelive::plist::get(response, "Number");
    if (!number || number->type != integer_type || number->integer != 0) { close_socket(connect); return INVALID_SOCKET; }
    return connect;
}

void handle_client(SOCKET output, int client_id)
{
    struct SessionGuard { ~SessionGuard() { session_active.store(false); } } guard;
    set_status("waiting_phone", "", 0);
    DWORD timeout = 1000;
    setsockopt(output, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    setsockopt(output, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    // One attempt per output connection. OBS retries without accumulating media.
    SOCKET phone = connect_phone();
    if (phone == INVALID_SOCKET) {
        set_status("waiting_phone", "Open the phone USB receiver on a trusted USB iPhone", 0);
        close_socket(output); return;
    }
    char greeting[sizeof(applelive::kUsbMagic) - 1];
    if (!recv_all(phone, greeting, sizeof(greeting)) ||
        memcmp(greeting, applelive::kUsbMagic, sizeof(greeting)) ||
        !send_all(output, greeting, sizeof(greeting))) {
        set_status("error", "iPhone USB handshake failed", 0);
        close_socket(phone); close_socket(output); return;
    }
    set_status("connected", "", client_id);
    while (!stopping.load()) {
        fd_set rd; FD_ZERO(&rd); FD_SET(output, &rd); FD_SET(phone, &rd);
        timeval wait{1, 0};
        int ready = select(0, &rd, nullptr, nullptr, &wait);
        if (ready < 0) break;
        // Phone media protocol is one-way after the greeting. Readability here
        // means closure or an unexpected response, both require a new session.
        if (FD_ISSET(phone, &rd)) break;
        if (!FD_ISSET(output, &rd)) continue;
        std::uint8_t header[4];
        if (!recv_all(output, header, 4)) break;
        auto length = read_be32(header);
        if (length < 4 || length > applelive::kMaxPacket) break;
        std::vector<std::uint8_t> payload(length);
        if (!recv_all(output, payload.data(), length) || !send_all(phone, header, 4) ||
            !send_all(phone, payload.data(), length)) break;
    }
    close_socket(phone); close_socket(output);
    set_status("waiting_phone", "", 0);
}

} // namespace

int wmain(int argc, wchar_t **argv)
{
    unsigned short listen_port = kDefaultListenPort;
    for (int i = 1; i < argc; ++i) {
        const std::wstring argument = argv[i];
        if (argument == L"--listen" && i + 1 < argc) listen_port = static_cast<unsigned short>(std::stoi(argv[++i]));
        else if (argument == L"--mux-port" && i + 1 < argc) mux_port = static_cast<unsigned short>(std::stoi(argv[++i]));
        else if (argument == L"--phone-port" && i + 1 < argc) phone_port = static_cast<unsigned short>(std::stoi(argv[++i]));
        else if (argument == L"--status-file" && i + 1 < argc) status_file = argv[++i];
    }
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return 2;
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) return 3;
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(listen_port);
    if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 || listen(listener, 2) != 0) {
        close_socket(listener); WSACleanup(); return 4;
    }
    set_status("listening");
    while (!stopping.load()) {
        fd_set set;
        FD_ZERO(&set); FD_SET(listener, &set);
        timeval timeout{0, 250000};
        if (select(0, &set, nullptr, nullptr, &timeout) <= 0) continue;
        SOCKET client = accept(listener, nullptr, nullptr);
        if (client == INVALID_SOCKET) continue;
        bool expected = false;
        if (!session_active.compare_exchange_strong(expected, true)) {
            close_socket(client);
            continue;
        }
        std::thread(handle_client, client, 1).detach();
    }
    stopping.store(true);
    close_socket(listener);
    set_status("stopped");
    WSACleanup();
    return 0;
}
