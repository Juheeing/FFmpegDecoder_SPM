//
//  Header.h
//  FFmpegDecoder
//
//  Created by 김주희 on 12/16/2568 BE.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

struct AVFormatContext;

void rtsp_keepalive_wrapper(struct AVFormatContext *fmtCtx);

#ifdef __cplusplus
}
#endif
