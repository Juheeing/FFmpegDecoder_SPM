#pragma once
#import <Foundation/Foundation.h>

// FFmpeg macro values that Swift cannot import directly
extern const int       kFFmpegErrorEOF;
extern const int64_t   kFFmpegNoPTSValue;

// Log callback setup — uses va_list, which cannot be written in Swift
void ffmpeg_setup_log_callback(void);
void ffmpeg_remove_log_callback(void);

// Per-instance interrupt check: opaque must be UnsafeMutablePointer<CBool> (_Bool *)
int ffmpeg_interrupt_check(void *opaque);
