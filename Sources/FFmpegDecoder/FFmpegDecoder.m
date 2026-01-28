#import "FFmpegDecoder.h"

@implementation FFmpegDecoder {
    // MARK: FFmpeg Core (리소스 관리)
    AVFormatContext   *pFormatContext;
    AVCodecContext    *pVCtx, *pACtx;
    AVCodecParameters *pVPara, *pAPara;
    AVCodec           *pVCodec, *pACodec;
    AVStream          *pVStream, *pAStream;
    AVPacket           packet;
    AVFrame           *vFrame, *aFrame;
    struct SwsContext *swsCtx;
    int                vidx, aidx;

    // MARK: Playback Control (재생 및 스레드 상태)
    NSCondition      *pauseCondition;
    dispatch_queue_t  mDecodingQueue;
    int               currentState;
    BOOL              decodingStopped;
    BOOL              isPaused;
    BOOL              isPlaying;
    BOOL              isSeeking;

    // MARK: Time Sync & Seek (시간 동기화 핵심)
    double  videoStartClock;      // 재생 시작 시점의 시스템 절대 시각
    int64_t videoStartPTS;        // 첫 프레임의 기준 PTS
    double  pauseStartTime;       // 일시정지 버튼 누른 시각
    
    double  seekTarget;           // 사용자가 이동하려는 목표 시간(초)
    BOOL    hasPendingSeek;       // Seek 후 첫 프레임 보정 대기 상태
    double  pendingSeekSeconds;   // 보정용 목표 초
    BOOL    needResetClockAfterSeek;
    
    int64_t lastRescaledPTS;      // 이전 프레임 PTS (정규화된 값)
    int64_t ptsOffset;            // 타임라인 단절 시 누적할 오프셋
    int64_t lastVideoPTS;         // 마지막 처리된 비디오 PTS

    BOOL               audioReady;

    // MARK: Video Output & Image Processing
    CGSize  outputFrameSize;
    double currentBrightness, currentContrast;
    float prevContrast, prevBrightness;
    
    // YUV->RGB 변환이나 필터 적용 시 사용하는 버퍼
    uint8_t *dst_data[4];
    int      dst_linesize[4];
}

+ (instancetype)sharedInstance {
    static FFmpegDecoder *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[FFmpegDecoder alloc] init];
    });
    return sharedInstance;
}

- (id)init {
    self = [super init];
    if (self) {
        // 제어 관련
        mDecodingQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        pauseCondition = [[NSCondition alloc] init];
        
        // 상태 초기화
        decodingStopped = NO;
        isPaused        = NO;
        isSeeking       = NO;
        isPlaying       = YES;
        currentState    = 0;

        // 시간/PTS 관련 초기화
        lastRescaledPTS = -1;
        ptsOffset       = 0;
        lastVideoPTS    = -1;
        videoStartPTS   = AV_NOPTS_VALUE;
        hasPendingSeek  = NO;
        needResetClockAfterSeek = NO;
        
        // 필터 기본값
        currentBrightness = 0.0;
        currentContrast   = 1.0;
        prevBrightness    = 0.0;
        prevContrast      = 0.0;
        
        audioReady        = NO;
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

- (void)startStreaming:(NSString *)url {
    decodingStopped = NO;
    dispatch_async(mDecodingQueue, ^{
        [self openFile: url];
    });
}

- (void)stopDecoding {
    NSLog(@"FFmpeg## stopDecoding");
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
        if (!self->isPaused) {
            self->isPaused = YES;
            self->pauseStartTime = [[NSProcessInfo processInfo] systemUptime]; // 멈춘 시점 기록
        }
        [self->pauseCondition unlock];
    });
}

- (void)resume {
    dispatch_async(mDecodingQueue, ^{
        [self->pauseCondition lock];
        if (self->isPaused) {
            // 멈춰있던 시간만큼 시작 시각을 뒤로 밀어줌 (보정)
            double pauseDuration = [[NSProcessInfo processInfo] systemUptime] - self->pauseStartTime;
            self->videoStartClock += pauseDuration;
            
            self->isPaused = NO;
            
            if (!self.engine.isRunning) {
                [self.engine startAndReturnError:nil];
            }
            [self.player play];
            
            [self->pauseCondition signal];
        }
        [self->pauseCondition unlock];
    });
}

