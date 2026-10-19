/*****************************************************************************
 * VLCAppSceneDelegate.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2022-2023 VideoLAN. All rights reserved.
 * $Id$
 *
 * Author: Felix Paul Kühne <fkuehne # videolan.org>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCAppSceneDelegate.h"
#import "VLCAppDelegate.h"
#import "VLC-Swift.h"

@interface VLCAppSceneDelegate () <UISceneDelegate>
{
    NSMutableArray<UIOpenURLContext *> *_pendingURLContexts;
}

@end

@implementation VLCAppSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)connectionOptions
{
    [VLCAppearanceManager setupAppearanceWithTheme:PresentationTheme.current];

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [VLCBottomTabBarController new];
    [window makeKeyAndVisible];

    [VLCAppearanceManager setupUserInterfaceStyleWithTheme:PresentationTheme.current];

    VLCAppDelegate *appDelegate = (VLCAppDelegate *)[UIApplication sharedApplication].delegate;
    appDelegate.window = window;
    [appDelegate setupTabBarAppearance];

    [self scene:scene openURLContexts:connectionOptions.URLContexts];

    NSUserActivity *firstActivity = connectionOptions.userActivities.anyObject;
    if (firstActivity != nil) {
        [self scene:scene willContinueUserActivityWithType:firstActivity.activityType];
        [self scene:scene continueUserActivity:firstActivity];
    }

    UIApplicationShortcutItem *shortcutItem = connectionOptions.shortcutItem;
    if (shortcutItem) {
        [appDelegate validatePasscodeIfNeededWithCompletion:^{
            [[VLCAppCoordinator sharedInstance] handleShortcutItem:shortcutItem];
        }];
    }
    // An explicit file/deep link takes precedence over restoring the old queue.
    if ([session.role isEqualToString:UIWindowSceneSessionRoleApplication] &&
        connectionOptions.URLContexts.count == 0 && !firstActivity && !shortcutItem) {
        [[VLCAppCoordinator sharedInstance].mediaLibraryService restoreLastPlayedMediaList];
    }
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
}

- (void)sceneDidBecomeActive:(UIScene *)scene
{
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    [appDelegate applicationDidBecomeActive:sharedApplication];
    NSArray<UIOpenURLContext *> *pending = [_pendingURLContexts copy];
    [_pendingURLContexts removeAllObjects];
    for (UIOpenURLContext *context in pending) {
        [self openURLContext:context];
    }
}

- (void)sceneWillResignActive:(UIScene *)scene
{
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    [appDelegate applicationWillResignActive:sharedApplication];
}

- (void)sceneWillEnterForeground:(UIScene *)scene
{
}

- (void)sceneDidEnterBackground:(UIScene *)scene
{
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    [appDelegate validatePasscodeIfNeededWithCompletion:^{}];
    [appDelegate applicationWillTerminate:sharedApplication];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
    for (UIOpenURLContext *context in URLContexts) {
        // Cold launches and share-sheet activations arrive before the player
        // can be presented. Retain the original context until activation.
        if (scene.activationState != UISceneActivationStateForegroundActive) {
            if (!_pendingURLContexts) _pendingURLContexts = [NSMutableArray new];
            [_pendingURLContexts addObject:context];
        } else {
            [self openURLContext:context];
        }
    }
}

- (void)openURLContext:(UIOpenURLContext *)context
{
    NSURL *url = context.URL;
    if (!url) return;

    if ([url.scheme isEqualToString:@"ml-widget"]) {
        NSArray<NSString *> *pathComponents = url.pathComponents;
        NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        url = [documentsURL URLByAppendingPathComponent:pathComponents.lastObject];
    }

    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    NSMutableDictionary<UIApplicationOpenURLOptionsKey, id> *options = [NSMutableDictionary new];
    options[UIApplicationOpenURLOptionsOpenInPlaceKey] = @(context.options.openInPlace);
    if (context.options.sourceApplication) options[UIApplicationOpenURLOptionsSourceApplicationKey] = context.options.sourceApplication;
    if (context.options.annotation) options[UIApplicationOpenURLOptionsAnnotationKey] = context.options.annotation;
    [appDelegate application:sharedApplication openURL:url options:options];
}

- (void)scene:(UIScene *)scene willContinueUserActivityWithType:(NSString *)userActivityType
{
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    [appDelegate application:sharedApplication willContinueUserActivityWithType:userActivityType];
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)userActivity
{
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    [appDelegate application:sharedApplication continueUserActivity:userActivity
          restorationHandler:^(NSArray<id<UIUserActivityRestoring>> * _Nullable restorableObjects){}];
}

- (void)scene:(UIScene *)scene didFailToContinueUserActivityWithType:(NSString *)userActivityType error:(NSError *)error
{
    UIApplication *sharedApplication = [UIApplication sharedApplication];
    VLCAppDelegate *appDelegate = (VLCAppDelegate *)sharedApplication.delegate;
    [appDelegate application:sharedApplication didFailToContinueUserActivityWithType:userActivityType error:error];
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL succeeded))completionHandler
{
    [[VLCAppCoordinator sharedInstance] handleShortcutItem:shortcutItem];
}

@end
