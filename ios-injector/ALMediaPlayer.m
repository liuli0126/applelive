#import "ALMediaPlayer.h"
#import <QuartzCore/QuartzCore.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/display.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <unistd.h>
#include <stdatomic.h>

typedef struct {
    atomic_uint *generation;
    unsigned expected;
    double deadline;
} ALMediaInterrupt;

static int ALInterruptMedia(void *opaque) {
    ALMediaInterrupt *state = opaque;
    return atomic_load(state->generation) != state->expected ||
        (state->deadline > 0 && CACurrentMediaTime() > state->deadline);
}

static enum AVPixelFormat ALHardwareFormat(AVCodecContext *codec, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; format++)
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    return formats[0];
}

static AVCodecContext *ALOpenMediaCodec(AVStream *stream, BOOL hardware) {
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context || avcodec_parameters_to_context(context, stream->codecpar) < 0) {
        avcodec_free_context(&context); return NULL;
    }
    context->pkt_timebase = stream->time_base;
    context->thread_count = 2;
    if (hardware && av_hwdevice_ctx_create(&context->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                         NULL, NULL, 0) >= 0) context->get_format = ALHardwareFormat;
    if (avcodec_open2(context, codec, NULL) < 0) { avcodec_free_context(&context); return NULL; }
    return context;
}

@interface ALMediaPlayer () {
    dispatch_queue_t _worker;
    atomic_uint _generation;
}
@property(atomic, copy, readwrite) NSDictionary *status;
@property(atomic) double requestedSeek;
@end

@implementation ALMediaPlayer
- (instancetype)init {
    if ((self = [super init])) {
        _worker = dispatch_queue_create("com.applelive.media", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_generation, 0);
        _requestedSeek = -1;
        _loop = YES;
        _status = @{@"state": @"stopped", @"position": @0, @"duration": @0};
        static dispatch_once_t once;
        dispatch_once(&once, ^{ avformat_network_init(); av_log_set_level(AV_LOG_ERROR); });
    }
    return self;
}

- (void)stop {
    @synchronized (self) { atomic_fetch_add(&_generation, 1); }
    self.paused = NO;
    self.status = @{@"state": @"stopped", @"position": @0, @"duration": @0};
}
- (void)seek:(NSTimeInterval)seconds { self.requestedSeek = MAX(0, seconds); }
- (void)playURL:(NSURL *)url {
    [self stop];
    unsigned generation = atomic_load(&_generation);
    self.requestedSeek = -1;
    self.status = @{@"state": @"opening", @"position": @0, @"duration": @0};
    dispatch_async(_worker, ^{
        while (atomic_load(&self->_generation) == generation) {
            @autoreleasepool { [self runURL:url generation:generation]; }
            if (url.isFileURL || atomic_load(&self->_generation) != generation) break;
            for (int i = 0; i < 20 && atomic_load(&self->_generation) == generation; i++) usleep(100000);
        }
    });
}

