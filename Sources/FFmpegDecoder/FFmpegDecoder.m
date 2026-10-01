#import "FFmpegDecoder.h"
#include <sys/time.h>
#define FFMPEG_DECODER_VERSION @"1.0.6"

static __weak FFmpegDecoder *gCurrentDecoder = nil;

@implementation FFmpegDecoder {
    struct SwsContext* swsCtx;
    AVFormatContext *pFormatContext;
    AVCodecContext *pVCtx, *pACtx;
    AVCodecParameters *pVPara, *pAPara;
    AVCodec *pVCodec, *pACodec;
    AVStream* pVStream, * pAStream;
    AVPacket packet;
    AVFrame *vFrame, *aFrame;
    CGSize outputFrameSize;
    dispatch_queue_t mDecodingQueue;
    uint8_t *dst_data[4];
    int dst_linesize[4];
    int vidx, aidx;
    BOOL decodingStopped;
    BOOL isPaused, isPlaying, isSeeking;
    double seekTarget;
    BOOL hasPendingSeek, hasEverSeeked;         // seek 직후 첫 프레임에서 보정할 플래그
    double pendingSeekSeconds;   // 사용자가 요청한 seek 시간
    BOOL needLog, needInterrupt;
    NSString *logFilePath;
    NSCondition *pauseCondition;  // stopDecoding 등 기존 호환용
    NSMutableArray *packetQueue;  // read/decode thread 간 패킷 공유 큐
    NSCondition *queueCondition;  // 큐 + pause/resume 동기화
    dispatch_queue_t mReadQueue;
    int64_t lastRescaledPTS;      // 이전 프레임 pts (rescaled)
    int64_t ptsOffset;           // 누적 offset
    int currentState;
    BOOL videoFirstPacketLogged;
    BOOL videoFirstValidPTSLogged;
    BOOL audioFirstPacketLogged;
    BOOL engineInitialized;
    double decodingStartWallTime;
    double decodingStartPTS;
    BOOL firstAudioFrameSeen;
    BOOL eofReached;
}

- (id) init {
    if (self = [super init]) {
        mDecodingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        pauseCondition = [[NSCondition alloc] init];
        queueCondition = [[NSCondition alloc] init];
        mReadQueue = dispatch_queue_create("com.ffmpeg.readqueue", DISPATCH_QUEUE_SERIAL);
        decodingStopped = NO;
        isPaused = NO;
        isPlaying = YES;
        lastRescaledPTS = -1;
        ptsOffset = 0;
        currentState = 0;
        hasPendingSeek = NO;
        hasEverSeeked = NO;
        pendingSeekSeconds = 0;
        needLog = NO;
        videoFirstPacketLogged = NO;
        videoFirstValidPTSLogged = NO;
        audioFirstPacketLogged = NO;
        engineInitialized = NO;
        firstAudioFrameSeen = NO;
        eofReached = NO;
        decodingStartWallTime = 0;
        decodingStartPTS = 0;
    }
    return self;
}

- (void) dealloc {
    [self stopDecoding];
    [self clear];
    mDecodingQueue = nil;
    pauseCondition = nil;
}

- (void) clear {
    [self logToFile:@"FFmpeg## clear"];
    if (vFrame) { av_frame_free(&vFrame); av_frame_unref(vFrame); vFrame = NULL; }
    if (aFrame) { av_frame_free(&aFrame); av_frame_unref(aFrame); aFrame = NULL; }
    if (pVCtx) { avcodec_close(pVCtx); avcodec_free_context(&pVCtx); pVCtx = NULL; }
    if (pACtx) { avcodec_close(pACtx); avcodec_free_context(&pACtx); pACtx = NULL; }
    if (pFormatContext) { avformat_close_input(&pFormatContext); pFormatContext = NULL; }
    if (swsCtx) { sws_freeContext(swsCtx); swsCtx = NULL; }
    if (dst_data) { av_freep(&dst_data[0]); dst_data[0] = NULL; }
    if ([self.engine isRunning]) { [self.engine stop]; }
    if ([self.player isPlaying]) { [self.player stop]; }
    engineInitialized = NO;
    firstAudioFrameSeen = NO;
}

