/*****************************************************************************
 * VLCEmptyLibraryView.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2018-2026 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Mike JS. Choi <mkchoi212 # icloud.com>
 *          Soomin Lee <bubu@mikan.io>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import <Foundation/Foundation.h>
#import "VLCEmptyLibraryView.h"
#import "VLCFirstStepsViewController.h"
#import "VLC-Swift.h"
#import "VLCDocumentPickerController.h"

@implementation VLCEmptyLibraryView

- (void)awakeFromNib
{
    _emptyLibraryLabel.text = NSLocalizedString(@"EMPTY_LIBRARY", nil);
    _emptyLibraryLongDescriptionLabel.text = NSLocalizedString(@"EMPTY_LIBRARY_LONG", nil);
    [_learnMoreButton setTitle:NSLocalizedString(@"BUTTON_LEARN_MORE", nil) forState:UIControlStateNormal];
#if TARGET_OS_IOS
    [RoxyLibraryStyle decorateEmptyView:self content:_iconView.superview];
    _emptyLibraryLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    _emptyLibraryLabel.adjustsFontForContentSizeCategory = YES;
    _emptyLibraryLongDescriptionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _emptyLibraryLongDescriptionLabel.adjustsFontForContentSizeCategory = YES;
    _learnMoreButton.accessibilityIdentifier = @"roxy.library.open";
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = @"Open Files";
    configuration.image = [UIImage systemImageNamed:@"folder"];
    configuration.imagePadding = 10;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 24, 14, 24);
    _learnMoreButton.configuration = configuration;
#endif
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(themeDidChange)
                                                 name:kVLCThemeDidChangeNotification
                                               object:nil];
    [self themeDidChange];
#if TARGET_OS_IOS
    [self setContentType:_contentType];
#endif
    [super awakeFromNib];
}

- (IBAction)learnMore:(id)sender
{
#if TARGET_OS_IOS
      UIViewController *presenter = self.window.rootViewController;
      while (presenter.presentedViewController) presenter = presenter.presentedViewController;
      NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
      [[[VLCDocumentPickerController alloc] init] presentFromViewController:presenter initialDirectory:documents];
#else
      UIViewController *firstStepsVC = [[VLCFirstStepsViewController alloc] initWithNibName:nil bundle:nil];
      UINavigationController *navCon = [[UINavigationController alloc] initWithRootViewController:firstStepsVC];
      navCon.modalPresentationStyle = UIModalPresentationFormSheet;
      [self.window.rootViewController presentViewController:navCon animated:YES completion:nil];
#endif
}

- (void)themeDidChange
{
    ColorPalette *colors = PresentationTheme.current.colors;
    [_learnMoreButton setTitleColor:colors.orangeDarkAccent forState:UIControlStateHighlighted];
    _emptyLibraryLabel.textColor = colors.cellTextColor;
    _emptyLibraryLabel.backgroundColor = colors.background;
    _emptyLibraryLongDescriptionLabel.textColor = colors.lightTextColor;
    _emptyLibraryLongDescriptionLabel.backgroundColor = colors.background;
#if TARGET_OS_IOS
    self.backgroundColor = colors.pageBackground;
    _emptyLibraryLabel.backgroundColor = UIColor.clearColor;
    _emptyLibraryLongDescriptionLabel.backgroundColor = UIColor.clearColor;
    _iconView.image = [UIImage systemImageNamed:@"play.square.stack.fill"];
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    _iconView.tintColor = colors.orangeUI;
    UIButtonConfiguration *configuration = _learnMoreButton.configuration;
    configuration.baseBackgroundColor = colors.orangeUI;
    configuration.baseForegroundColor = UIColor.whiteColor;
    _learnMoreButton.configuration = configuration;
    [_learnMoreButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    _learnMoreButton.tintColor = colors.orangeUI;
#else
    if (colors.isDark) {
        _iconView.image = [UIImage imageNamed:@"VLCCone26-dark-512x512"];
    } else {
        _iconView.image = [UIImage imageNamed:@"VLCCone26-512x512"];
    }
#endif
}

- (void)setContentType:(VLCEmptyLibraryViewContentType)contentType
{
    _contentType = contentType;

    NSString *title;
    NSString *description;

    switch (contentType) {
        case VLCEmptyLibraryViewContentTypeVideo:
        case VLCEmptyLibraryViewContentTypeAudio:
            title = NSLocalizedString(@"EMPTY_LIBRARY", nil);
            description = NSLocalizedString(@"EMPTY_LIBRARY_LONG", nil);
            _learnMoreButton.hidden = NO;
            break;
        case VLCEmptyLibraryViewContentTypePlaylist:
            title = NSLocalizedString(@"EMPTY_PLAYLIST", nil);
            description = NSLocalizedString(@"EMPTY_PLAYLIST_DESCRIPTION",
                                            nil);
            _learnMoreButton.hidden = YES;
            break;
        case VLCEmptyLibraryViewContentTypeNoHistory:
            title = NSLocalizedString(@"EMPTY_HISTORY", nil);
            description = NSLocalizedString(@"EMPTY_HISTORY_DESCRIPTION", nil);
            _learnMoreButton.hidden = YES;
            break;
        case VLCEmptyLibraryViewContentTypeNoPlaylists:
            title = NSLocalizedString(@"EMPTY_NO_PLAYLISTS", nil);
            description = NSLocalizedString(@"EMPTY_NO_PLAYLISTS_DESCRIPTION",
                                            nil);
            _learnMoreButton.hidden = YES;
            break;
        case VLCEmptyLibraryViewContentTypeNoFavorites:
            title = NSLocalizedString(@"NO_FAVORITES", nil);
            description = NSLocalizedString(@"NO_FAVORITES_DESCRIPTION", nil);
            _learnMoreButton.hidden = YES;
            break;
        case VLCEmptyLibraryViewContentTypeEmptyFolder:
            title = _folderName ? _folderName : NSLocalizedString(@"EMPTY_FOLDER", nil);
            description = _isAudioFolder ? NSLocalizedString(@"EMPTY_FOLDER_DES_AUDIO", nil)
                                         : NSLocalizedString(@"EMPTY_FOLDER_DES_VIDEO", nil);
            _learnMoreButton.hidden = YES;
            break;
    }
    _emptyLibraryLabel.text = title;
    _emptyLibraryLongDescriptionLabel.text = description;
#if TARGET_OS_IOS
    if (contentType == VLCEmptyLibraryViewContentTypeVideo || contentType == VLCEmptyLibraryViewContentTypeAudio) {
        _emptyLibraryLabel.text = @"Welcome to Roxy";
        _emptyLibraryLongDescriptionLabel.text = @"Your videos, beautifully played.\nOpen a file to begin, then tap Anime4K for sharper anime.";
        [_learnMoreButton setTitle:@"Open Files" forState:UIControlStateNormal];
    }
#endif
}

@end
