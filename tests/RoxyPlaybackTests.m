// Hosted iOS integration tests: use the actual app URL handler and LibVLC.
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <VLCKit/VLCKit.h>
#import "VLCPlaybackService.h"
#import "VLCAppDelegate.h"
#import "VLCDocumentPickerController.h"

@protocol RoxyFileAccess <NSObject>
@property (nonatomic, readonly) NSURL *url;
- (void)close;
@end
@protocol RoxyFilePreparer <NSObject>
+ (void)prepareURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSArray<id<RoxyFileAccess>> *, NSError *))completion;
@end
@protocol RoxyFrameCapture <NSObject>
- (void)captureNextFrame:(void (^)(UIImage *))completion;
@end

@interface RoxyPlaybackTests : XCTestCase
@property (nonatomic) NSMutableArray<NSURL *> *cleanupURLs;
@end

@implementation RoxyPlaybackTests

- (void)setUp
{
    [super setUp];
    self.continueAfterFailure = NO;
    XCTAssertTrue(NSThread.isMainThread);
    self.cleanupURLs = [NSMutableArray new];
    XCTAssertTrue([UIApplication.sharedApplication.delegate isKindOfClass:VLCAppDelegate.class],
                  @"The hosted test must launch the real Roxy app delegate");
    XCTAssertTrue([self waitUntil:^BOOL {
        return [(VLCAppDelegate *)UIApplication.sharedApplication.delegate window].isKeyWindow;
    } seconds:10], @"The app scene did not become ready");
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"RoxyAnime4KEnabled"];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"RoxyAnime4KPreviewOriginal"];
    [NSUserDefaults.standardUserDefaults setObject:@"preset" forKey:@"RoxyAnime4KShader"];
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"ContinuePlayback"];
    [self stopAndWait];
}

- (void)tearDown
{
    [self stopAndWait];
    for (NSURL *url in self.cleanupURLs) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    [super tearDown];
}

- (BOOL)waitUntil:(BOOL (^)(void))condition seconds:(NSTimeInterval)timeout
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]];
    }
    return condition();
}

- (void)stopAndWait
{
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    [service stopPlayback];
    XCTAssertTrue([self waitUntil:^BOOL { return !service.playerIsSetup; } seconds:15], @"Asynchronous stop never finished");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
}

- (NSURL *)copyFixture:(NSString *)extension into:(NSURL *)folder name:(NSString *)name
{
    NSURL *source = [[NSBundle bundleForClass:self.class] URLForResource:@"shared" withExtension:extension];
    XCTAssertNotNil(source);
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&error];
    XCTAssertNil(error);
    NSURL *file = [folder URLByAppendingPathComponent:name];
    [NSFileManager.defaultManager copyItemAtURL:source toURL:file error:&error];
    XCTAssertNil(error);
    [self.cleanupURLs addObject:file];
    return file;
}