static int ffmpeg_interrupt_cb(void *ctx) {
    FFmpegDecoder *decoder = (__bridge FFmpegDecoder *)ctx;
    return decoder->decodingStopped ? 1 : 0;
}

static void ffmpeg_log_callback(void* ptr, int level, const char* fmt, va_list vl)
{
    if (level > av_log_get_level()) return;

    char log_buf[1024];
    vsnprintf(log_buf, sizeof(log_buf), fmt, vl);
    
    NSString *logMessage = [NSString stringWithUTF8String:log_buf];

    FFmpegDecoder *decoder = gCurrentDecoder;
    if (decoder) [decoder logToFile:logMessage];
    else NSLog(@"%@", logMessage);
}

- (void)logToFile:(NSString *)text {

    NSLog(@"%@", text);

    if (self->needLog && logFilePath) {
        NSDateFormatter *timestampFormatter = [[NSDateFormatter alloc] init];
        [timestampFormatter setDateFormat:@"HH:mm:ss"];
        NSString *timestamp = [timestampFormatter stringFromDate:[NSDate date]];

        NSString *logText = [NSString stringWithFormat:@"[%@] %@\n", timestamp, text];
        NSData *logData = [logText dataUsingEncoding:NSUTF8StringEncoding];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        if ([fileManager fileExistsAtPath:logFilePath]) {
            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
            if (fileHandle) {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:logData];
                [fileHandle closeFile];
            }
        } else {
            [logData writeToURL:[NSURL fileURLWithPath:logFilePath] atomically:YES];
        }
    }
}

- (void)setupLogFilePath {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *documentsURL = [[fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd_HH-mm-ss"];
    NSString *baseName = [formatter stringFromDate:[NSDate date]];

    NSString *candidate = [baseName stringByAppendingString:@".txt"];
    NSURL *fileURL = [documentsURL URLByAppendingPathComponent:candidate];
    int suffix = 2;
    while ([fileManager fileExistsAtPath:[fileURL path]]) {
        candidate = [NSString stringWithFormat:@"%@ (%d).txt", baseName, suffix++];
        fileURL = [documentsURL URLByAppendingPathComponent:candidate];
    }
    logFilePath = [fileURL path];
}

- (void)startStreaming:(NSString *)url withOptions:(NSDictionary<NSString *, NSString *> *)options
               needLog:(BOOL)needLog needInterrupt:(BOOL)needInterrupt {
    gCurrentDecoder = self;
    self->decodingStopped = NO;
    self->needLog = needLog;
    self->needInterrupt = needInterrupt;
    if (needLog) [self setupLogFilePath];
    self->videoFirstPacketLogged = NO;
    self->videoFirstValidPTSLogged = NO;
    self->audioFirstPacketLogged = NO;
    dispatch_async(mDecodingQueue, ^{
        [self openFile:url withOptions:options];
    });
}

- (void)stopDecoding {
    [self logToFile:@"FFmpeg## stopDecoding"];
    if (currentState != 0) { [self sendCurrentState:0]; }
    [self->queueCondition lock];
    self->decodingStopped = YES;
    [self->queueCondition broadcast];
    [self->queueCondition unlock];
}

- (BOOL)isPlaying {
    return !self->isPaused;
}

- (void)pause {
    [self->queueCondition lock];
    self->isPaused = YES;
    [self->queueCondition unlock];
}

- (void)resume {
    [self->queueCondition lock];
    self->isPaused = NO;
    [self->queueCondition signal];
    [self->queueCondition unlock];
}

- (void)seek:(double)seconds {
    [self logToFile:@"FFmpeg## isSeeking"];
    [self->queueCondition lock];
    self->seekTarget = seconds;
    self->isSeeking = YES;
    [self->queueCondition signal];
    [self->queueCondition unlock];
}

- (void)sendCurrentState:(PlayerState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_delegate receivedState:state];
    });
}