- (void)runURL:(NSURL *)url generation:(unsigned)generation {
    AVFormatContext *input = avformat_alloc_context();
    AVCodecContext *video = NULL, *audio = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    SwrContext *resampler = NULL;
    struct SwsContext *scaler = NULL;
    CVPixelBufferPoolRef pool = NULL;
    int poolWidth = 0, poolHeight = 0;
    ALMediaInterrupt interrupt = {&_generation, generation, CACurrentMediaTime() + 10};
    int error = AVERROR(ENOMEM);
    double duration = 0, position = 0, originPTS = NAN, originClock = 0;
    double lastStatus = 0;
    double discardBefore = -1;
    BOOL local = url.isFileURL;
    if (!input || !packet || !frame) goto cleanup;
    input->interrupt_callback = (AVIOInterruptCB){ALInterruptMedia, &interrupt};
    AVDictionary *options = NULL;
    if (!local) {
        av_dict_set(&options, "rw_timeout", "5000000", 0);
        av_dict_set(&options, "rtsp_transport", "tcp", 0);
        av_dict_set(&options, "probesize", "262144", 0);
        av_dict_set(&options, "analyzeduration", "1000000", 0);
        av_dict_set(&options, "rtmp_live", "live", 0);
    }
    error = avformat_open_input(&input, local ? url.path.UTF8String : url.absoluteString.UTF8String, NULL, &options);
    av_dict_free(&options);
    if (error < 0) goto cleanup;
    error = avformat_find_stream_info(input, NULL);
    if (error < 0) goto cleanup;
    int videoIndex = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int audioIndex = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (videoIndex < 0) { error = videoIndex; goto cleanup; }
    video = ALOpenMediaCodec(input->streams[videoIndex], YES);
    if (!video) { error = AVERROR_DECODER_NOT_FOUND; goto cleanup; }
    if (audioIndex >= 0) audio = ALOpenMediaCodec(input->streams[audioIndex], NO);
    duration = input->duration > 0 ? (double)input->duration / AV_TIME_BASE : 0;
    size_t matrixSize = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    uint8_t *matrix = av_stream_get_side_data(input->streams[videoIndex], AV_PKT_DATA_DISPLAYMATRIX, &matrixSize);
#pragma clang diagnostic pop
    double angle = matrix && matrixSize >= 9 * sizeof(int32_t) ? av_display_rotation_get((int32_t *)matrix) : 0;
    NSInteger rotation = isfinite(angle) ? (NSInteger)llround(-angle / 90.0) : 0;
    rotation = (rotation % 4 + 4) % 4;
    interrupt.deadline = 0;
    while (atomic_load(&_generation) == generation) {
        @autoreleasepool {
            if (local && self.paused && self.requestedSeek < 0) {
                self.status = @{@"state": @"paused", @"position": @(position), @"duration": @(duration), @"audio": @(audio != NULL)};
                usleep(20000); originPTS = NAN; continue;
            }
            double seek = self.requestedSeek;
            if (local && seek >= 0) {
                self.requestedSeek = -1;
                AVRational rate = av_guess_frame_rate(input, input->streams[videoIndex], NULL);
                double interval = rate.num > 0 && rate.den > 0 ? av_q2d(av_inv_q(rate)) : 0.05;
                if (duration > 0) seek = MIN(seek, MAX(0, duration - interval));
                if (av_seek_frame(input, -1, (int64_t)(seek * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD) >= 0) {
                    avcodec_flush_buffers(video); if (audio) avcodec_flush_buffers(audio);
                    swr_free(&resampler); originPTS = NAN;
                    discardBefore = seek;
                    if (self.onReset) self.onReset();
                }
            }
            interrupt.deadline = local ? 0 : CACurrentMediaTime() + 5;
            error = av_read_frame(input, packet);
            interrupt.deadline = 0;
            if (error < 0) {
                // Drain delayed video frames before ending or looping a local file.
                if (error == AVERROR_EOF && local) avcodec_send_packet(video, NULL);
                else break;
            }
            BOOL isVideo = error < 0 || packet->stream_index == videoIndex;
            AVCodecContext *codec = isVideo ? video : packet->stream_index == audioIndex ? audio : NULL;
            AVStream *stream = input->streams[isVideo ? videoIndex : MAX(audioIndex, 0)];
            if (codec) {
                int sent = error < 0 ? 0 : avcodec_send_packet(codec, packet);
                if (sent >= 0) while (avcodec_receive_frame(codec, frame) == 0) {
                    double pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? position :
                        frame->best_effort_timestamp * av_q2d(stream->time_base);
                    if (input->start_time != AV_NOPTS_VALUE) pts -= (double)input->start_time / AV_TIME_BASE;
                    if (discardBefore >= 0 && pts < discardBefore - 0.02) { av_frame_unref(frame); continue; }
                    if (!isVideo && local && self.paused) { av_frame_unref(frame); continue; }
                    if (isVideo) discardBefore = -1;
                    if (!isfinite(originPTS)) { originPTS = pts; originClock = CACurrentMediaTime(); }
                    double target = originClock + pts - originPTS;
                    double now = CACurrentMediaTime();
                    if (!local && fabs(now - target) > 2) {
                        originClock = now; originPTS = pts; target = now;
                    }
                    if (!local && now - target > (isVideo ? 0.12 : 0.2)) { av_frame_unref(frame); continue; }
                    while (target > CACurrentMediaTime() && atomic_load(&_generation) == generation &&
                           !(local && (self.paused || self.requestedSeek >= 0))) usleep(3000);
                    if (atomic_load(&_generation) != generation) { av_frame_unref(frame); break; }
                    if (isVideo) {
                        CVPixelBufferRef pixel = NULL;
                        if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) pixel = CVPixelBufferRetain((CVPixelBufferRef)frame->data[3]);
                        else {
                            if (!pool || poolWidth != frame->width || poolHeight != frame->height) {
                                if (pool) CVPixelBufferPoolRelease(pool);
                                poolWidth = frame->width; poolHeight = frame->height;
                                NSDictionary *attributes = @{
                                    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                                    (id)kCVPixelBufferWidthKey: @(poolWidth), (id)kCVPixelBufferHeightKey: @(poolHeight),
                                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                                };
                                CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &pool);
                            }
                            if (pool && CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixel) == kCVReturnSuccess) {
                                scaler = sws_getCachedContext(scaler, frame->width, frame->height, frame->format,
                                    frame->width, frame->height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
                                CVPixelBufferLockBaseAddress(pixel, 0);
                                uint8_t *planes[4] = {CVPixelBufferGetBaseAddress(pixel), NULL, NULL, NULL};
                                int strides[4] = {(int)CVPixelBufferGetBytesPerRow(pixel), 0, 0, 0};
                                if (scaler) sws_scale(scaler, (const uint8_t * const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
                                CVPixelBufferUnlockBaseAddress(pixel, 0);
                                if (!scaler) { CVPixelBufferRelease(pixel); pixel = NULL; }
                            }
                        }
                        if (pixel) {
                            @synchronized (self) {
                                if (atomic_load(&_generation) == generation && self.onFrame) self.onFrame(pixel, rotation);
                            }
                            CVPixelBufferRelease(pixel);
                        }
                        position = MAX(0, pts);
                    } else {
                        if (!resampler) {
                            AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
                            if (swr_alloc_set_opts2(&resampler, &stereo, AV_SAMPLE_FMT_FLT, 48000,
                                    &frame->ch_layout, frame->format, frame->sample_rate, 0, NULL) < 0 ||
                                swr_init(resampler) < 0) swr_free(&resampler);
                        }
                        if (resampler) {
                            int capacity = (int)av_rescale_rnd(swr_get_delay(resampler, frame->sample_rate) + frame->nb_samples,
                                                              48000, frame->sample_rate, AV_ROUND_UP);
                            NSMutableData *pcm = [NSMutableData dataWithLength:(NSUInteger)capacity * 2 * sizeof(float)];
                            uint8_t *output = pcm.mutableBytes;
                            int count = swr_convert(resampler, &output, capacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
                            @synchronized (self) {
                                if (atomic_load(&_generation) == generation && count > 0 && self.onAudio) self.onAudio((const float *)pcm.bytes, count);
                            }
                        }
                    }
                    av_frame_unref(frame);
                    if (atomic_load(&_generation) == generation && CACurrentMediaTime() - lastStatus > 0.2) {
                        lastStatus = CACurrentMediaTime();
                        self.status = @{@"state": @"playing", @"position": @(position), @"duration": @(duration), @"audio": @(audio != NULL)};
                    }
                }
            }
            av_packet_unref(packet);
            if (error == AVERROR_EOF) {
                if (self.loop && av_seek_frame(input, -1, 0, AVSEEK_FLAG_BACKWARD) >= 0) {
                    avcodec_flush_buffers(video); if (audio) avcodec_flush_buffers(audio);
                    swr_free(&resampler); originPTS = NAN;
                    if (self.onReset) self.onReset();
                } else break;
            }
        }
    }
cleanup:
    av_packet_free(&packet); av_frame_free(&frame);
    avcodec_free_context(&video); avcodec_free_context(&audio);
    swr_free(&resampler); sws_freeContext(scaler);
    if (pool) CVPixelBufferPoolRelease(pool);
    avformat_close_input(&input);
    if (atomic_load(&_generation) == generation) {
        char message[AV_ERROR_MAX_STRING_SIZE] = {0}; av_strerror(error, message, sizeof(message));
        BOOL ended = error == AVERROR_EOF && local;
        self.status = @{@"state": ended ? @"ended" : @"error", @"error": ended ? @"" : [NSString stringWithUTF8String:message],
                        @"position": @(position), @"duration": @(duration)};
        if (!local && self.onReset) self.onReset();
    }
}
@end
