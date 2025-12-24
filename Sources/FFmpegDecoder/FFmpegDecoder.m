#import "FFmpegDecoder.h"

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
    BOOL isPaused, isPlaying;
    NSCondition *pauseCondition;
    int64_t lastRescaledPTS;      // 이전 프레임 pts (rescaled)
    int64_t ptsOffset;           // 누적 offset
    int currentState;
}

+ (instancetype)sharedInstance {
    static FFmpegDecoder *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FFmpegDecoder alloc] init];
    });
    return sharedInstance;
}

- (id) init {
    if (self = [super init]) {
        mDecodingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        pauseCondition = [[NSCondition alloc] init];
        decodingStopped = NO;
        isPaused = NO;
        isPlaying = YES;
        lastRescaledPTS = -1;
        ptsOffset = 0;
        currentState = 0;
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
    if (vFrame) { av_frame_free(&vFrame); av_frame_unref(vFrame); vFrame = NULL; }
    if (aFrame) { av_frame_free(&aFrame); av_frame_unref(aFrame); aFrame = NULL; }
    if (pVCtx) { avcodec_close(pVCtx); avcodec_free_context(&pVCtx); pVCtx = NULL; }
    if (pACtx) { avcodec_close(pACtx); avcodec_free_context(&pACtx); pACtx = NULL; }
    if (pFormatContext) { avformat_close_input(&pFormatContext); pFormatContext = NULL; }
    if (swsCtx) { sws_freeContext(swsCtx); swsCtx = NULL; }
    if (dst_data) { av_freep(&dst_data[0]); dst_data[0] = NULL; }
    if ([self.engine isRunning]) { [self.engine stop]; }
    if ([self.player isPlaying]) { [self.player stop]; }
}

- (void)startStreaming:(NSString *)url withOptions:(NSDictionary<NSString *, NSString *> *)options {
    decodingStopped = NO;
    dispatch_async(mDecodingQueue, ^{
        [self openFile:url withOptions:options];
    });
}

- (void)stopDecoding {
    NSLog(@"FFmpeg## stopDecoding");
    if (currentState != 0) { [self sendCurrentState:0]; }
    [self->pauseCondition lock];
    self->decodingStopped = YES;
    [self->pauseCondition signal];
    [self->pauseCondition unlock];
}

- (BOOL)isPlaying {
    return !self->isPaused;
}

- (void)pause {
    dispatch_async(mDecodingQueue, ^{
        [self->pauseCondition lock];
        self->isPaused = YES;
        [self->pauseCondition unlock];
    });
}

- (void)resume {
    dispatch_async(mDecodingQueue, ^{
        [self->pauseCondition lock];
        self->isPaused = NO;
        [self->pauseCondition signal];
        [self->pauseCondition unlock];
    });
}

- (void)sendCurrentState:(int)state {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_delegate receivedState:state];
    });
}