- (void)openFile:(NSString *)url withOptions:(NSDictionary<NSString *, NSString *> *)options {
    [self logToFile:[NSString stringWithFormat:@"FFmpeg## SPM Viersion: %@", FFMPEG_DECODER_VERSION]];
    [self logToFile:[NSString stringWithFormat:@"FFmpeg## openFile: %@", url]];

    if (currentState != 0) { [self sendCurrentState:0]; }
    av_log_set_callback(ffmpeg_log_callback);
    av_log_set_level(AV_LOG_DEBUG);
    avformat_network_init();
    pFormatContext = avformat_alloc_context();
    if (needInterrupt) {
        pFormatContext->interrupt_callback.callback = ffmpeg_interrupt_cb;
        pFormatContext->interrupt_callback.opaque = (__bridge void *)self;
    }
    AVDictionary *opts = 0;
    
    for (NSString *key in options) {
        NSString *value = options[key];
        av_dict_set(&opts, [key UTF8String], [value UTF8String], 0);
    }

    //미디어 파일 열기
    //파일의 헤더로 부터 파일 포맷에 대한 정보를 읽어낸 뒤 첫번째 인자 (AVFormatContext) 에 저장.
    //그 뒤의 인자들은 각각 Input Source (스트리밍 URL이나 파일경로), Input Format, demuxer의 추가옵션.
    int ret = avformat_open_input(&pFormatContext, [url UTF8String], NULL, &opts);
    
    if (ret != 0) {
        [self logToFile:@"FFmpeg## File Open Failed"];
        [self stopDecoding];
        if (currentState != 7) { [self sendCurrentState:7]; }
        return;
    }
    
    // 비디오 스트림 못찾으면 재시도
    int maxRetry = 3;
    for (int i = 0; i < maxRetry; i++) {
        ret = avformat_find_stream_info(pFormatContext, NULL);
        
        BOOL hasVideoParams = NO;
        for (int s = 0; s < pFormatContext->nb_streams; s++) {
            AVStream *stream = pFormatContext->streams[s];
            if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                if (stream->codecpar->width > 0 && stream->codecpar->height > 0) {
                    hasVideoParams = YES;
                    break;
                }
            }
        }
        
        if (hasVideoParams) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## Stream info found on attempt %d", i + 1]];
            break;
        }
        
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## Retrying find_stream_info (%d/%d)...", i + 1, maxRetry]];

        // 컨텍스트 리셋 후 재시도
        avformat_close_input(&pFormatContext);
        pFormatContext = avformat_alloc_context();
        pFormatContext->interrupt_callback.callback = ffmpeg_interrupt_cb;
        pFormatContext->interrupt_callback.opaque = (__bridge void *)self;
        
        ret = avformat_open_input(&pFormatContext, [url UTF8String], NULL, &opts);
        if (ret != 0) { break; }
    }
    
    if (ret < 0 ) {
        [self logToFile:@"FFmpeg## Fail to get Stream Info"];
        [self stopDecoding];
        return;
    }
    [self openCodec];
}

- (void) openCodec {
    vidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    aidx = av_find_best_stream(pFormatContext, AVMEDIA_TYPE_AUDIO, -1, vidx, NULL, 0);
    
    // 비디오 코덱 오픈
    if (vidx >= 0) {
        pVStream = pFormatContext->streams[vidx];
        pVPara = pVStream->codecpar;
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## 비디오 codec_id: %d (%s)", pVPara->codec_id, avcodec_get_name(pVPara->codec_id)]];

        pVCodec = (AVCodec*) avcodec_find_decoder(pVPara->codec_id);
        if (!pVCodec) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## 비디오 코덱을 찾을 수 없습니다. codec_id = %d", pVPara->codec_id]];;
            if (currentState != 7) { [self sendCurrentState:7]; }
            return;
        } else {
            pVCtx = avcodec_alloc_context3(pVCodec);
            avcodec_parameters_to_context(pVCtx, pVPara);
            avcodec_open2(pVCtx, pVCodec, NULL);
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## 비디오 코덱 : %d, %s(%s)\n",
                             pVCodec->id,
                             pVCodec->name,
                             pVCodec->long_name ? pVCodec->long_name : "N/A"]];
        }
    }
    // 오디오 코덱 오픈
    if (aidx >= 0) {
        pAStream = pFormatContext->streams[aidx];
        pAPara = pAStream->codecpar;
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## 오디오 codec_id: %d (%s)", pAPara->codec_id, avcodec_get_name(pAPara->codec_id)]];

        pACodec = (AVCodec*) avcodec_find_decoder(pAPara->codec_id);
        if (!pACodec) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## 오디오 코덱을 찾을 수 없습니다. codec_id = %d", pAPara->codec_id]];
            if (currentState != 7) { [self sendCurrentState:7]; }
            return;
        } else {
            pACtx = avcodec_alloc_context3(pACodec);
            avcodec_parameters_to_context(pACtx, pAPara);
            avcodec_open2(pACtx, pACodec, NULL);
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## 오디오 코덱 : %d, %s(%s)\n",
                             pACodec->id,
                             pACodec->name,
                             pACodec->long_name ? pACodec->long_name : "N/A"]];
        }
    }
    
    [self decoding];
}

