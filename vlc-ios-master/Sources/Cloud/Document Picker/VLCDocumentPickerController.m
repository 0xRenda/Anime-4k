/*****************************************************************************
 * VLCDocumentPickerController.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2014-2026 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Tamas Timar <ttimar.vlc # gmail.com>
 *          Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCDocumentPickerController.h"
#import "VLCPlaybackService.h"
#import "VLC-Swift.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface VLCDocumentPickerController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) VLCDocumentPickerController *retainedSelf;
@property (nonatomic, weak) UIViewController *presentingViewController;
@end

@implementation VLCDocumentPickerController

- (UIDocumentPickerViewController *)createPickerViewController
{
    return [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem, UTTypeFolder] asCopy:NO];
}

- (void)presentFromViewController:(UIViewController *)presentingViewController
                 initialDirectory:(NSURL *)initialDirectoryURL
{
    UIDocumentPickerViewController *picker = [self createPickerViewController];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    picker.directoryURL = initialDirectoryURL;

    self.presentingViewController = presentingViewController;
    self.retainedSelf = self;

    [presentingViewController presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    [RoxyMediaFileAccess prepareURLs:urls completion:^(NSArray<RoxyMediaFileAccess *> *accesses, NSError *error) {
        void (^openPreparedFiles)(void) = ^{
            if (error || accesses.count == 0) {
                [RoxyMediaFileAccess showOpenError:error ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil]];
            } else {
                VLCMediaList *mediaList = [VLCMediaList new];
                for (RoxyMediaFileAccess *access in accesses) {
                    [mediaList addMedia:[VLCMedia mediaWithURL:access.url]];
                }
                [[VLCPlaybackService sharedInstance] playMediaList:mediaList firstIndex:0 subtitlesFilePath:nil completion:^(BOOL success) {
                    for (RoxyMediaFileAccess *access in accesses) [access close];
                }];
            }
            self.retainedSelf = nil;
        };
        // Present playback only after the Files sheet has finished dismissing.
        if (controller.isBeingDismissed && controller.transitionCoordinator) {
            [controller.transitionCoordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
                openPreparedFiles();
            }];
        } else if (controller.presentingViewController) {
            [controller dismissViewControllerAnimated:YES completion:openPreparedFiles];
        } else {
            openPreparedFiles();
        }
    }];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    self.retainedSelf = nil;
}

@end
