//
//  ffmpeg_rtsp_ex.h
//  FFmpegDecoder
//
//  Created by 김주희 on 12/11/2568 BE.
//

int ff_rtsp_send_cmd(void *rtsp_state,
                     const char *method,
                     void *reply);