//파일로부터 인코딩 된 비디오, 오디오 데이터를 읽어서 packet에 저장하는 함수
// Read thread: 네트워크에서 패킷을 읽어 큐에 쌓음. Decode thread와 분리되어 pause 중에도 계속 실행.
- (void)readThread {
    while (!self->decodingStopped) {
        AVPacket *pkt = av_packet_alloc();
        int ret = av_read_frame(self->pFormatContext, pkt);

        if (ret < 0) {
            av_packet_free(&pkt);
            if (ret == AVERROR_EOF) {
                [self logToFile:@"FFmpeg## readThread EOF"];
                // 즉시 종료하지 않고 플래그만 세팅 → decode thread가 큐를 모두 소진한 후 종료
                [self->queueCondition lock];
                self->eofReached = YES;
                [self->queueCondition signal];
                [self->queueCondition unlock];
            } else {
                [self logToFile:[NSString stringWithFormat:@"FFmpeg## readThread error: %d", ret]];
            }
            break;
        }

        [self->queueCondition lock];
        // 큐가 꽉 차면 decode thread가 소비할 때까지 대기 (최대 5000패킷 ≈ 60초 버퍼)
        while (self->packetQueue.count >= 5000 && !self->decodingStopped) {
            [self->queueCondition wait];
        }
        if (!self->decodingStopped) {
            [self->packetQueue addObject:[NSValue valueWithPointer:pkt]];
            [self->queueCondition signal];
        } else {
            av_packet_free(&pkt);
        }
        [self->queueCondition unlock];
    }

    // decode thread가 대기 중일 수 있으므로 깨워서 종료 확인하게 함
    [self->queueCondition lock];
    [self->queueCondition broadcast];
    [self->queueCondition unlock];
}

