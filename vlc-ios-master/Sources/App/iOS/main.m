/*****************************************************************************
 * main.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import <UIKit/UIKit.h>

#import "VLCAppDelegate.h"

int main(int argc, char *argv[])
{
    @autoreleasepool {
        // Logic tests skip startup, but hosted playback tests need the real
        // app delegate, registered defaults, and scene just like a user launch.
        BOOL launchForPlaybackTests = [NSProcessInfo.processInfo.environment[@"ROXY_PLAYBACK_TESTS"] boolValue];
        if (NSClassFromString(@"XCTestCase") != nil && !launchForPlaybackTests) {
            return UIApplicationMain(argc, argv, nil, nil);
        } else {
            return UIApplicationMain(argc, argv, nil, NSStringFromClass([VLCAppDelegate class]));
        }
    }
}