- (NSURL *)testDirectory
{
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [documents URLByAppendingPathComponent:[@"Roxy-open-tests-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    [self.cleanupURLs addObject:folder];
    return folder;
}

- (void)assertPlaying:(NSURL *)url
{
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    XCTAssertTrue([self waitUntil:^BOOL {
        return service.isPlaying && [service.currentlyPlayingMedia.url.path isEqual:url.path] &&
               service.currentlyPlayingMedia.statistics.decodedVideo > 0;
    } seconds:20], @"Expected decoded video for %@; state=%ld current=%@", url.lastPathComponent,
       (long)service.mediaPlayerState, service.currentlyPlayingMedia.url);
}

- (void)testSharedMKVOpensPlayerFromInbox
{
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *name = [NSString stringWithFormat:@"Shared anime فریم %@.mkv", NSUUID.UUID.UUIDString];
    NSURL *url = [self copyFixture:@"mkv" into:[documents URLByAppendingPathComponent:@"Inbox"] name:name];
    NSURL *moved = [documents URLByAppendingPathComponent:name];
    [self.cleanupURLs addObject:moved];
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    XCTAssertTrue([delegate application:UIApplication.sharedApplication openURL:url options:@{UIApplicationOpenURLOptionsOpenInPlaceKey: @NO}]);
    [self assertPlaying:moved];
    XCTAssertTrue([self waitUntil:^BOOL {
        return [(VLCAppDelegate *)delegate window].rootViewController.presentedViewController.view.window != nil;
    } seconds:5], @"The player remained hidden behind the library");
}

- (void)testAppOwnedFileNeedsNoSecurityScope
{
    NSURL *url = [self copyFixture:@"mp4" into:self.testDirectory name:@"movie with spaces.mp4"];
    XCTestExpectation *ready = [self expectationWithDescription:@"Own file is accepted"];
    [(Class<RoxyFilePreparer>)NSClassFromString(@"RoxyMediaFileAccess") prepareURLs:@[url] completion:^(NSArray<id<RoxyFileAccess>> *accesses, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(accesses.count, 1u);
        XCTAssertEqualObjects(accesses.firstObject.url.path, url.path);
        [accesses.firstObject close];
        [ready fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testMissingFileReportsAnError
{
    NSURL *url = [self.testDirectory URLByAppendingPathComponent:@"missing.mkv"];
    XCTestExpectation *ready = [self expectationWithDescription:@"Missing file fails visibly"];
    [(Class<RoxyFilePreparer>)NSClassFromString(@"RoxyMediaFileAccess") prepareURLs:@[url] completion:^(NSArray<id<RoxyFileAccess>> *accesses, NSError *error) {
        XCTAssertNil(accesses);
        XCTAssertNotNil(error);
        [ready fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testSharingTheSameFilenameImportsTheNewFile
{
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *inbox = [documents URLByAppendingPathComponent:@"Inbox"];
    NSString *name = [NSString stringWithFormat:@"Repeat-%@.mkv", NSUUID.UUID.UUIDString];
    NSURL *url = [self copyFixture:@"mkv" into:inbox name:name];
    __block NSURL *firstDestination = nil;
    XCTestExpectation *first = [self expectationWithDescription:@"First import"];
    Class<RoxyFilePreparer> preparer = (Class<RoxyFilePreparer>)NSClassFromString(@"RoxyMediaFileAccess");
    [preparer prepareURLs:@[url] completion:^(NSArray<id<RoxyFileAccess>> *accesses, NSError *error) {
        XCTAssertNil(error);
        firstDestination = accesses.firstObject.url;
        if (firstDestination) [self.cleanupURLs addObject:firstDestination];
        [accesses.firstObject close];
        [first fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
    NSData *expected = [NSData dataWithContentsOfURL:[[NSBundle bundleForClass:self.class] URLForResource:@"shared" withExtension:@"mp4"]];
    [self copyFixture:@"mp4" into:inbox name:name];
    XCTestExpectation *second = [self expectationWithDescription:@"Second import with reused filename"];
    [preparer prepareURLs:@[url] completion:^(NSArray<id<RoxyFileAccess>> *accesses, NSError *error) {
        XCTAssertNil(error);
        NSURL *destination = accesses.firstObject.url;
        if (destination) [self.cleanupURLs addObject:destination];
        XCTAssertNotEqualObjects(destination.path, firstDestination.path);
        XCTAssertEqualObjects([NSData dataWithContentsOfURL:destination], expected);
        [accesses.firstObject close];
        [second fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testPickerOpensAppOwnedFileWithoutExtension
{
    NSURL *url = [self copyFixture:@"mkv" into:self.testDirectory name:@"movie without extension"];
    VLCDocumentPickerController *picker = [VLCDocumentPickerController new];
    UIDocumentPickerViewController *sheet = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
    [(id<UIDocumentPickerDelegate>)picker documentPicker:sheet didPickDocumentsAtURLs:@[url]];
    [self assertPlaying:url];
}

- (void)testFolderWithDotsAndNaturalEpisodeOrdering
{
    NSURL *folder = [self.testDirectory URLByAppendingPathComponent:@"Season.01" isDirectory:YES];
    [self copyFixture:@"mkv" into:folder name:@"episode10.mkv"];
    [self copyFixture:@"mkv" into:folder name:@"episode2.mkv"];
    [self copyFixture:@"mkv" into:folder name:@".hidden.mkv"];
    XCTestExpectation *ready = [self expectationWithDescription:@"Folder contents"];
    [(Class<RoxyFilePreparer>)NSClassFromString(@"RoxyMediaFileAccess") prepareURLs:@[folder] completion:^(NSArray<id<RoxyFileAccess>> *accesses, NSError *error) {
        XCTAssertNil(error);
        XCTAssertEqual(accesses.count, 2u);
        if (accesses.count == 2) {
            XCTAssertEqualObjects(accesses[0].url.lastPathComponent, @"episode2.mkv");
            XCTAssertEqualObjects(accesses[1].url.lastPathComponent, @"episode10.mkv");
        }
        for (id<RoxyFileAccess> access in accesses) [access close];
        [ready fulfill];
    }];
    [self waitForExpectationsWithTimeout:10 handler:nil];
}

- (void)testReplacingPlaybackKeepsNewCompletionUntilItsOwnStop
{
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    NSURL *folder = self.testDirectory;
    NSURL *first = [self copyFixture:@"mkv" into:folder name:@"first.mkv"];
    NSURL *second = [self copyFixture:@"mp4" into:folder name:@"second.mp4"];
    __block NSUInteger firstStops = 0, secondStops = 0;
    [service playMediaList:[[VLCMediaList alloc] initWithArray:@[[VLCMedia mediaWithURL:first]]] firstIndex:0 subtitlesFilePath:nil completion:^(BOOL success) { firstStops++; }];
    [self assertPlaying:first];
    [service playMediaList:[[VLCMediaList alloc] initWithArray:@[[VLCMedia mediaWithURL:second]]] firstIndex:0 subtitlesFilePath:nil completion:^(BOOL success) { secondStops++; }];
    [self assertPlaying:second];
    XCTAssertEqual(firstStops, 1u);
    XCTAssertEqual(secondStops, 0u, @"The new file's access was released before its playback finished");
    [self stopAndWait];
    XCTAssertEqual(firstStops, 1u);
    XCTAssertEqual(secondStops, 1u);
}

- (void)testRapidReplacementKeepsLatestRequest
{
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    NSURL *folder = self.testDirectory;
    NSURL *first = [self copyFixture:@"mkv" into:folder name:@"first.mkv"];
    NSURL *second = [self copyFixture:@"mkv" into:folder name:@"second.mkv"];
    NSURL *last = [self copyFixture:@"mkv" into:folder name:@"last.mkv"];
    [service playMediaList:[[VLCMediaList alloc] initWithArray:@[[VLCMedia mediaWithURL:first]]] firstIndex:0 subtitlesFilePath:nil];
    // Let the app submit playItemAtNumber without waiting for VLCKit's queued
    // Opening callback, then replace it twice during that startup window.
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
    [service playMediaList:[[VLCMediaList alloc] initWithArray:@[[VLCMedia mediaWithURL:second]]] firstIndex:0 subtitlesFilePath:nil];
    [service playMediaList:[[VLCMediaList alloc] initWithArray:@[[VLCMedia mediaWithURL:last]]] firstIndex:0 subtitlesFilePath:nil];
    [self assertPlaying:last];
}

- (void)testValidVideoOpensAfterDecoderFailure
{
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    NSURL *folder = self.testDirectory;
    NSURL *valid = [self copyFixture:@"mkv" into:folder name:@"valid.mkv"];
    NSURL *broken = [folder URLByAppendingPathComponent:@"broken.mkv"];
    [@"This is not a video file." writeToURL:broken atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTestExpectation *failure = [self expectationWithDescription:@"VLC rejects the invalid video"];
    id observer = [NSNotificationCenter.defaultCenter addObserverForName:VLCPlaybackServicePlaybackDidFail object:service queue:nil usingBlock:^(NSNotification *notification) {
        [failure fulfill];
    }];
    [UIApplication.sharedApplication.delegate application:UIApplication.sharedApplication openURL:broken options:@{}];
    [self waitForExpectationsWithTimeout:15 handler:nil];
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    XCTAssertTrue([self waitUntil:^BOOL { return !service.playerIsSetup; } seconds:15]);
    [UIApplication.sharedApplication.delegate application:UIApplication.sharedApplication openURL:valid options:@{}];
    [self assertPlaying:valid];
}

- (void)testSharedMKVReachesAnime4KFrameQueue
{
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RoxyAnime4KEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"low" forKey:@"RoxyAnime4KQuality"];
    NSURL *url = [self copyFixture:@"mkv" into:self.testDirectory name:@"enhanced.mkv"];
    [UIApplication.sharedApplication.delegate application:UIApplication.sharedApplication openURL:url options:@{UIApplicationOpenURLOptionsOpenInPlaceKey: @YES}];
    [self assertPlaying:url];
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    XCTAssertTrue([self waitUntil:^BOOL {
        id output = [service valueForKey:@"roxyVideoOutput"];
        id view = [output valueForKey:@"view"];
        id frames = [view valueForKey:@"frames"];
        return [[frames valueForKey:@"receivedFrameCount"] unsignedLongLongValue] > 0;
    } seconds:10], @"The VLC callback never delivered a video frame to Anime4K");
}

- (void)testVideoReopensWhilePreviousPlayerIsDismissing
{
    NSURL *folder = self.testDirectory;
    NSURL *first = [self copyFixture:@"mkv" into:folder name:@"before close.mkv"];
    NSURL *second = [self copyFixture:@"mp4" into:folder name:@"after close.mp4"];
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    UIViewController *root = [(VLCAppDelegate *)delegate window].rootViewController;
    [delegate application:UIApplication.sharedApplication openURL:first options:@{}];
    [self assertPlaying:first];
    XCTAssertTrue([self waitUntil:^BOOL {
        UIViewController *player = root.presentedViewController;
        return player.view.window != nil && !player.isBeingPresented && !player.isBeingDismissed;
    } seconds:5]);

    UIViewController *closingPlayer = root.presentedViewController;
    [VLCPlaybackService.sharedInstance stopPlayback];
    XCTAssertTrue([self waitUntil:^BOOL { return closingPlayer.isBeingDismissed; } seconds:5],
                  @"The test must open the new video during the dismissal animation");
    [delegate application:UIApplication.sharedApplication openURL:second options:@{}];
    [self assertPlaying:second];
    XCTAssertTrue([self waitUntil:^BOOL {
        UIViewController *player = root.presentedViewController;
        return player.view.window != nil && !player.isBeingDismissed && !player.isBeingPresented;
    } seconds:5], @"Decoded video stayed behind the library after a rapid reopen");
}

- (UIView<RoxyFrameCapture> *)animeView
{
    return [[VLCPlaybackService.sharedInstance valueForKey:@"roxyVideoOutput"] valueForKey:@"view"];
}

- (void)saveImage:(UIImage *)image name:(NSString *)name
{
    XCTAssertNotNil(image);
    XCTAttachment *attachment = [XCTAttachment attachmentWithImage:image];
    attachment.name = name;
    attachment.lifetime = XCTAttachmentLifetimeKeepAlways;
    [self addAttachment:attachment];
    NSURL *folder = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"RoxyValidation"];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [UIImagePNGRepresentation(image) writeToURL:[folder URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]] atomically:YES];
}

- (UIImage *)captureVideo
{
    __block UIImage *image = nil;
    XCTestExpectation *ready = [self expectationWithDescription:@"Read actual Metal presentation pixels"];
    [self.animeView captureNextFrame:^(UIImage *value) { image = value; [ready fulfill]; }];
    [self waitForExpectationsWithTimeout:30 handler:nil];
    XCTAssertNotNil(image);
    return image;
}

- (void)assertColorBars:(UIImage *)image name:(NSString *)name
{
    CGImageRef source = image.CGImage;
    size_t width = CGImageGetWidth(source), height = CGImageGetHeight(source);
    NSMutableData *bytes = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes.mutableBytes, width, height, 8, width * 4, space,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    XCTAssertNotEqual(context, NULL);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    const int expected[8][3] = {{220,20,20},{20,220,20},{20,20,220},{128,128,128},
                               {220,220,220},{20,20,20},{20,220,220},{220,220,20}};
    // The production renderer aspect-fits a 16:9 video; exclude letterboxing.
    double videoWidth = MIN((double)width, height * 16.0 / 9.0);
    double left = (width - videoWidth) / 2.0;
    const uint8_t *pixels = bytes.bytes;
    for (int bar = 0; bar < 8; bar++) {
        size_t x = (size_t)(left + videoWidth * (bar + 0.5) / 8.0);
        const uint8_t *pixel = pixels + ((height / 2) * width + x) * 4;
        NSLog(@"COLOR %@ bar=%d RGB=%d,%d,%d", name, bar, pixel[0], pixel[1], pixel[2]);
        for (int channel = 0; channel < 3; channel++) {
            XCTAssertLessThan(abs((int)pixel[channel] - expected[bar][channel]), 40,
                @"%@ color channel %d is wrong in bar %d", name, channel, bar);
        }
        if (bar == 3 || bar == 4) {
            XCTAssertLessThan(abs((int)pixel[0] - pixel[2]), 6, @"Neutral colors must not turn purple");
        }
    }
    [self saveImage:image name:name];
}

- (void)validateRenderedFixture:(NSString *)name
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"RoxyAnime4KEnabled"];
    [defaults setObject:@"low" forKey:@"RoxyAnime4KQuality"];
    NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:name withExtension:@"mkv"];
    XCTAssertNotNil(url);
    [UIApplication.sharedApplication.delegate application:UIApplication.sharedApplication openURL:url options:@{}];
    [self assertPlaying:url];
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    [service pause];
    for (NSString *quality in @[@"low", @"medium", @"high"]) {
        [defaults setObject:quality forKey:@"RoxyAnime4KQuality"];
        XCTAssertTrue([self waitUntil:^BOOL {
            NSDictionary *metrics = service.anime4KRenderMetrics;
            return [metrics[@"passes"] intValue] > 0 && [metrics[@"quality"] isEqual:quality];
        } seconds:60], @"%@ failed to run %@: %@", name, quality, service.anime4KRenderMetrics);
        NSDictionary *metrics = service.anime4KRenderMetrics;
        XCTAssertEqual([metrics[@"inputWidth"] intValue], 128);
        XCTAssertEqual([metrics[@"outputWidth"] intValue], 256, @"The CNN must actually double the resolution");
        XCTAssertEqual([metrics[@"outputHeight"] intValue], 144);
        CGFloat scale = self.animeView.window.screen.scale;
        XCTAssertEqualWithAccuracy([metrics[@"displayWidth"] doubleValue], self.animeView.bounds.size.width * scale, 1);
        [self assertColorBars:self.captureVideo name:[NSString stringWithFormat:@"%@-%@", name, quality]];
    }
    [defaults setBool:YES forKey:@"RoxyAnime4KPreviewOriginal"];
    XCTAssertTrue([self waitUntil:^BOOL { return [service.anime4KRenderMetrics[@"passes"] intValue] == 0; } seconds:10]);
    XCTAssertEqual([service.anime4KRenderMetrics[@"outputWidth"] intValue], 128);
    [self assertColorBars:self.captureVideo name:[name stringByAppendingString:@"-original"]];
    [defaults setBool:NO forKey:@"RoxyAnime4KPreviewOriginal"];
}

- (void)testRendered8BitColorsAndAllThreeUpscalingPresets { [self validateRenderedFixture:@"bars-8bit"]; }
- (void)testRendered10BitColorsAndAllThreeUpscalingPresets { [self validateRenderedFixture:@"bars-10bit"]; }

- (void)testEnablingAnime4KPreservesPausedMediaAndFileLease
{
    NSURL *url = [self copyFixture:@"mkv" into:self.testDirectory name:@"enable live.mkv"];
    VLCPlaybackService *service = VLCPlaybackService.sharedInstance;
    VLCMediaList *list = [VLCMediaList new];
    [list addMedia:[VLCMedia mediaWithURL:url]];
    __block int completions = 0;
    [service playMediaList:list firstIndex:0 subtitlesFilePath:nil completion:^(BOOL success) { completions++; }];
    [self assertPlaying:url];
    service.playbackPosition = 2;
    [service pause];
    XCTAssertTrue([self waitUntil:^BOOL { return service.mediaPlayerState == VLCMediaPlayerStatePaused; } seconds:10]);
    float position = service.playbackPosition;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RoxyAnime4KEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"low" forKey:@"RoxyAnime4KQuality"];
    [service applyAnime4KSettings];
    XCTAssertTrue([self waitUntil:^BOOL {
        return service.mediaPlayerState == VLCMediaPlayerStatePaused && [service.anime4KRenderMetrics[@"passes"] intValue] > 0;
    } seconds:60]);
    XCTAssertEqualObjects(service.currentlyPlayingMedia.url, url);
    XCTAssertEqualWithAccuracy(service.playbackPosition, position, 0.75);
    XCTAssertEqual(completions, 0, @"Changing the renderer must not finish the caller's file access");
    [self stopAndWait];
    XCTAssertEqual(completions, 1);
}

- (void)testVisibleAnime4KButtonOpensGlassSettings
{
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"RoxyAnime4KEnabled"];
    [NSUserDefaults.standardUserDefaults setObject:@"low" forKey:@"RoxyAnime4KQuality"];
    NSURL *url = [[NSBundle bundleForClass:self.class] URLForResource:@"bars-8bit" withExtension:@"mkv"];
    [UIApplication.sharedApplication.delegate application:UIApplication.sharedApplication openURL:url options:@{}];
    [self assertPlaying:url];
    UIWindow *window = [(VLCAppDelegate *)UIApplication.sharedApplication.delegate window];
    __block UIButton *button = nil;
    XCTAssertTrue([self waitUntil:^BOOL {
        button = (UIButton *)[self findView:window identifier:@"roxy.anime4k.open"];
        return button.window != nil && button.alpha > 0;
    } seconds:10]);
    [self saveWindow:window name:@"player-glass"];
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    XCTAssertTrue([self waitUntil:^BOOL { return [self findView:window identifier:@"roxy.anime4k.quality"] != nil; } seconds:10]);
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
    [self saveWindow:window name:@"anime4k-glass-menu"];
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    [controller dismissViewControllerAnimated:NO completion:nil];
}

- (UIView *)findView:(UIView *)root identifier:(NSString *)identifier
{
    if ([root.accessibilityIdentifier isEqual:identifier]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = [self findView:child identifier:identifier];
        if (found) return found;
    }
    return nil;
}

- (void)saveWindow:(UIWindow *)window name:(NSString *)name
{
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];
    [self saveImage:image name:name];
}

@end
