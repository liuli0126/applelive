#import "ALMediaPlayer.h"
#include <libavformat/avformat.h>
#include <libavutil/time.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_bool gStopPublisher;
static void publishFixture(const char *filename) {
    AVFormatContext *input = NULL, *output = NULL;
    AVPacket *packet = av_packet_alloc();
    if (avformat_open_input(&input, filename, NULL, NULL) < 0 || avformat_find_stream_info(input, NULL) < 0) goto done;
    if (avformat_alloc_output_context2(&output, NULL, "flv", "rtmp://127.0.0.1:1935/live/applelive-test") < 0) goto done;
    for (unsigned i = 0; i < input->nb_streams; i++) {
        AVStream *stream = avformat_new_stream(output, NULL);
        avcodec_parameters_copy(stream->codecpar, input->streams[i]->codecpar);
        stream->codecpar->codec_tag = 0;
        stream->time_base = input->streams[i]->time_base;
    }
    AVDictionary *options = NULL;
    av_dict_set(&options, "rw_timeout", "3000000", 0);
    int result = avio_open2(&output->pb, output->url, AVIO_FLAG_WRITE, NULL, &options);
    av_dict_free(&options);
    if (result < 0 || avformat_write_header(output, NULL) < 0) goto done;
    output->flags |= AVFMT_FLAG_FLUSH_PACKETS;
    int64_t started = av_gettime_relative();
    int64_t loopOffset = 0;
    while (!atomic_load(&gStopPublisher)) {
        if (av_read_frame(input, packet) < 0) {
            if (av_seek_frame(input, -1, 0, AVSEEK_FLAG_BACKWARD) < 0) break;
            loopOffset += input->duration > 0 ? input->duration : 2 * AV_TIME_BASE;
            continue;
        }
        AVStream *source = input->streams[packet->stream_index];
        int64_t offset = av_rescale_q(loopOffset, AV_TIME_BASE_Q, source->time_base);
        if (packet->pts != AV_NOPTS_VALUE) packet->pts += offset;
        if (packet->dts != AV_NOPTS_VALUE) packet->dts += offset;
        int64_t due = started + av_rescale_q(packet->dts, source->time_base, AV_TIME_BASE_Q);
        while (due > av_gettime_relative() && !atomic_load(&gStopPublisher)) usleep(2000);
        av_packet_rescale_ts(packet, source->time_base, output->streams[packet->stream_index]->time_base);
        packet->pos = -1;
        if (av_interleaved_write_frame(output, packet) < 0) break;
        av_packet_unref(packet);
    }
    av_write_trailer(output);
done:
    av_packet_free(&packet); avformat_close_input(&input);
    if (output) { avio_closep(&output->pb); avformat_free_context(output); }
}
static BOOL testSource(NSString *url) {
    ALMediaPlayer *player = [ALMediaPlayer new];
    __block atomic_uint frames, audio;
    atomic_init(&frames, 0); atomic_init(&audio, 0);
    player.onFrame = ^(CVPixelBufferRef frame, NSInteger rotation) { atomic_fetch_add(&frames, 1); };
    player.onAudio = ^(const float *pcm, NSUInteger count) { atomic_fetch_add(&audio, (unsigned)count); };
    [player playURL:[NSURL URLWithString:url]];
    BOOL sawError = NO;
    unsigned middleFrames = 0, middleAudio = 0;
    for (int i = 0; i < 120; i++) {
        usleep(50000);
        if ([player.status[@"state"] isEqualToString:@"error"]) sawError = YES;
        if (i == 59) { middleFrames = atomic_load(&frames); middleAudio = atomic_load(&audio); }
    }
    unsigned finalFrames = atomic_load(&frames), finalAudio = atomic_load(&audio);
    BOOL passed = !sawError && middleFrames >= 20 && finalFrames - middleFrames >= 20 &&
        middleAudio >= 20000 && finalAudio - middleAudio >= 20000 &&
        [player.status[@"state"] isEqualToString:@"playing"];
    fprintf(passed ? stdout : stderr, "%s frames=%u audio=%u state=%s\n", url.UTF8String,
            finalFrames, finalAudio, player.status.description.UTF8String);
    [player stop];
    return passed;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        atomic_init(&gStopPublisher, false);
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ publishFixture(argv[1]); });
        usleep(250000);
        BOOL rtmp = testSource(@"rtmp://127.0.0.1:1935/live/applelive-test");
        BOOL rtsp = testSource(@"rtsp://127.0.0.1:8554/live/applelive-test");
        atomic_store(&gStopPublisher, true); dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        if (!rtmp || !rtsp) return 1;
        puts("RTMP and RTSP H.264/AAC network sources passed");
    }
    return 0;
}
