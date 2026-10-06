#include "applelive_obs_api.h"

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "applelive_protocol.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("applelive-native-output", "en-US");

namespace {

constexpr char kRelayHost[] = "127.0.0.1";
unsigned short kRelayPort = 28765;
unsigned short kControlPort = 28766;
constexpr std::size_t kMaxQueueBytes = 8 * 1024 * 1024;
constexpr std::size_t kMaxQueuePackets = 16;

struct NativeOutput {
    obs_output_t *output = nullptr;
    obs_encoder_t *video = nullptr;
    obs_encoder_t *audio = nullptr;
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<std::vector<std::uint8_t>> queue;
    std::size_t queued_bytes = 0;
    std::vector<std::uint8_t> sps;
    std::vector<std::uint8_t> pps;
    std::thread worker;
    std::atomic<bool> stopping{false};
    std::atomic<bool> connected{false};
    bool waiting_for_keyframe = true;
    std::uint32_t sequence = 0;
    std::uint32_t width = 1920;
    std::uint32_t height = 1080;
    std::uint32_t sample_rate = 48000;
    std::uint32_t channels = 2;
    bool audio_config_sent = false;
};

std::mutex g_mutex;
obs_output_t *g_active = nullptr;
std::atomic<bool> g_control_stop{false};
std::thread g_control_thread;

void log(const char *level, const std::string &message)
{
    blog(level[0] == 'E' ? LOG_ERROR : LOG_INFO, "[AppleLive] %s", message.c_str());
}

void close_socket(SOCKET &socket)
{
    if (socket != INVALID_SOCKET) {
        shutdown(socket, SD_BOTH);
        closesocket(socket);
        socket = INVALID_SOCKET;
    }
}

bool write_all(SOCKET socket, const std::uint8_t *data, std::size_t size)
{
    while (size) {
        int sent = send(socket, reinterpret_cast<const char *>(data), static_cast<int>(std::min<std::size_t>(size, INT_MAX)), 0);
        if (sent <= 0) return false;
        data += sent;
        size -= static_cast<std::size_t>(sent);
    }
    return true;
}

// The phone sends the greeting. The relay acknowledges only after receiving it.
// Never queue media before this point: a newly connected decoder needs a fresh IDR.
SOCKET connect_relay()
{
    SOCKET sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock == INVALID_SOCKET) return sock;
    DWORD timeout = 1000;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeout), sizeof(timeout));
    BOOL nodelay = TRUE;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char *>(&nodelay), sizeof(nodelay));
    sockaddr_in addr{};
    addr.sin_family = AF_INET; addr.sin_port = htons(kRelayPort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(sock, reinterpret_cast<sockaddr *>(&addr), sizeof(addr))) { close_socket(sock); return sock; }
    char greeting[sizeof(applelive::kUsbMagic) - 1];
    size_t offset = 0;
    while (offset < sizeof(greeting)) {
        int n = recv(sock, greeting + offset, int(sizeof(greeting) - offset), 0);
        if (n <= 0) { close_socket(sock); return sock; }
        offset += n;
    }
    if (memcmp(greeting, applelive::kUsbMagic, sizeof(greeting))) close_socket(sock);
    return sock;
}

void drop_queue_locked(NativeOutput *state)
{
    state->queue.clear();
    state->queued_bytes = 0;
    state->waiting_for_keyframe = true;
    state->audio_config_sent = false;
}

bool has_start_code(const std::uint8_t *data, std::size_t size)
{
    return size >= 4 && ((data[0] == 0 && data[1] == 0 && data[2] == 1) ||
                         (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 1));
}

