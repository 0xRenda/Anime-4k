#import "RoxyVLCVideoOutput.h"
#import "VLC-Swift.h"
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>

// VLCKit 4.0.0-a25 ships an incomplete libvlc header tree: vlc.h includes
// libvlc_media.h, which needs the absent libvlc_picture.h. Declare only the
// public vmem ABI used here, matching include/vlc/libvlc_media_player.h at
// the pinned libvlc commit 005e69e67. CI checks both exported symbols before
// archiving. No LibVLC structures are accessed through this boundary.
typedef struct libvlc_media_player_t libvlc_media_player_t;
typedef void *(*RoxyVideoLockCallback)(void *opaque, void **planes);
typedef void (*RoxyVideoUnlockCallback)(void *opaque, void *picture, void *const *planes);
typedef void (*RoxyVideoDisplayCallback)(void *opaque, void *picture);
typedef unsigned (*RoxyVideoFormatCallback)(void **opaque, char *chroma, unsigned *width,
                                             unsigned *height, unsigned *pitches, unsigned *lines);
typedef void (*RoxyVideoCleanupCallback)(void *opaque);

extern __attribute__((visibility("default")))
void libvlc_video_set_callbacks(libvlc_media_player_t *player, RoxyVideoLockCallback lock,
                                RoxyVideoUnlockCallback unlock, RoxyVideoDisplayCallback display,
                                void *opaque);
extern __attribute__((visibility("default")))
void libvlc_video_set_format_callbacks(libvlc_media_player_t *player, RoxyVideoFormatCallback setup,
                                       RoxyVideoCleanupCallback cleanup);

// The pinned VLCKit 4.0.0-a25 implements this accessor. Keeping the small
// compatibility boundary here avoids private ivar offsets and KVC. CI checks
// the accessor and all libvlc symbols against the pinned binary.
@interface VLCMediaPlayer (RoxyLibVLC)
- (void *)libVLCMediaPlayer;
@end

@interface RoxyVideoFormat : NSObject
@property (nonatomic, strong) RoxyVideoFrameQueue *frames;
@property (nonatomic) void *bytes;
@property (nonatomic) size_t pitch;
@property (nonatomic) unsigned width;
@property (nonatomic) unsigned height;
@property (nonatomic) CVPixelBufferPoolRef pool;
@end

@implementation RoxyVideoFormat
- (void)dealloc
{
    free(_bytes);
    if (_pool) CVPixelBufferPoolRelease(_pool);
}
@end

@interface RoxyVLCVideoOutput ()
@property (nonatomic, strong, nullable) RoxyAnime4KView *metalView;
@property (nonatomic, strong, nullable) RoxyVideoFrameQueue *frames;
@property (nonatomic, weak, nullable) id nativeDrawable;
@property (nonatomic, readwrite) BOOL attached;
@end

static unsigned RoxySetup(void **opaque, char *chroma, unsigned *width, unsigned *height,
                          unsigned *pitches, unsigned *lines)
{
    @autoreleasepool {
        RoxyVLCVideoOutput *owner = (__bridge RoxyVLCVideoOutput *)*opaque;
        // VLC 4 supplies coded dimensions at [0] and visible ones at [1].
        // Request only the visible image so codec padding isn't displayed.
        if (width[1] > 0 && height[1] > 0) {
            width[0] = width[1];
            height[0] = height[1];
        }
        if (!owner.frames || !*width || !*height || *width > 8192 || *height > 8192) return 0;
        size_t pitch = (((size_t)*width * 4) + 63) & ~(size_t)63;
        size_t alignedLines = ((size_t)*height + 31) & ~(size_t)31;
        // Bound CPU staging memory independently of shader texture memory.
        if (pitch * alignedLines > 128 * 1024 * 1024) return 0;
        RoxyVideoFormat *format = [RoxyVideoFormat new];
        format.frames = owner.frames;
        format.pitch = pitch;
        format.width = *width;
        format.height = *height;
        void *storage = NULL;
        if (posix_memalign(&storage, 64, pitch * alignedLines) != 0) return 0;
        memset(storage, 0, pitch * alignedLines);
        format.bytes = storage;
        NSDictionary *attributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(*width),
            (id)kCVPixelBufferHeightKey: @(*height),
            (id)kCVPixelBufferMetalCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferBytesPerRowAlignmentKey: @64
        };
        CVPixelBufferPoolRef pool = NULL;
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &pool) != kCVReturnSuccess) return 0;
        format.pool = pool;
        // VLC 4 defines RV32 as XRGB in MEMORY order, not endian-dependent
        // BGRX. CoreVideo and Metal both require explicit BGRA here.
        memcpy(chroma, "BGRA", 4);
        pitches[0] = (unsigned)pitch;
        lines[0] = (unsigned)alignedLines;
        *opaque = (__bridge_retained void *)format;
        return 1;
    }
}