- (void)decoding {
    if (currentState != 1) { [self sendCurrentState:1]; }
    vFrame = av_frame_alloc();
    aFrame = av_frame_alloc();
    packetQueue = [NSMutableArray array];

    outputFrameSize = CGSizeMake(self->pVCtx->width, self->pVCtx->height);
    [self logToFile:[NSString stringWithFormat:@"FFmpeg## Video Resolution: %.0f x %.0f", outputFrameSize.width, outputFrameSize.height]];

    // Read thread 시작: pause 중에도 독립적으로 패킷 수신 지속 → decoder state 보존, IDR 불필요
    dispatch_async(mReadQueue, ^{ [self readThread]; });

    if (currentState != 2) { [self sendCurrentState:2]; }

    while (!self->decodingStopped) {

        [self->queueCondition lock];

        BOOL wasPaused = NO;
        // pause 중이거나 큐가 비어있으면 대기
        while (!self->decodingStopped && (self->isPaused || self->packetQueue.count == 0)) {

            // 큐가 비었고 EOF에 도달했으면 → 영상 끝까지 재생 완료
            if (!self->isPaused && self->packetQueue.count == 0 && self->eofReached) {
                [self->queueCondition unlock];
                [self stopDecoding];
                if (self->currentState != 6) { [self sendCurrentState:6]; }
                goto decoding_done;
            }

            if (self->isPaused) {
                wasPaused = YES;
                if (self->isPlaying) {
                    self->isPlaying = NO;
                    if (self->_player.isPlaying) { [self->_player stop]; }
                    if (self->currentState != 5) { [self sendCurrentState:5]; }
                }
                if (self->isSeeking) {
                    [self logToFile:@"FFmpeg## readSeek"];
                    // 큐에 남은 패킷 전부 폐기 후 seek
                    for (NSValue *w in self->packetQueue) {
                        AVPacket *p = (AVPacket *)[w pointerValue];
                        av_packet_free(&p);
                    }
                    [self->packetQueue removeAllObjects];
                    double target = self->seekTarget;
                    self->isSeeking = NO;
                    [self->queueCondition signal]; // read thread 깨우기 (큐 공간 생김)
                    [self->queueCondition unlock];

                    [self readSeek:target];
                    if (self->pVCtx) avcodec_flush_buffers(self->pVCtx);
                    if (self->pACtx) avcodec_flush_buffers(self->pACtx);
                    self->firstAudioFrameSeen = NO;

                    [self->queueCondition lock];
                    wasPaused = NO;
                }
            }

            [self->queueCondition wait];
        }

        if (self->decodingStopped) {
            [self->queueCondition unlock];
            break;
        }

        // pause → resume 전환: A/V sync 재보정
        if (!self->isPlaying) {
            self->isPlaying = YES;
            if (wasPaused) { self->firstAudioFrameSeen = NO; }
            if (self.player && !self.player.isPlaying) { [self.player play]; }
            if (self->currentState != 4) { [self sendCurrentState:4]; }
            if (self->currentState != 2) { [self sendCurrentState:2]; }
        }

        // 큐에서 패킷 꺼내기
        NSValue *wrapper = self->packetQueue.firstObject;
        [self->packetQueue removeObjectAtIndex:0];
        [self->queueCondition signal]; // read thread에 큐 공간 생겼음을 알림
        [self->queueCondition unlock];

        AVPacket *pkt = (AVPacket *)[wrapper pointerValue];

        [self->_delegate receivedVideoSize:outputFrameSize];

        NSString *trackTag = (pkt->stream_index == vidx) ? @"V" : ((pkt->stream_index == aidx) ? @"A" : @"?");
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## [PKT.%@] pts=%lld dts=%lld", trackTag, (long long)pkt->pts, (long long)pkt->dts]];

        if (pkt->stream_index == vidx) {
            if ([self sendPacket:pVCtx packet:pkt] >= 0) {
                int ret = [self receiveFrame:pVCtx frame:vFrame];
                if (ret >= 0) {
                    if (!videoFirstPacketLogged) {
                        videoFirstPacketLogged = YES;
                        AVRational tb = pVStream->time_base;
                        [self logToFile:[NSString stringWithFormat:@"FFmpeg## [Video] first frame — frame_pts=%lld best_effort=%lld pkt_pts=%lld tb=%d/%d",
                            (long long)vFrame->pts, (long long)vFrame->best_effort_timestamp, (long long)pkt->pts, tb.num, tb.den]];
                    }
                    if (!videoFirstValidPTSLogged) {
                        int64_t rawPTS = (vFrame->pts != AV_NOPTS_VALUE) ? vFrame->pts : vFrame->best_effort_timestamp;
                        AVRational tb = pVStream->time_base;
                        if (rawPTS != AV_NOPTS_VALUE && tb.den > 0) {
                            videoFirstValidPTSLogged = YES;
                            double ptsSec = (double)rawPTS * tb.num / tb.den;
                            [self logToFile:[NSString stringWithFormat:@"FFmpeg## [Video] first valid PTS — frame_pts=%lld best_effort=%lld pts_sec=%.4f",
                                (long long)vFrame->pts, (long long)vFrame->best_effort_timestamp, ptsSec]];
                        }
                    }
                    if (aidx < 0) { // 오디오가 없는 영상(타임랩스 등)
                        [self getCurrentTime:vFrame stream:pVStream];
                    }
                    [self drawImage];
                }
            }
        }
        if (pkt->stream_index == aidx) {
            if ([self sendPacket:pACtx packet:pkt] >= 0) {
                int ret = [self receiveFrame:pACtx frame:aFrame];
                if (ret >= 0) {
                    if (!audioFirstPacketLogged) {
                        int64_t rawPTS = (aFrame->pts != AV_NOPTS_VALUE) ? aFrame->pts : aFrame->best_effort_timestamp;
                        if (rawPTS != AV_NOPTS_VALUE && pAStream) {
                            audioFirstPacketLogged = YES;
                            AVRational tb = pAStream->time_base;
                            double ptsSec = (double)rawPTS * tb.num / tb.den;
                            int64_t dts = aFrame->pkt_dts;
                            [self logToFile:[NSString stringWithFormat:@"FFmpeg## [Audio] first packet — pts=%lld dts=%lld tb=%d/%d pts_sec=%.4f sampleRate=%dHz",
                                (long long)rawPTS, (long long)dts, tb.num, tb.den, ptsSec, aFrame->sample_rate]];
                        }
                    }
                    // AV sync: audio PTS 기반으로 decode loop 속도 제어
                    int64_t syncPTS = (aFrame->pts != AV_NOPTS_VALUE) ? aFrame->pts : aFrame->best_effort_timestamp;
                    if (syncPTS != AV_NOPTS_VALUE && pAStream) {
                        double ptsSec = syncPTS * av_q2d(pAStream->time_base);
                        struct timeval tv;
                        gettimeofday(&tv, NULL);
                        double now = tv.tv_sec + tv.tv_usec / 1e6;
                        if (!firstAudioFrameSeen) {
                            firstAudioFrameSeen = YES;
                            decodingStartWallTime = now;
                            decodingStartPTS = ptsSec;
                        } else {
                            double sleepSec = (ptsSec - decodingStartPTS) - (now - decodingStartWallTime);
                            if (sleepSec > 0.001 && sleepSec < 1.0) {
                                usleep((useconds_t)(sleepSec * 1e6));
                            }
                        }
                    }
                    [self getCurrentTime:aFrame stream:pAStream];
                    [self drawAudio];
                }
            }
        }

        av_packet_free(&pkt);
    }

decoding_done:
    // Read thread가 av_read_frame 중일 수 있으므로 완전히 종료될 때까지 대기.
    // clear()에서 pFormatContext를 해제하기 전에 반드시 read thread가 끝나야 함.
    dispatch_sync(mReadQueue, ^{});
    [self clear];
}