std::vector<std::vector<std::uint8_t>> split_nals(const std::uint8_t *data, std::size_t size)
{
    std::vector<std::vector<std::uint8_t>> nals;
    if (!data || !size) return nals;
    if (!has_start_code(data, size)) {
        std::size_t offset = 0;
        while (offset + 4 <= size) {
            std::uint32_t length = (static_cast<std::uint32_t>(data[offset]) << 24) |
                                   (static_cast<std::uint32_t>(data[offset + 1]) << 16) |
                                   (static_cast<std::uint32_t>(data[offset + 2]) << 8) |
                                   data[offset + 3];
            offset += 4;
            if (!length || length > size - offset) return {};
            nals.emplace_back(data + offset, data + offset + length);
            offset += length;
        }
        if (offset != size) return {};
        return nals;
    }
    std::size_t cursor = 0;
    auto find_start = [&](std::size_t from) {
        for (std::size_t i = from; i + 3 <= size; ++i) {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) return i;
            if (i + 4 <= size && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) return i;
        }
        return size;
    };
    while (cursor < size) {
        std::size_t start = find_start(cursor);
        if (start == size) break;
        std::size_t prefix = (start + 3 < size && data[start + 2] == 0) ? 4 : 3;
        std::size_t next = find_start(start + prefix);
        std::size_t end = next == size ? size : next;
        if (end > start + prefix) nals.emplace_back(data + start + prefix, data + end);
        cursor = end;
    }
    return nals;
}

std::vector<std::uint8_t> annexb(const std::vector<std::vector<std::uint8_t>> &nals)
{
    std::vector<std::uint8_t> result;
    for (const auto &nal : nals) {
        result.insert(result.end(), {0, 0, 0, 1});
        result.insert(result.end(), nal.begin(), nal.end());
    }
    return result;
}

std::vector<std::uint8_t> video_packet(NativeOutput *state, const encoder_packet *packet)
{
    const auto nals = split_nals(packet->data, packet->size);
    std::vector<std::vector<std::uint8_t>> output;
    output.reserve(nals.size() + 2);
    for (const auto &nal : nals) {
        if (nal.empty()) continue;
        const std::uint8_t type = nal[0] & 0x1f;
        if (type == 7) state->sps = [&] { std::vector<std::uint8_t> v{0, 0, 0, 1}; v.insert(v.end(), nal.begin(), nal.end()); return v; }();
        if (type == 8) state->pps = [&] { std::vector<std::uint8_t> v{0, 0, 0, 1}; v.insert(v.end(), nal.begin(), nal.end()); return v; }();
        output.push_back(nal);
    }
    if (packet->keyframe) {
        if (state->sps.size() > 4) {
            std::vector<std::uint8_t> sps(state->sps.begin() + 4, state->sps.end());
            output.insert(output.begin(), std::move(sps));
        }
        if (state->pps.size() > 4) {
            std::vector<std::uint8_t> pps(state->pps.begin() + 4, state->pps.end());
            output.insert(output.begin() + (state->sps.size() > 4 ? 1 : 0), std::move(pps));
        }
    }
    auto body = annexb(output);
    std::vector<std::uint8_t> result;
    result.reserve(20 + body.size());
    result.insert(result.end(), {'f', 'r', 'a', 'm'});
    applelive::put_le32(result, state->sequence++);
    applelive::put_le32(result, (packet->keyframe ? 1u : 0u) | 2u);
    applelive::put_le32(result, state->width);
    applelive::put_le32(result, state->height);
    result.insert(result.end(), body.begin(), body.end());
    return result;
}

std::vector<std::uint8_t> audio_packet(NativeOutput *state, const encoder_packet *packet)
{
    // ffmpeg_pcm_f32le is selected when available. If OBS falls back to AAC,
    // mark it as aaca so newer phone builds can decode it instead of treating
    // compressed bytes as float PCM.
    const char *codec = state->audio ? obs_encoder_get_codec(state->audio) : nullptr;
    const bool pcm = codec && strstr(codec, "pcm") != nullptr;
    std::vector<std::uint8_t> result;
    result.reserve(12 + packet->size);
    const char *type = pcm ? "audi" : "aaca";
    result.insert(result.end(), type, type + 4);
    applelive::put_le32(result, state->sample_rate);
    applelive::put_le32(result, state->channels);
    result.insert(result.end(), packet->data, packet->data + packet->size);
    return result;
}

