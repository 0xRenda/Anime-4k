#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>

NS_ASSUME_NONNULL_BEGIN

// Lifecycle owner for VLC's vmem callbacks. Reconfigure only while stopped;
// VLC 4's -stop is asynchronous, so callers must check the state explicitly.
@interface RoxyVLCVideoOutput : NSObject
@property (nonatomic, readonly, nullable) UIView *view;
@property (nonatomic, readonly) BOOL attached;
+ (instancetype)outputForPlayer:(VLCMediaPlayer *)player;
- (void)configureForPlayer:(VLCMediaPlayer *)player enabled:(BOOL)enabled;
- (void)setFillVideo:(BOOL)fill aspectRatio:(double)ratio;
@end

NS_ASSUME_NONNULL_END
