#pragma once

#include <cstddef>
#include <cstdint>

extern "C" {

struct obs_data;
struct obs_output;
struct obs_encoder;
struct video_output;
struct audio_output;
struct obs_properties;

using obs_data_t = obs_data;
using obs_output_t = obs_output;
using obs_encoder_t = obs_encoder;
using video_t = video_output;
using audio_t = audio_output;
using obs_properties_t = obs_properties;

enum obs_encoder_type { OBS_ENCODER_AUDIO, OBS_ENCODER_VIDEO };
struct encoder_packet {
    std::uint8_t *data;
    std::size_t size;
    std::int64_t pts;
    std::int64_t dts;
    std::int32_t timebase_num;
    std::int32_t timebase_den;
    obs_encoder_type type;
    bool keyframe;
    std::int64_t dts_usec;
    std::int64_t sys_dts_usec;
    int priority;
    int drop_priority;
    std::size_t track_idx;
    obs_encoder_t *encoder;
};

// ABI pinned to OBS Studio 30.2.3 public headers (Windows x64).
struct obs_video_info {
    const char *graphics_module;
    std::uint32_t fps_num, fps_den;
    std::uint32_t base_width, base_height, output_width, output_height;
    int output_format;
    std::uint32_t adapter;
    bool gpu_conversion;
    int colorspace, range, scale_type;
};
struct obs_audio_info { std::uint32_t samples_per_sec; int speakers; };
static_assert(sizeof(obs_video_info) == 56);
static_assert(offsetof(obs_video_info, output_width) == 24);
static_assert(offsetof(obs_video_info, colorspace) == 44);
static_assert(sizeof(obs_audio_info) == 8);

enum { OBS_OUTPUT_VIDEO = 1, OBS_OUTPUT_AUDIO = 2, OBS_OUTPUT_AV = 3, OBS_OUTPUT_ENCODED = 4 };
enum { OBS_LOG_INFO = 300, LOG_INFO = OBS_LOG_INFO, LOG_ERROR = 100 };
enum { SPEAKERS_MONO = 1 };

struct obs_output_info {
    const char *id;
    std::uint32_t flags;
    const char *(*get_name)(void *);
    void *(*create)(obs_data_t *, obs_output_t *);
    void (*destroy)(void *);
    bool (*start)(void *);
    void (*stop)(void *, std::uint64_t);
    void (*raw_video)(void *, void *);
    void (*raw_audio)(void *, void *);
    void (*encoded_packet)(void *, encoder_packet *);
    void (*update)(void *, obs_data_t *);
    void (*get_defaults)(obs_data_t *);
    obs_properties_t *(*get_properties)(void *);
    void (*unused1)(void *);
    std::uint64_t (*get_total_bytes)(void *);
    int (*get_dropped_frames)(void *);
    void *type_data;
    void (*free_type_data)(void *);
    float (*get_congestion)(void *);
    int (*get_connect_time_ms)(void *);
    const char *encoded_video_codecs;
    const char *encoded_audio_codecs;
    void (*raw_audio2)(void *, std::size_t, void *);
    const char *protocols;
};

static_assert(sizeof(obs_output_info) == 192);
static_assert(offsetof(obs_output_info, encoded_packet) == 72);

__declspec(dllimport) void obs_register_output_s(const obs_output_info *, std::size_t);
__declspec(dllimport) obs_output_t *obs_output_create(const char *, const char *, obs_data_t *, void *);
__declspec(dllimport) void obs_output_release(obs_output_t *);
__declspec(dllimport) bool obs_output_active(const obs_output_t *);
__declspec(dllimport) bool obs_output_start(obs_output_t *);
__declspec(dllimport) void obs_output_stop(obs_output_t *);
__declspec(dllimport) bool obs_output_can_begin_data_capture(const obs_output_t *, std::uint32_t);
__declspec(dllimport) bool obs_output_initialize_encoders(obs_output_t *, std::uint32_t);
__declspec(dllimport) bool obs_output_begin_data_capture(obs_output_t *, std::uint32_t);
__declspec(dllimport) void obs_output_end_data_capture(obs_output_t *);
__declspec(dllimport) void obs_output_set_last_error(obs_output_t *, const char *);
__declspec(dllimport) void obs_output_set_media(obs_output_t *, video_t *, audio_t *);
__declspec(dllimport) void obs_output_set_video_encoder(obs_output_t *, obs_encoder_t *);
__declspec(dllimport) void obs_output_set_audio_encoder(obs_output_t *, obs_encoder_t *, std::size_t);
__declspec(dllimport) obs_encoder_t *obs_video_encoder_create(const char *, const char *, obs_data_t *, void *);
__declspec(dllimport) obs_encoder_t *obs_audio_encoder_create(const char *, const char *, obs_data_t *, std::size_t, void *);
__declspec(dllimport) void obs_encoder_set_video(obs_encoder_t *, video_t *);
__declspec(dllimport) void obs_encoder_set_audio(obs_encoder_t *, audio_t *);
__declspec(dllimport) void obs_encoder_release(obs_encoder_t *);
__declspec(dllimport) const char *obs_encoder_get_codec(const obs_encoder_t *);
__declspec(dllimport) bool obs_encoder_get_extra_data(const obs_encoder_t *, std::uint8_t **, std::size_t *);
__declspec(dllimport) bool obs_get_video_info(obs_video_info *);
__declspec(dllimport) bool obs_get_audio_info(obs_audio_info *);
__declspec(dllimport) video_t *obs_get_video(void);
__declspec(dllimport) audio_t *obs_get_audio(void);
__declspec(dllimport) obs_data_t *obs_data_create(void);
__declspec(dllimport) void obs_data_release(obs_data_t *);
__declspec(dllimport) void obs_data_set_int(obs_data_t *, const char *, long long);
__declspec(dllimport) void obs_data_set_string(obs_data_t *, const char *, const char *);
__declspec(dllimport) void blog(int level, const char *format, ...);

}

#define OBS_DECLARE_MODULE() extern "C" __declspec(dllexport) void obs_module_set_pointer(void *) {} extern "C" __declspec(dllexport) std::uint32_t obs_module_ver(void) { return (30u << 24) | (2u << 16) | 3u; } extern "C" __declspec(dllexport) bool obs_module_load(void); extern "C" __declspec(dllexport) void obs_module_unload(void)
#define OBS_MODULE_USE_DEFAULT_LOCALE(name, locale)
#define obs_register_output(info) obs_register_output_s(info, sizeof(obs_output_info))