- (int) readFrame:(AVPacket *)packet {

    int ret = -1;
    if (pFormatContext != NULL) {
        @try {
            ret = av_read_frame(pFormatContext, packet);
            
            if (ret == AVERROR_EOF) {
                [self logToFile:[NSString stringWithFormat:@"FFmpeg## readFrame EOF"]];
                [self stopDecoding];
                if (currentState != 6) { [self sendCurrentState:6]; }
            }
        } @catch (NSException *exception) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_frame error: %@", exception]];
            if (currentState != 7) { [self sendCurrentState:7]; }
        }
    }
    return ret;
}

- (int) sendPacket:(AVCodecContext *)ctx packet:(AVPacket *)packet {
    
    int ret = -1;
    if(ctx != NULL) {
        @try {
            ret = avcodec_send_packet(ctx, packet);
        } @catch (NSException *exception) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## avcodec_send_packet error"]];
            if (currentState != 7) { [self sendCurrentState:7]; }
        }
    }
    return ret;
}

- (int) receiveFrame:(AVCodecContext *)ctx frame:(AVFrame *)frame {
    
    int ret = -1;
    if (ctx != NULL) {
        @try {
            ret = avcodec_receive_frame(ctx, frame);
        } @catch (NSException *exception) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## avcodec_receive_frame error"]];
            if (currentState != 7) { [self sendCurrentState:7]; }
        }
    }
    return ret;
}