- (void)openFile:(NSString *)url withOptions:(NSDictionary<NSString *, NSString *> *)options {
    NSLog(@"FFmpeg## openFile: %@", url);
    
    if (currentState != 0) { [self sendCurrentState:0]; }
    av_log_set_level(AV_LOG_DEBUG);
    avformat_network_init();
    pFormatContext = avformat_alloc_context();
    
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
        NSLog(@"FFmpeg## File Open Failed");
        [self stopDecoding];
        if (currentState != 7) { [self sendCurrentState:7]; }
        return;
    }
    
    ret = avformat_find_stream_info(pFormatContext, NULL);
    
    if (ret < 0 ) {
        NSLog(@"FFmpeg## Fail to get Stream Info");
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
        NSLog(@"FFmpeg## 비디오 codec_id: %d (%s)", pVPara->codec_id, avcodec_get_name(pVPara->codec_id));
        
        pVCodec = (AVCodec*) avcodec_find_decoder(pVPara->codec_id);
        if (!pVCodec) {
            NSLog(@"FFmpeg## 비디오 코덱을 찾을 수 없습니다. codec_id = %d", pVPara->codec_id);
            if (currentState != 7) { [self sendCurrentState:7]; }
            return;
        } else {
            pVCtx = avcodec_alloc_context3(pVCodec);
            avcodec_parameters_to_context(pVCtx, pVPara);
            avcodec_open2(pVCtx, pVCodec, NULL);
            NSLog(@"FFmpeg## 비디오 코덱 : %d, %s(%s)\n",
                  pVCodec->id,
                  pVCodec->name,
                  pVCodec->long_name ? pVCodec->long_name : "N/A");
        }
    }
    // 오디오 코덱 오픈
    if (aidx >= 0) {
        pAStream = pFormatContext->streams[aidx];
        pAPara = pAStream->codecpar;
        NSLog(@"FFmpeg## 오디오 codec_id: %d (%s)", pAPara->codec_id, avcodec_get_name(pAPara->codec_id));
        
        pACodec = (AVCodec*) avcodec_find_decoder(pAPara->codec_id);
        if (!pACodec) {
            NSLog(@"FFmpeg## 오디오 코덱을 찾을 수 없습니다. codec_id = %d", pAPara->codec_id);
            if (currentState != 7) { [self sendCurrentState:7]; }
            return;
        } else {
            pACtx = avcodec_alloc_context3(pACodec);
            avcodec_parameters_to_context(pACtx, pAPara);
            avcodec_open2(pACtx, pACodec, NULL);
            NSLog(@"FFmpeg## 오디오 코덱 : %d, %s(%s)\n",
                  pACodec->id,
                  pACodec->name,
                  pACodec->long_name ? pACodec->long_name : "N/A");
        }
    }
    
    [self decoding];
}

//파일로부터 인코딩 된 비디오, 오디오 데이터를 읽어서 packet에 저장하는 함수
- (void) decoding {
    
    if (currentState != 1) { [self sendCurrentState:1]; }
    vFrame = av_frame_alloc();
    aFrame = av_frame_alloc();
    packet = *av_packet_alloc();
    
    outputFrameSize = CGSizeMake(self->pVCtx->width, self->pVCtx->height);
    NSLog(@"FFmpeg## Video Resolution: %.0f x %.0f", outputFrameSize.width, outputFrameSize.height);
        
    while (!self->decodingStopped && pFormatContext != NULL) {
        
        if (currentState != 2) { [self sendCurrentState:2]; }
        
        while (!self->decodingStopped && [self readFrame:&packet] >= 0) {
            
            [self->_delegate receivedVideoSize:outputFrameSize];
            
            [self->pauseCondition lock];
            
            while (!self->decodingStopped && self->isPaused) {
                [self readPause];
                if (_player.isPlaying) {
                    [_player pause];
                }
                [self->pauseCondition wait];
            }
            [self->pauseCondition unlock];
            
            if (!self->isPlaying) {
                [self readPlay];
                if (currentState != 2) { [self sendCurrentState:2]; }
            }

            if (packet.stream_index == vidx) {
                if ([self sendPacket:pVCtx packet:&packet] >= 0) {
                    int ret = [self receiveFrame:pVCtx frame:vFrame];
                    if (ret >= 0) {
                        [self getCurrentTime:vFrame stream:pVStream];
                        [self drawImage];
                    }
                }
            }
            if (packet.stream_index == aidx) {
                if ([self sendPacket:pACtx packet:&packet] >= 0) {
                    int ret = [self receiveFrame:pACtx frame:aFrame];
                    if (ret >= 0) {
                        [self drawAudio];
                    }
                }
            }
            av_packet_unref(&packet);
        }
    }
    [self clear];
}

- (int) readFrame:(AVPacket *)packet {

    int ret = -1;
    if (pFormatContext != NULL) {
        @try {
            ret = av_read_frame(pFormatContext, packet);
            
            if (ret == AVERROR_EOF) {
                NSLog(@"FFmpeg## readFrame EOF");
                [self stopDecoding];
                if (currentState != 6) { [self sendCurrentState:6]; }
            }
        } @catch (NSException *exception) {
            NSLog(@"FFmpeg## av_read_frame error: %@", exception);
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
            NSLog(@"FFmpeg## avcodec_send_packet error");
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
            NSLog(@"FFmpeg## avcodec_receive_frame error");
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
            NSLog(@"FFmpeg## av_read_play error %d, errno? [%d]", ret, errno);
            if (currentState != 7) { [self sendCurrentState:7]; }
        } else {
            NSLog(@"FFmpeg## av_read_play: %d", ret);
            if (currentState != 4) { [self sendCurrentState:4]; }
        }
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_read_play error %@", exception);
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
            NSLog(@"FFmpeg## av_read_pause error %d, errno? [%d]", ret, errno);
            if (currentState != 7) { [self sendCurrentState:7]; }
        } else {
            NSLog(@"FFmpeg## av_read_pause: %d", ret);
            if (currentState != 5) { [self sendCurrentState:5]; }
        }
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_read_pause error %@", exception);
        if (currentState != 7) { [self sendCurrentState:7]; }
    }
    
    return ret;
}