- (void)seek:(double)seconds {
    dispatch_async(mDecodingQueue, ^{
        NSLog(@"FFmpeg## isSeeking");
        [self->pauseCondition lock];
        self->seekTarget = seconds;
        self->isSeeking = YES;
        [self->pauseCondition signal];
        [self->pauseCondition unlock];
    });
}

- (void)setBrightness:(double)bright contrast:(double)contrast {
    dispatch_async(mDecodingQueue, ^{
        self->currentBrightness = bright;
        self->currentContrast = contrast;
    });
}

- (void)sendCurrentState:(int)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_delegate receivedState:state];
    });
}

- (void) openFile:(NSString *)url {
    NSLog(@"FFmpeg## openFile: %@", url);
    
    if (currentState != 0) {
        [self sendCurrentState:0];
    }
    av_log_set_level(AV_LOG_DEBUG);
    avformat_network_init();
    pFormatContext = avformat_alloc_context();
    
    AVDictionary *opts = 0;
    int ret = 0;

    //미디어 파일 열기
    //파일의 헤더로 부터 파일 포맷에 대한 정보를 읽어낸 뒤 첫번째 인자 (AVFormatContext) 에 저장.
    //그 뒤의 인자들은 각각 Input Source (스트리밍 URL이나 파일경로), Input Format, demuxer의 추가옵션.
    ret = avformat_open_input(&pFormatContext, [url UTF8String], NULL, &opts);
    
    if (ret != 0) {
        NSLog(@"FFmpeg## File Open Failed");
        [self stopDecoding];
        if (currentState != 7) {
            [self sendCurrentState:7];
        }
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
       pVCodec = (AVCodec*) avcodec_find_decoder(pVPara->codec_id);
       pVCtx = avcodec_alloc_context3(pVCodec);
       avcodec_parameters_to_context(pVCtx, pVPara);
        pVCtx->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
        AVBufferRef *hwDeviceCtx = NULL;

        int err = av_hwdevice_ctx_create(
            &hwDeviceCtx,
            AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
            NULL,
            NULL,
            0
        );

        if (err < 0) {
            NSLog(@"❌ Failed to create VideoToolbox device");
        } else {
            pVCtx->hw_device_ctx = av_buffer_ref(hwDeviceCtx);
        }
       avcodec_open2(pVCtx, pVCodec, NULL);
       NSLog(@"FFmpeg## 비디오 코덱 : %d, %s(%s)\n", pVCodec->id, pVCodec->name, pVCodec->long_name);
    }
    // 오디오 코덱 오픈
    if (aidx >= 0) {
       pAStream = pFormatContext->streams[aidx];
       pAPara = pAStream->codecpar;
       pACodec = (AVCodec*) avcodec_find_decoder(pAPara->codec_id);
       pACtx = avcodec_alloc_context3(pACodec);
       avcodec_parameters_to_context(pACtx, pAPara);
       avcodec_open2(pACtx, pACodec, NULL);
       NSLog(@"FFmpeg## 오디오 코덱 : %d, %s(%s)\n", pACodec->id, pACodec->name, pACodec->long_name);
    }

    if (pVCodec == NULL) {
        NSLog(@"FFmpeg## No Video Decoder");
    }
    
    if (pACodec == NULL) {
        NSLog(@"FFmpeg## No Audio Decoder");
    }
    [self decoding];
}

