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

@interface RoxyPlaybackTests : XCTestCase
@property (nonatomic) NSMutableArray<NSURL *> *cleanupURLs;
@end

@implementation RoxyPlaybackTests

- (void)setUp
{
    [super setUp];
    XCTAssertTrue(NSThread.isMainThread);
    self.cleanupURLs = [NSMutableArray new];
    XCTAssertTrue([self waitUntil:^BOOL {
        return [(VLCAppDelegate *)UIApplication.sharedApplication.delegate window].isKeyWindow;
    } seconds:10], @"The app scene did not become ready");
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"RoxyAnime4KEnabled"];
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

@end
