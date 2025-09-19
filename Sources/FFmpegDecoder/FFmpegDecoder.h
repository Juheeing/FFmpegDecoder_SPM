#import <AVFoundation/AVFoundation.h>
#import "libavformat/avformat.h"
#import "libavutil/imgutils.h"
#import "libavcodec/avcodec.h"
#import "libswscale/swscale.h"
#import <CoreImage/CoreImage.h>
#import <CoreGraphics/CoreGraphics.h>

@protocol DecoderDelegate <NSObject>

- (void)receivedDecodedCIImage:(CIImage *)ciImage;
- (void) receivedCurrentTime:(int64_t)currentTime duration:(int64_t)duration;
- (void) receivedState:(int64_t)state; // 0: initialized, 1: preparing, 2: readyToPlay, 3: buffering, 4: bufferFinished, 5: paused, 6: playedToTheEnd, 7: error, 8: stop
- (void) receivedSeekingState:(BOOL)success;
- (void) receivedVideoSize:(CGSize)videoSize;

@end

@interface FFmpegDecoder : NSObject
+ (instancetype)sharedInstance;

@property (nonatomic, weak) id<DecoderDelegate> delegate;
@property (nonatomic, strong)AVAudioEngine *engine;
@property (nonatomic, strong)AVAudioPlayerNode *player;

- (void) startStreaming:(NSString *)url withOptions:(NSDictionary<NSString *, NSString *> *)options;
- (void) stopDecoding;
- (void) pause;
- (void) resume;
- (void) seek:(double)seconds;
- (void) setBrightness:(double)bright contrast:(double)contrast;
- (BOOL) isPlaying;
@end