- (int) readPlay {
    
    int ret = -1;
    
    @try {
        isPlaying = YES;
        ret = av_read_play(pFormatContext);
        if (ret < 0) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_play error %d, errno? [%d]", ret, errno]];
            if (currentState != 7) { [self sendCurrentState:7]; }
        } else {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_play: %d", ret]];
            if (currentState != 4) { [self sendCurrentState:4]; }
        }
    } @catch (NSException *exception) {
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_play error %@", exception]];
        if (currentState != 7) { [self sendCurrentState:7]; }
    }
    
    return ret;
}

- (int) readPause {
    
    int ret = -1;
    
    @try {
        isPlaying = NO;
        ret = av_read_pause(pFormatContext);
        if (ret < 0) {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_pause error %d, errno? [%d]", ret, errno]];
            if (currentState != 7) { [self sendCurrentState:7]; }
        } else {
            [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_pause: %d", ret]];
            if (currentState != 5) { [self sendCurrentState:5]; }
        }
    } @catch (NSException *exception) {
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_read_pause error %@", exception]];
        if (currentState != 7) { [self sendCurrentState:7]; }
    }
    
    return ret;
}

- (int)readSeek:(double)seconds {
    int ret = -1;

    @try {
        if (seconds < 0 || !pFormatContext) {
            [self logToFile:@"FFmpeg## Invalid seek time or context is NULL"];
            if (currentState != 7) { [self sendCurrentState:7]; }
            return -1;
        }

        lastRescaledPTS = -1;
        ptsOffset = 0;
        hasPendingSeek = YES;
        pendingSeekSeconds = seconds;
        firstAudioFrameSeen = NO;

        int64_t timestamp = (int64_t)(seconds * AV_TIME_BASE);

        // 디코더 상태 초기화
        avcodec_flush_buffers(pVCtx);
        avcodec_flush_buffers(pACtx);

        // seek 수행
        ret = av_seek_frame(pFormatContext, -1, timestamp, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY);
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_seek_frame to %.2f sec (ts: %lld): %d", seconds, timestamp, ret]];

        if (ret < 0) {
            [self logToFile:@"FFmpeg## Seek failed"];
            if (currentState != 7) { [self sendCurrentState:7]; }
            hasPendingSeek = NO;
        } else {
            hasEverSeeked = YES;
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self->_delegate receivedSeekingState:YES];
            });
        }
    } @catch (NSException *exception) {
        [self logToFile:[NSString stringWithFormat:@"FFmpeg## av_seek_frame exception: %@", exception]];
        if (currentState != 7) { [self sendCurrentState:7]; }
        ret = -1;
        hasPendingSeek = NO;
    }

    return ret;
}

- (void)getCurrentTime:(AVFrame *)frame stream:(AVStream *)stream {
    if (!frame || !stream) return;

    if (self->hasEverSeeked) {
        // seek 이후: PTS discontinuity 보정 로직 사용
        int64_t currentTime = 0;
        int64_t totalDuration = pFormatContext->duration / AV_TIME_BASE;

        int64_t raw_pts = (frame->pts != AV_NOPTS_VALUE) ? frame->pts : frame->best_effort_timestamp;
        if (raw_pts == AV_NOPTS_VALUE) {
            currentTime = (lastRescaledPTS != -1) ? (lastRescaledPTS + ptsOffset) : 0;
        } else {
            int64_t rescaled_pts = av_rescale_q(raw_pts, stream->time_base, (AVRational){1, 1});

            if (hasPendingSeek) {
                ptsOffset = (int64_t)pendingSeekSeconds - rescaled_pts;
                lastRescaledPTS = rescaled_pts;
                hasPendingSeek = NO;
            } else {
                if (lastRescaledPTS != -1 && rescaled_pts < lastRescaledPTS) {
                    ptsOffset += lastRescaledPTS;
                }
                lastRescaledPTS = rescaled_pts;
            }

            currentTime = rescaled_pts + ptsOffset;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate receivedCurrentTime:currentTime duration:totalDuration];
        });

    } else {
        // seek 전: 단순 ms 변환 로직 사용
        if (!frame->pkt_dts && !frame->pts) return;

        int64_t pts = (frame->pts == AV_NOPTS_VALUE) ? frame->pkt_dts : frame->pts;
        if (pts == AV_NOPTS_VALUE) return;

        int64_t currentTime = av_rescale_q(pts, stream->time_base, (AVRational){1, 1000});

        int64_t duration = 0;
        if (pFormatContext && pFormatContext->duration > 0) {
            duration = av_rescale_q(pFormatContext->duration, AV_TIME_BASE_Q, (AVRational){1, 1000});
        }

        currentTime = currentTime / 1000;
        duration = duration / 1000;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate receivedCurrentTime:currentTime duration:duration];
        });
    }
}