- (void)getCurrentTime:(AVFrame *)frame stream:(AVStream *)stream {
    if (!frame || !stream) return;
    if (!frame->pkt_dts && !frame->pts) return;

    // PTS 기준값
    int64_t pts = (frame->pts == AV_NOPTS_VALUE) ? frame->pkt_dts : frame->pts;
    if (pts == AV_NOPTS_VALUE) return;

    // stream time_base → ms 로 변환
    int64_t currentTime = av_rescale_q(pts, stream->time_base, (AVRational){1, 1000});

    int64_t duration = 0;
    
    if (pFormatContext && pFormatContext->duration > 0) {
        duration = av_rescale_q(pFormatContext->duration, AV_TIME_BASE_Q, (AVRational){1, 1000});
    }

    currentTime = currentTime / 1000;
    duration = duration / 1000;
    
    NSLog(@"FFmpeg## currentTime %lld, duration %lld", currentTime, duration);
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_delegate receivedCurrentTime:currentTime duration:duration];
    });
}

- (void)drawImage {
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

    // 3️⃣ CIImage 생성
    CIImage *ciImage = [CIImage imageWithBitmapData:[NSData dataWithBytesNoCopy:dst_data[0]
                                                                         length:dst_linesize[0]*height
                                                                   freeWhenDone:NO]
                                      bytesPerRow:dst_linesize[0]
                                            size:CGSizeMake(width, height)
                                          format:kCIFormatRGBA8
                                      colorSpace:CGColorSpaceCreateDeviceRGB()];

    dispatch_sync(dispatch_get_main_queue(), ^{
        [self->_delegate receivedDecodedCIImage:ciImage];
    });
}


- (void) drawAudio {
    AVAudioChannelLayout *channelLayout = [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Stereo];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                             sampleRate:aFrame->sample_rate
                                                           interleaved:NO
                                                         channelLayout:channelLayout];
    
    if (![self.player isPlaying]) {
        self.engine = [[AVAudioEngine alloc] init];
        self.player = [[AVAudioPlayerNode alloc] init];
        self.player.volume = 1.0;
        [self.engine attachNode:self.player];

        AVAudioMixerNode *mainMixer = [self.engine mainMixerNode];
        
        [self.engine connect:self.player to:mainMixer format:format];
        
        if (!self.engine.isRunning) {
            [self.engine prepare];
            NSError *error;
            BOOL success;
            success = [self.engine startAndReturnError:&error];
            NSAssert(success, @"couldn't start engine, %@", [error localizedDescription]);
        }
        [self.player play];
    }
    
    NSData *data = [self playAudioFrame:aFrame];
    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc]
                                  initWithPCMFormat:format
                                  frameCapacity:(uint32_t)(data.length)
                                  /format.streamDescription->mBytesPerFrame];

    pcmBuffer.frameLength = pcmBuffer.frameCapacity;

    [data getBytes:*pcmBuffer.floatChannelData length:data.length];

    [self.player scheduleBuffer:pcmBuffer completionHandler:nil];
}

- (NSData *)playAudioFrame:(AVFrame *)audioFrame {
    
    int bytesPerSample = av_get_bytes_per_sample(pACtx->sample_fmt);
    int channels = pACtx->ch_layout.nb_channels; // 최신 FFmpeg (5.x 이상)에서는 ch_layout 사용
    int dataSize = bytesPerSample * channels * audioFrame->nb_samples;

    NSData *audioData = [NSData dataWithBytes:audioFrame->data[0] length:dataSize];
    return audioData;
}

@end
