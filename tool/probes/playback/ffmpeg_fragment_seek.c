/*
 * 分片 AAC 最小回归：只解复用，不解码、不播放、不等待。
 * 输入为 fixtures/backward-seek-aac.m4s；--control 跳过首次前跳。
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavutil/error.h>

int main(int argc, char **argv)
{
    AVFormatContext *format = NULL;
    AVPacket *packet = NULL;
    int result = 0;
    int64_t previous = AV_NOPTS_VALUE, duration = 0;

    if (argc != 2 && !(argc == 3 && !strcmp(argv[2], "--control"))) {
        fprintf(stderr, "Usage: %s backward-seek-aac.m4s [--control]\n", argv[0]);
        return 2;
    }
    av_log_set_level(AV_LOG_ERROR);
    if ((result = avformat_open_input(&format, argv[1], NULL, NULL)) < 0)
        goto done;
    if (format->nb_streams != 1 ||
        format->streams[0]->codecpar->codec_id != AV_CODEC_ID_AAC) {
        fprintf(stderr, "Expected the single-track AAC fixture\n");
        result = 2;
        goto done;
    }
    AVRational time_base = format->streams[0]->time_base;
    /* 前跳只解析后面的分片头；无需读包或等待播放。 */
    if (argc == 2 && (result = av_seek_frame(format, 0,
            av_rescale_q(16000, (AVRational){1, 1000}, time_base),
            AVSEEK_FLAG_BACKWARD)) < 0)
        goto done;
    if ((result = av_seek_frame(format, 0,
            av_rescale_q(8133, (AVRational){1, 1000}, time_base),
            AVSEEK_FLAG_BACKWARD)) < 0)
        goto done;
    packet = av_packet_alloc();
    if (!packet) {
        result = AVERROR(ENOMEM);
        goto done;
    }
    /* 第 90 个包跨越未读取过的分片；只检查 seek 后首包会漏检。 */
    for (int i = 0; i < 100; i++) {
        if ((result = av_read_frame(format, packet)) < 0)
            goto done;
        if (previous != AV_NOPTS_VALUE && packet->pts != previous + duration) {
            printf("FAIL packet=%d expected=%.6f actual=%.6f gap=%.6f pos=%"PRId64"\n",
                   i, (previous + duration) * av_q2d(time_base),
                   packet->pts * av_q2d(time_base),
                   (packet->pts - previous - duration) * av_q2d(time_base),
                   packet->pos);
            result = 1;
            goto done;
        }
        previous = packet->pts;
        duration = packet->duration;
        av_packet_unref(packet);
    }
    puts("PASS: 100 contiguous AAC packets");
done:
    if (result < 0) {
        char error[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result, error, sizeof(error));
        fprintf(stderr, "FFmpeg: %s\n", error);
        result = 2;
    }
    av_packet_free(&packet);
    avformat_close_input(&format);
    return result;
}