static void RoxyCleanup(void *opaque)
{
    // Per-format allocation, not per-frame. Works across stream size changes.
    RoxyVideoFormat *format = CFBridgingRelease(opaque);
    (void)format;
}

static void *RoxyLock(void *opaque, void **planes)
{
    RoxyVideoFormat *format = (__bridge RoxyVideoFormat *)opaque;
    planes[0] = format.bytes;
    return NULL;
}

static void RoxyUnlock(void *opaque, void *picture, void *const *planes)
{
    // VLC calls display at the presentation timestamp. Do not submit early.
    (void)opaque; (void)picture; (void)planes;
}

static void RoxyDisplay(void *opaque, void *picture)
{
    (void)picture;
    @autoreleasepool {
        RoxyVideoFormat *format = (__bridge RoxyVideoFormat *)opaque;
        if (!format.frames.acceptingFrames) return;
        CVPixelBufferRef pixelBuffer = NULL;
        // One GPU frame, one latest frame, one incoming copy. Drop instead of
        // blocking VLC when all three pool buffers are still retained.
        NSDictionary *limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey: @3};
        CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, format.pool,
                                       (__bridge CFDictionaryRef)limits, &pixelBuffer);
        if (result != kCVReturnSuccess || !pixelBuffer) return;
        if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
            CVPixelBufferRelease(pixelBuffer);
            return;
        }
        size_t pitch = CVPixelBufferGetBytesPerRow(pixelBuffer);
        uint8_t *destination = CVPixelBufferGetBaseAddress(pixelBuffer);
        const uint8_t *source = format.bytes;
        for (unsigned row = 0; row < format.height; row++) {
            memcpy(destination + row * pitch, source + row * format.pitch, (size_t)format.width * 4);
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        [format.frames submitPixelBuffer:pixelBuffer];
        CVPixelBufferRelease(pixelBuffer);
    }
}

@implementation RoxyVLCVideoOutput

+ (instancetype)outputForPlayer:(VLCMediaPlayer *)player
{
    static char associationKey;
    RoxyVLCVideoOutput *output = objc_getAssociatedObject(player, &associationKey);
    if (!output) {
        output = [RoxyVLCVideoOutput new];
        // The original callback opaque must outlive asynchronous VLC stop and
        // format cleanup. Associate it with the actual player, not a view.
        objc_setAssociatedObject(player, &associationKey, output, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return output;
}

- (UIView *)view { return _metalView; }

- (void)configureForPlayer:(VLCMediaPlayer *)player enabled:(BOOL)enabled
{
    NSAssert([NSThread isMainThread], @"Configure video output on the main thread");
    if ((player.state != VLCMediaPlayerStateStopped && player.state != VLCMediaPlayerStateNothingSpecial)
        || ![player respondsToSelector:@selector(libVLCMediaPlayer)]) return;
    if (enabled == _attached) return;
    libvlc_media_player_t *instance = [player libVLCMediaPlayer];
    if (!instance) return;
    if (enabled) {
        RoxyAnime4KView *view = [RoxyAnime4KView makeViewWithFrame:CGRectZero];
        if (!view) return; // Keep the normal VLCDrawable output on failure.
        _metalView = view;
        _frames = view.frames;
        _nativeDrawable = player.drawable;
        libvlc_video_set_callbacks(instance, RoxyLock, RoxyUnlock, RoxyDisplay, (__bridge void *)self);
        libvlc_video_set_format_callbacks(instance, RoxySetup, RoxyCleanup);
        _attached = YES;
    } else {
        libvlc_video_set_format_callbacks(instance, NULL, NULL);
        // Setting NULL vmem callbacks still selects the vmem output in VLC.
        // Reattach the original drawable to restore the native output instead.
        player.drawable = _nativeDrawable;
        [_metalView removeFromSuperview];
        _metalView = nil;
        _frames = nil;
        _attached = NO;
    }
}

- (void)setFillVideo:(BOOL)fill aspectRatio:(double)ratio
{
    _metalView.fillVideo = fill;
    _metalView.aspectRatio = ratio;
}
@end