std::vector<std::uint8_t> audio_config_packet(NativeOutput *state)
{
    std::uint8_t *extra = nullptr;
    std::size_t size = 0;
    if (!state->audio || !obs_encoder_get_extra_data(state->audio, &extra, &size) || !extra || !size || size > 1024) return {};
    std::vector<std::uint8_t> result;
    result.reserve(12 + size);
    result.insert(result.end(), {'a', 'a', 'c', 'd'});
    applelive::put_le32(result, state->sample_rate);
    applelive::put_le32(result, state->channels);
    result.insert(result.end(), extra, extra + size);
    return result;
}

// All packet construction and queue state are serialized by state->mutex.
void enqueue_locked(NativeOutput *state, std::vector<std::uint8_t> packet)
{
    state->queued_bytes += packet.size();
    state->queue.emplace_back(std::move(packet));
    state->wake.notify_one();
}

void worker_loop(NativeOutput *state)
{
    while (!state->stopping.load()) {
        SOCKET relay = connect_relay();
        if (relay == INVALID_SOCKET) {
            std::unique_lock lock(state->mutex);
            state->wake.wait_for(lock, std::chrono::milliseconds(250), [&] { return state->stopping.load(); });
            continue;
        }
        {
            std::lock_guard lock(state->mutex);
            drop_queue_locked(state);
            state->connected.store(true);
        }
        while (!state->stopping.load()) {
            std::vector<std::uint8_t> packet;
            {
                std::unique_lock lock(state->mutex);
                state->wake.wait_for(lock, std::chrono::milliseconds(500), [&] { return state->stopping.load() || !state->queue.empty(); });
                if (state->stopping.load()) break;
                if (!state->queue.empty()) {
                    packet = std::move(state->queue.front()); state->queue.pop_front();
                    state->queued_bytes -= packet.size();
                }
            }
            if (packet.empty()) {
                fd_set rd; FD_ZERO(&rd); FD_SET(relay, &rd); timeval timeout{};
                if (select(0, &rd, nullptr, nullptr, &timeout) > 0) break;
                continue;
            }
            auto framed = applelive::frame(packet);
            if (!write_all(relay, framed.data(), framed.size())) break;
        }
        {
            std::lock_guard lock(state->mutex);
            state->connected.store(false); drop_queue_locked(state);
        }
        close_socket(relay);
    }
}

bool setup_encoders(NativeOutput *state);

void *output_create(obs_data_t *, obs_output_t *output)
{
    auto *state = new NativeOutput();
    state->output = output;
    obs_video_info video_info{};
    if (obs_get_video_info(&video_info)) {
        state->width = video_info.output_width ? video_info.output_width : video_info.base_width;
        state->height = video_info.output_height ? video_info.output_height : video_info.base_height;
    }
    obs_audio_info audio_info{};
    if (obs_get_audio_info(&audio_info)) {
        state->sample_rate = audio_info.samples_per_sec;
        state->channels = audio_info.speakers == SPEAKERS_MONO ? 1 : 2;
    }
    if (!setup_encoders(state)) {
        if (state->video) obs_encoder_release(state->video);
        if (state->audio) obs_encoder_release(state->audio);
        delete state;
        return nullptr;
    }
    return state;
}

void output_destroy(void *data)
{
    auto *state = static_cast<NativeOutput *>(data);
    if (!state) return;
    state->stopping.store(true);
    state->wake.notify_all();
    if (state->worker.joinable()) state->worker.join();
    if (state->video) obs_encoder_release(state->video);
    if (state->audio) obs_encoder_release(state->audio);
    delete state;
}

