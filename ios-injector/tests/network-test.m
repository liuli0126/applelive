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
    while (!atomic_load(&gStopPublisher) && av_read_frame(input, packet) >= 0) {
        AVStream *source = input->streams[packet->stream_index];
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
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        ALMediaPlayer *player = [ALMediaPlayer new];
        __block atomic_uint frames, audio;
        atomic_init(&frames, 0); atomic_init(&audio, 0); atomic_init(&gStopPublisher, false);
        player.onFrame = ^(CVPixelBufferRef frame, NSInteger rotation) { atomic_fetch_add(&frames, 1); };
        player.onAudio = ^(const float *pcm, NSUInteger count) { atomic_fetch_add(&audio, (unsigned)count); };
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ publishFixture(argv[1]); });
        usleep(250000); player.loop = NO;
        [player playURL:[NSURL URLWithString:@"rtmp://127.0.0.1:1935/live/applelive-test"]];
        for (int i = 0; i < 160 && (atomic_load(&frames) < 5 || atomic_load(&audio) < 2000); i++) usleep(50000);
        BOOL passed = atomic_load(&frames) >= 5 && atomic_load(&audio) >= 2000;
        if (!passed) fprintf(stderr, "RTMP frames=%u audio=%u state=%s\n", atomic_load(&frames), atomic_load(&audio), player.status.description.UTF8String);
        [player stop]; atomic_store(&gStopPublisher, true); dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        if (!passed) return 1;
        puts("RTMP H.264/AAC network source passed");
    }
    return 0;
}