//파일로부터 인코딩 된 비디오, 오디오 데이터를 읽어서 packet에 저장하는 함수
- (void) decoding {
    
    if (currentState != 1) {
        [self sendCurrentState:1];
    }
    vFrame = av_frame_alloc();
    aFrame = av_frame_alloc();
    packet = *av_packet_alloc();
    
    videoStartClock = [[NSProcessInfo processInfo] systemUptime];
    videoStartPTS = AV_NOPTS_VALUE;
    
    outputFrameSize = CGSizeMake(self->pVCtx->width, self->pVCtx->height);
        
    NSLog(@"FFmpeg## Video Resolution: %.0f x %.0f", outputFrameSize.width, outputFrameSize.height);
        
    while (!self->decodingStopped && pFormatContext != NULL) {
        @autoreleasepool {
            if (currentState != 2) {
                [self sendCurrentState:2];
            }
            while (!self->decodingStopped && [self readFrame:&packet] >= 0) {
                [self->_delegate receivedVideoSize:outputFrameSize];
                [self->pauseCondition lock];
                while (!self->decodingStopped && self->isPaused) {
                    if (currentState != 5) {
                        [self sendCurrentState:5];
                    }
                    [self readPause];
                    if (_player.isPlaying) {
                        [_player pause];
                    }
                    if (self->isSeeking) {
                        NSLog(@"FFmpeg## readSeek");
                        self->isSeeking = NO;
                        [self readSeek:seekTarget];
                    }
                    [self->pauseCondition wait];
                }
                [self->pauseCondition unlock];
                
                if (!self->isPlaying) {
                    [self readPlay];
                    if (currentState != 2) {
                        [self sendCurrentState:2];
                    }
                }
                
                if (packet.stream_index == vidx) {
                    if ([self sendPacket:pVCtx packet:&packet] >= 0) {
                        int ret = [self receiveFrame:pVCtx frame:vFrame];
                        if (ret >= 0) {
                            [self syncVideoFrame:vFrame stream:pVStream];
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
                if (currentState != 6) {
                    [self sendCurrentState:6];
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"FFmpeg## av_read_frame error: %@", exception);
            if (currentState != 7) {
                [self sendCurrentState:7];
            }
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
            if (currentState != 7) {
                [self sendCurrentState:7];
            }
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
            if (currentState != 7) {
                [self sendCurrentState:7];
            }
        }
    }
    return ret;
}

- (int) readPlay {
    
    int ret = -1;
    
    @try {
        isPlaying = YES;
        ret = av_read_play(pFormatContext);
        NSLog(@"FFmpeg## av_read_play: %d", ret);
        if (currentState != 4) {
            [self sendCurrentState:4];
        }
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_read_play error %@", exception);
        if (currentState != 7) {
            [self sendCurrentState:7];
        }
    }
    
    return ret;
}

- (int) readPause {
    
    int ret = -1;
    
    @try {
        isPlaying = NO;
        ret = av_read_pause(pFormatContext);
        NSLog(@"FFmpeg## av_read_pause: %d", ret);
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_read_pause error %@", exception);
        if (currentState != 7) {
            [self sendCurrentState:7];
        }
    }
    
    return ret;
}

- (int)readSeek:(double)seconds {
    int ret = -1;

    @try {
        if (seconds < 0 || !pFormatContext) {
            NSLog(@"FFmpeg## Invalid seek time or context is NULL");
            if (currentState != 7) {
                [self sendCurrentState:7];
            }
            return -1;
        }

        lastRescaledPTS = -1;
        ptsOffset = 0;
        hasPendingSeek = YES;
        pendingSeekSeconds = seconds;
        
        int64_t timestamp = (int64_t)(seconds * AV_TIME_BASE);

        // 디코더 상태 초기화
        avcodec_flush_buffers(pVCtx);
        avcodec_flush_buffers(pACtx);

        // seek 수행
        ret = av_seek_frame(pFormatContext, -1, timestamp, AVSEEK_FLAG_BACKWARD | AVSEEK_FLAG_ANY);

        NSLog(@"FFmpeg## av_seek_frame to %.2f sec (ts: %lld): %d", seconds, timestamp, ret);

        if (ret < 0) {
            NSLog(@"FFmpeg## Seek failed");
            if (currentState != 7) {
                [self sendCurrentState:7];
            }
            hasPendingSeek = NO;
        } else {
            needResetClockAfterSeek = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self->_delegate receivedSeekingState:YES];
            });
        }
    } @catch (NSException *exception) {
        NSLog(@"FFmpeg## av_seek_frame exception: %@", exception);
        if (currentState != 7) {
            [self sendCurrentState:7];
        }
        ret = -1;
        hasPendingSeek = NO;
    }

    return ret;
}

- (void)getCurrentTime:(AVFrame *)frame stream:(AVStream *)stream {
    int64_t currentTime = 0;
    int64_t totalDuration = pFormatContext->duration / AV_TIME_BASE;

    int64_t raw_pts = (frame->pts != AV_NOPTS_VALUE) ? frame->pts : frame->best_effort_timestamp;
    if (raw_pts == AV_NOPTS_VALUE) {
        currentTime = (lastRescaledPTS != -1) ? (lastRescaledPTS + ptsOffset) : 0;
    } else {
        int64_t rescaled_pts = av_rescale_q(raw_pts, stream->time_base, (AVRational){1, 1});

        if (hasPendingSeek) {
            // seek 직후 첫 프레임: 요청한 초에 맞추기 위한 offset 계산
            ptsOffset = (int64_t)pendingSeekSeconds - rescaled_pts;
            lastRescaledPTS = rescaled_pts;
            hasPendingSeek = NO;
        } else {
            // 일반적인 discontinuity 처리
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
}

- (void)syncVideoFrame:(AVFrame *)frame stream:(AVStream *)stream {

    int64_t pts = frame->best_effort_timestamp;
    if (pts == AV_NOPTS_VALUE) return;

    double ptsSeconds = pts * av_q2d(stream->time_base);

    // seek 직후 첫 프레임이면 기준 리셋
    if (needResetClockAfterSeek) {
        videoStartPTS   = ptsSeconds;
        videoStartClock = [[NSProcessInfo processInfo] systemUptime];
        needResetClockAfterSeek = NO;
        return;   // 첫 프레임은 delay 계산하지 않음
    }

    if (videoStartPTS == AV_NOPTS_VALUE) {
        videoStartPTS   = ptsSeconds;
        videoStartClock = [[NSProcessInfo processInfo] systemUptime];
        return;
    }

    double elapsedReal  = [[NSProcessInfo processInfo] systemUptime] - videoStartClock;
    double elapsedVideo = ptsSeconds - videoStartPTS;
    double delay        = elapsedVideo - elapsedReal;

    if (delay <= 0) return;

    usleep((useconds_t)(delay * 1e6));
}


- (void)drawImage {
    int width = vFrame->width;
    int height = vFrame->height;

    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)vFrame->data[3];

    if (!pixelBuffer) return;

    // retain 필요 (FFmpeg가 해제할 수 있음)
    CVPixelBufferRetain(pixelBuffer);

    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];

    // 렌더 후 release
    CVPixelBufferRelease(pixelBuffer);

    CIImage *outputImage = ciImage;

    // 밝기/대비 필터 적용: 값 변경이 있을 때만
    if (self->prevContrast != self->currentContrast || self->prevBrightness != self->currentBrightness) {
        CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
        [filter setValue:ciImage forKey:kCIInputImageKey];
        [filter setValue:@(self->currentContrast) forKey:kCIInputContrastKey];
        [filter setValue:@(self->currentBrightness) forKey:kCIInputBrightnessKey];
        outputImage = filter.outputImage;

        // 이전 값 업데이트
        self->prevContrast = self->currentContrast;
        self->prevBrightness = self->currentBrightness;
    }

    // delegate에 CIImage 직접 전달
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_delegate receivedDecodedCIImage:outputImage size:CGSizeMake(width, height)];
    });
}

