#import "FFmpegCBridge.h"
#include "libavutil/log.h"
#include "libavformat/avformat.h"
#include <stdarg.h>

const int      kFFmpegErrorEOF  = AVERROR_EOF;
const int64_t  kFFmpegNoPTSValue = AV_NOPTS_VALUE;

static void ffmpeg_log_callback_impl(void *ptr, int level, const char *fmt, va_list vl) {
    if (level > av_log_get_level()) return;
    char buf[1024];
    vsnprintf(buf, sizeof(buf), fmt, vl);
    NSLog(@"FFmpeg: %s", buf);
}

void ffmpeg_setup_log_callback(void) {
    av_log_set_callback(ffmpeg_log_callback_impl);
}

void ffmpeg_remove_log_callback(void) {
    av_log_set_callback(av_log_default_callback);
}