bool output_start(void *data)
{
    auto *state = static_cast<NativeOutput *>(data);
    if (!obs_output_can_begin_data_capture(state->output, 0) ||
        !obs_output_initialize_encoders(state->output, 0)) {
        obs_output_set_last_error(state->output, "AppleLive could not initialize H.264/AAC encoders");
        return false;
    }
    std::uint8_t *extra = nullptr; std::size_t size = 0;
    if (obs_encoder_get_extra_data(state->video, &extra, &size)) {
        for (const auto &nal : split_nals(extra, size)) {
            if (nal.empty()) continue;
            auto data = annexb({nal});
            if ((nal[0] & 31) == 7) state->sps = std::move(data);
            if ((nal[0] & 31) == 8) state->pps = std::move(data);
        }
    }
    state->stopping.store(false);
    state->waiting_for_keyframe = true;
    state->audio_config_sent = false;
    state->worker = std::thread(worker_loop, state);
    if (!obs_output_begin_data_capture(state->output, OBS_OUTPUT_VIDEO | OBS_OUTPUT_AUDIO)) {
        state->stopping.store(true);
        state->wake.notify_all();
        if (state->worker.joinable()) state->worker.join();
        return false;
    }
    log("I", "native OBS output started; relay queue is non-blocking");
    return true;
}

void output_stop(void *data, uint64_t)
{
    auto *state = static_cast<NativeOutput *>(data);
    if (!state) return;
    obs_output_end_data_capture(state->output);
    state->stopping.store(true);
    state->wake.notify_all();
    if (state->worker.joinable()) state->worker.join();
    std::lock_guard lock(state->mutex);
    drop_queue_locked(state);
}

void output_packet(void *data, encoder_packet *packet)
{
    auto *state = static_cast<NativeOutput *>(data);
    if (!state || !packet || !packet->data || !packet->size || state->stopping.load()) return;
    std::lock_guard lock(state->mutex);
    if (!state->connected.load()) return;
    const bool video = packet->type == OBS_ENCODER_VIDEO;
    // A sequence advances even when this queue drops a video frame. The receiver
    // can then discard dependent pictures until the next SPS/PPS + IDR.
    auto payload = video ? video_packet(state, packet) : audio_packet(state, packet);
    if (payload.empty() || payload.size() > applelive::kMaxPacket) {
        drop_queue_locked(state); return;
    }
    if (state->queue.size() + 2 > kMaxQueuePackets || state->queued_bytes + payload.size() + 2048 > kMaxQueueBytes)
        drop_queue_locked(state);
    if (state->waiting_for_keyframe) {
        if (!video || !packet->keyframe || state->sps.empty() || state->pps.empty()) return;
        state->waiting_for_keyframe = false;
    }
    if (!video && !state->audio_config_sent) {
        auto config = audio_config_packet(state);
        if (config.empty()) return;
        enqueue_locked(state, std::move(config));
        state->audio_config_sent = true;
    }
    enqueue_locked(state, std::move(payload));
    // OBS owns this borrowed encoder_packet and releases it after the callback.
}

const char *output_name(void *) { return "AppleLive USB (native)"; }

bool setup_encoders(NativeOutput *state)
{
    obs_data_t *video_settings = obs_data_create();
    obs_data_set_int(video_settings, "bitrate", 6000);
    obs_data_set_int(video_settings, "keyint_sec", 1);
    obs_data_set_string(video_settings, "rate_control", "CBR");
    obs_data_set_string(video_settings, "preset", "veryfast");
    obs_data_set_string(video_settings, "tune", "zerolatency");
    obs_data_set_string(video_settings, "profile", "baseline");
    obs_data_set_string(video_settings, "x264opts", "bframes=0 repeat-headers=1 annexb=1 scenecut=0 slices=1");
    obs_encoder_t *video = obs_video_encoder_create("obs_x264", "AppleLive H.264", video_settings, nullptr);
    obs_data_release(video_settings);
    if (video) {
        obs_encoder_set_video(video, obs_get_video());
        obs_output_set_video_encoder(state->output, video);
        state->video = video;
    }
    obs_data_t *audio_settings = obs_data_create();
    obs_data_set_int(audio_settings, "bitrate", 160);
    obs_encoder_t *audio = obs_audio_encoder_create("ffmpeg_aac", "AppleLive AAC", audio_settings, 0, nullptr);
    obs_data_release(audio_settings);
    if (audio) {
        obs_encoder_set_audio(audio, obs_get_audio());
        obs_output_set_audio_encoder(state->output, audio, 0);
        state->audio = audio;
    }
    return video && audio;
}

