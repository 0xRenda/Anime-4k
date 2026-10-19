# Roxy Player

An iPhone and iPad player based on the supplied VLC iOS source, with a Metal
port of the supplied Anime4K shader library.

**Status:** GitHub Actions has successfully archived the iOS app, compiled all
49 Metal shaders, checked the small CNN against its CPU reference, and passed
all **11 hosted iOS playback tests** for 4.0.1. IPA uploads require those tests
to pass. Physical-device,
file-provider and performance testing remains pending; see
[validation results](docs/VALIDATION.md) and the [device checklist](docs/DEVICE_TESTING.md).

- iOS/iPadOS **15.0+**, arm64; universal iPhone and iPad application.
- All **49** supplied GLSL shaders translated to Metal, with upstream weights,
  license notices and source SHA-256 hashes preserved.
- Low, Medium and High presets, plus Automatic selection and individual shaders.
- Runtime selection by Metal GPU family, temperature, Low Power Mode and GPU
  frame time, including newer iPads without a device model allowlist.
- A separate name, icon, `com.roxy.player` bundle identifier and `roxy://` links.
- GitHub Actions builds unsigned IPAs or signs with your Apple credentials.

## Build the three IPAs

1. Put **this whole folder's contents** in the root of your GitHub repository.
   Keep `Anime4K-master`, `vlc-ios-master`, `tools`, `tests` and `.github` together.
2. Open **Actions → Build Roxy Player IPA → Run workflow**.
3. Choose **quality: all**, leave **signed: false**, and run it.
4. Download the `Roxy-Player-low-unsigned`, `Roxy-Player-medium-unsigned` and
   `Roxy-Player-high-unsigned` artifacts after the jobs pass.

These variants set a different starting quality. Each app includes every preset
and shader; they share a bundle ID and replace each other on installation.
**Unsigned IPAs require signing with an iOS sideloading tool before installation.**
Pushes and pull requests build one Automatic variant. The workflow compiles all
49 shaders for both macOS validation and iOS packaging, checks the original small
CNN against a CPU reference if a Metal device is available, archives the actual
VLC application, inspects the resulting IPA for arm64 and shader resources, and
runs hosted playback tests using real MKV and MP4 decoding before uploading it.

For a signed IPA, see [BUILDING.md](docs/BUILDING.md). For architecture,
performance limits and testing, see [ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[DEVICE_TESTING.md](docs/DEVICE_TESTING.md).

## Open media

Share a file from Files to **Roxy Player**, or use the app's document picker.
Version 4.0.1 waits for scene activation and picker dismissal before opening
playback, preserves file access for the active video, and imports Inbox copies
into Documents. Folders use their actual resource type and natural episode
ordering; readable files without an extension can also be opened directly.
Opening failures report an error instead of silently discarding the request.

## Use Anime4K

Open **Settings → Anime4K**, enable upscaling and reopen the video. Choose
Automatic, Low, Medium or High. Turn on **Show Anime4K status** to inspect the
active preset and preparation/fallback messages. Individual advanced shaders
replace the preset chain; they can be substantially more expensive.

| Quality | Shader chain | Intended starting point |
| --- | --- | --- |
| Low | CNN x2 S | Older devices, battery saving |
| Medium | Restore CNN S → CNN x2 M | Recent iPhones and midrange iPads |
| High | Restore CNN L → CNN x2 VL | Powerful iPads and manual quality testing |
| Automatic | Selects one of the above | Uses GPU capability and memory; thermal backoff applies |

The algorithm uses the **GPU through Metal**. VLC decoding and frame copies use
the CPU in this integration. No per-device frame-rate guarantee is claimed.
Picture in Picture requires turning Anime4K off and reopening playback. The
enhanced path currently processes SDR BGRA frames; HDR output is not preserved.
Chromecast rendering is performed by the receiver, so local Anime4K is not sent
to a casting device. Normal native VLC rendering remains available when the
feature is disabled before starting playback.

## Local source checks

```powershell
python tools/port_anime4k.py --check
python -m unittest discover -s tests -p "test_*.py" -v
```

On a Mac with a suitable Xcode installation:

```bash
bundle install
bash tools/test_metal.sh
ROXY_QUALITY=low bash tools/build_ipa.sh unsigned
```

The integrated Xcode workspace is `vlc-ios-master/VLC.xcworkspace`; use the
shared **Roxy** scheme. Dependency installation is required first.

## Attribution and source

Roxy Player is an independent modification, not an official VideoLAN release.
VLC and dependency attribution remains in the application and source tree.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Keep source and notices
available when distributing builds.
