//
//  RTSPKeepAliveWrapper.m
//  FFmpegDecoder
//
//  Created by 김주희 on 12/16/2568 BE.
//

#import "RTSPKeepAliveWrapper.h"
#import <libavformat/avformat.h>

extern void rtsp_send_keepalive(AVFormatContext *s);

void rtsp_keepalive_wrapper(AVFormatContext *fmtCtx)
{
    if (!fmtCtx)
        return;

    rtsp_send_keepalive(fmtCtx);
}
