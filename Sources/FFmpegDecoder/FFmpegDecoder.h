#import <AVFoundation/AVFoundation.h>
#import "libavformat/avformat.h"
#import "libavutil/imgutils.h"
#import "libavcodec/avcodec.h"
#import "libswscale/swscale.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>

@protocol DecoderDelegate <NSObject>

typedef NS_ENUM(NSInteger, PlayerState) {
    PlayerStateInitialized     = 0,
    PlayerStatePreparing       = 1,
    PlayerStateReadyToPlay     = 2,
    PlayerStateBuffering       = 3,
    PlayerStateBufferFinished  = 4,
    PlayerStatePaused          = 5,
    PlayerStatePlayedToTheEnd  = 6,
    PlayerStateError           = 7,
    PlayerStateStop            = 8
};

- (void) receivedDecodedCIImage:(CIImage *)ciImage;
- (void) receivedCurrentTime:(int64_t)currentTime duration:(int64_t)duration;
- (void) receivedState:(PlayerState)state; // 0: initialized, 1: preparing, 2: readyToPlay, 3: buffering, 4: bufferFinished, 5: paused, 6: playedToTheEnd, 7: error, 8: stop
- (void) receivedSeekingState:(BOOL)success;
- (void) receivedVideoSize:(CGSize)videoSize;

@end

@interface FFmpegDecoder : NSObject

@property (nonatomic, weak) id<DecoderDelegate> delegate;
@property (nonatomic, strong)AVAudioEngine *engine;
@property (nonatomic, strong)AVAudioPlayerNode *player;


- (void)startStreaming:(NSString *)url withOptions:(NSDictionary<NSString *, NSString *> *)options
               needLog:(BOOL)needLog needInterrupt:(BOOL)needInterrupt;
- (void) stopDecoding;
- (void) pause;
- (void) resume;
- (void) seek:(double)seconds;
- (BOOL) isPlaying;

- (void) logToFile:(NSString *)text;

@end