- (void)drawImage {
    if (self->decodingStopped) return;
    
    int width = vFrame->width;
    int height = vFrame->height;

    // 1️⃣ sws_scale에서 RGBA로 출력 (초기화 시 한 번만)
    if (swsCtx == NULL) {
        static int sws_flags = SWS_FAST_BILINEAR;
        swsCtx = sws_getContext(
            pVCtx->width,
            pVCtx->height,
            pVCtx->pix_fmt,
            outputFrameSize.width,
            outputFrameSize.height,
            AV_PIX_FMT_RGBA,
            sws_flags,
            NULL, NULL, NULL
        );

        av_image_alloc(dst_data, dst_linesize,
                       pVCtx->width,
                       pVCtx->height,
                       AV_PIX_FMT_RGBA, 1);
    }

    // 2️⃣ YUV -> RGBA 변환
    sws_scale(swsCtx,
              (uint8_t const * const *)vFrame->data,
              vFrame->linesize,
              0,
              height,
              dst_data,
              dst_linesize);

    NSData *imageData = [NSData dataWithBytes:dst_data[0] length:dst_linesize[0] * height];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->decodingStopped) return;
        
        // 3️⃣ CIImage 생성
        CIImage *ciImage = [CIImage imageWithBitmapData:imageData
                                            bytesPerRow:dst_linesize[0]
                                                  size:CGSizeMake(width, height)
                                                format:kCIFormatRGBA8
                                            colorSpace:CGColorSpaceCreateDeviceRGB()];
        [self->_delegate receivedDecodedCIImage:ciImage];
    });
}


- (void) drawAudio {
    if (self->decodingStopped) return;

    int channels = pACtx->ch_layout.nb_channels;
    AudioChannelLayoutTag layoutTag = (channels == 1) ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;
    AVAudioChannelLayout *channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:layoutTag];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:aFrame->sample_rate
                                                           interleaved:NO
                                                         channelLayout:channelLayout];

    // 엔진은 한 번만 초기화 (버퍼 언더런 시 재초기화 금지)
    if (!engineInitialized) {
        engineInitialized = YES;
        self.engine = [[AVAudioEngine alloc] init];
        self.player = [[AVAudioPlayerNode alloc] init];
        self.player.volume = 1.0;
        [self.engine attachNode:self.player];
        [self.engine connect:self.player to:self.engine.mainMixerNode format:format];
        [self.engine prepare];
        NSError *error;
        BOOL success = [self.engine startAndReturnError:&error];
        NSAssert(success, @"couldn't start engine, %@", [error localizedDescription]);
        [self.player play];
    } else if (self.player && !self.player.isPlaying) {
        // pause 후 resume 시 player 재시작
        [self.player play];
    }

    int nb_samples = aFrame->nb_samples;
    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:nb_samples];
    pcmBuffer.frameLength = nb_samples;

    // planar(non-interleaved) 포맷: 채널별로 data[ch]에 분리 저장됨
    int numChannels = (int)MIN(channels, (int)format.channelCount);
    for (int ch = 0; ch < numChannels; ch++) {
        if (aFrame->data[ch]) {
            memcpy(pcmBuffer.floatChannelData[ch], aFrame->data[ch], nb_samples * sizeof(float));
        }
    }

    [self.player scheduleBuffer:pcmBuffer completionHandler:nil];
}

@end