obs_output_info output_info()
{
    obs_output_info info{};
    info.id = "applelive_native_usb";
    info.flags = OBS_OUTPUT_AV | OBS_OUTPUT_ENCODED;
    info.get_name = output_name;
    info.create = output_create;
    info.destroy = output_destroy;
    info.start = output_start;
    info.stop = output_stop;
    info.encoded_packet = output_packet;
    info.encoded_video_codecs = "h264";
    info.encoded_audio_codecs = "aac";
    return info;
}

const obs_output_info kOutputInfo = output_info();
void send_control_response(SOCKET client, const char *text)
{
    send(client, text, static_cast<int>(strlen(text)), 0);
    shutdown(client, SD_BOTH);
    closesocket(client);
}

void control_loop()
{
    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) return;
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(kControlPort);
    if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 || listen(listener, 4) != 0) {
        closesocket(listener);
        return;
    }
    while (!g_control_stop.load()) {
        fd_set read_set;
        FD_ZERO(&read_set);
        FD_SET(listener, &read_set);
        timeval timeout{0, 250000};
        if (select(0, &read_set, nullptr, nullptr, &timeout) <= 0) continue;
        SOCKET client = accept(listener, nullptr, nullptr);
        if (client == INVALID_SOCKET) continue;
        DWORD timeoutMs = 1000;
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char *>(&timeoutMs), sizeof(timeoutMs));
        char command[32]{};
        int received = recv(client, command, sizeof(command) - 1, 0);
        std::string value(command, received > 0 ? received : 0);
        std::lock_guard lock(g_mutex);
        if (value.rfind("start", 0) == 0) {
            if (!g_active) {
                obs_data_t *settings = obs_data_create();
                obs_output_t *output = obs_output_create(kOutputInfo.id, "AppleLive USB", settings, nullptr);
                obs_data_release(settings);
                if (output) {
                    g_active = output;
                    if (!obs_output_start(output)) {
                        obs_output_release(output);
                        g_active = nullptr;
                    }
                }
            }
            send_control_response(client, g_active ? "ok\n" : "error\n");
        } else if (value.rfind("stop", 0) == 0) {
            if (g_active) {
                obs_output_stop(g_active);
                obs_output_release(g_active);
                g_active = nullptr;
            }
            send_control_response(client, "ok\n");
        } else {
            send_control_response(client, g_active && obs_output_active(g_active) ? "running\n" : "stopped\n");
        }
    }
    closesocket(listener);
}

} // namespace

bool obs_module_load(void)
{
    if (const char *port = std::getenv("APPLELIVE_TEST_RELAY_PORT")) kRelayPort = static_cast<unsigned short>(std::atoi(port));
    if (const char *port = std::getenv("APPLELIVE_TEST_CONTROL_PORT")) kControlPort = static_cast<unsigned short>(std::atoi(port));
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return false;
    obs_register_output(&kOutputInfo);
    g_control_stop.store(false);
    g_control_thread = std::thread(control_loop);
    blog(LOG_INFO, "[AppleLive] native USB output loaded on control port %u", kControlPort);
    return true;
}

void obs_module_unload(void)
{
    g_control_stop.store(true);
    if (g_control_thread.joinable()) g_control_thread.join();
    std::lock_guard lock(g_mutex);
    if (g_active) {
        obs_output_stop(g_active);
        obs_output_release(g_active);
        g_active = nullptr;
    }
    WSACleanup();
}


