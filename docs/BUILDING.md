# Building Roxy Player

## Requirements

The supplied VLC tree uses current Xcode APIs. Use **Xcode 26.3 or newer** on a
compatible Mac, Ruby 3.3, Bundler and Python 3.10+. The workflow uses GitHub's
`macos-26` image; installed Xcode versions can change with the image. See the
[runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md).
The app's deployment target remains iOS 15.0.

Dependencies remain pinned by `vlc-ios-master/Podfile.lock` and
`vlc-ios-master/VLC.xcworkspace/xcshareddata/swiftpm/Package.resolved`. VLCKit is
4.0.0-a25. `pod install --deployment` intentionally fails if those inputs drift.
The first build needs internet access to VideoLAN, GitHub and CocoaPods.

Run these commands from the folder containing this document's parent `README.md`:

```bash
bundle install
bash tools/build_ipa.sh unsigned
```

`ROXY_QUALITY=low`, `medium`, `high` or `automatic` controls the initial preset.
Existing installed preferences take precedence over a variant's initial value.
The app target supports iPhone and iPad. The CI preparation script excludes
upstream watch, widget, intents and share extension products so an IPA needs
only the main app's provisioning profile. Those extension products remain in
the upstream project for separate development.

For an interactive Xcode session, install CocoaPods dependencies, run
`bundle exec ruby tools/prepare_ci.rb` to select the app-only build, then open
`vlc-ios-master/VLC.xcworkspace` and select **Roxy**. Without precompiled Metal
libraries the renderer can compile the bundled Metal sources asynchronously.

## Signed GitHub Actions builds

Create an explicit Apple app identifier matching your bundle ID, and enable its
App Groups capability. The default identifiers are:

| Item | Default |
| --- | --- |
| App | `com.roxy.player` |
| App Group | `group.com.roxy.player` |

For your own identifiers set repository variables `ROXY_BUNDLE_ID` and, if
needed, `ROXY_APP_GROUP`. Register the app group in the Apple Developer portal,
associate it with the app, and regenerate the provisioning profile.

Add these repository **secrets**:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `IOS_CERTIFICATE_P12_BASE64` | Base64 of the signing certificate **with private key**, exported as `.p12` |
| `IOS_CERTIFICATE_PASSWORD` | Password used when exporting that `.p12` |
| `IOS_PROVISION_PROFILE_BASE64` | Base64 of the main app's `.mobileprovision` |

From PowerShell, copy a base64 value to the clipboard without committing it:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\certificate.p12")) | Set-Clipboard
```

Run **Build Roxy Player IPA**, choose the quality variants, enable **signed**,
and select the export method that matches the profile:

| Export method | Profile |
| --- | --- |
| `release-testing` | Ad Hoc distribution; include the target device UDIDs |
| `debugging` | Development profile and matching development certificate |
| `app-store-connect` | App Store distribution; not directly installable as an Ad Hoc app |

The signing installer checks the bundle ID, team, expiration, app group and
profile type, creates a temporary keychain, and installs the profile. Cleanup
runs even on a failed job. Do not commit certificates or profiles. This follows
the [GitHub Xcode signing workflow](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

Signed export does not upload to App Store Connect, TestFlight or GitHub
Releases. Downloaded artifacts remain private to the repository's access rules.

## Outputs and failures

Successful jobs upload `Roxy-Player-QUALITY-unsigned.ipa` or
`Roxy-Player-QUALITY-signed.ipa`. Build logs are uploaded separately, including
on failure. A failed archive does not produce a placeholder IPA.

The Windows development workspace cannot run Xcode, `codesign`, the Apple Metal
compiler or iOS playback. The first CI run is a required validation step. Upstream
cloud-service account identifiers and entitlement-dependent features may need
your own configuration; no VideoLAN signing identity or merchant capability is
used for the main Roxy target.