- (void) setPlayerVolume:(float)volume {
    if (self.player) {
        self.player.volume = volume;
        NSLog(@"FFmpeg## volume changed: %f", volume);
    }
}

- (void)drawAudio {

    if (!audioReady) {
        AVAudioChannelLayout *channelLayout =
            [[AVAudioChannelLayout alloc] initWithLayoutTag:kAudioChannelLayoutTag_Stereo];

        _audioFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:aFrame->sample_rate
            interleaved:NO
            channelLayout:channelLayout];

        self.engine = [[AVAudioEngine alloc] init];
        self.player = [[AVAudioPlayerNode alloc] init];
        self.player.volume = 0.5;

        [self.engine attachNode:self.player];
        [self.engine connect:self.player to:self.engine.mainMixerNode format:_audioFormat];

        NSError *error = nil;
        [self.engine startAndReturnError:&error];
        NSAssert(!error, @"AudioEngine error %@", error);

        [self.player play];
        audioReady = YES;
    }

    int frames = aFrame->nb_samples;

    AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_audioFormat frameCapacity:frames];

    pcmBuffer.frameLength = frames;

    int bytesPerSample = av_get_bytes_per_sample(pACtx->sample_fmt);
    int channels = pACtx->ch_layout.nb_channels;
    int dataSize = frames * bytesPerSample * channels;

    memcpy(pcmBuffer.floatChannelData[0], aFrame->data[0], dataSize);

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
