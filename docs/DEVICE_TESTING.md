# Device acceptance checklist

These checks have **not** been run in the Windows workspace. Record device,
iOS/iPadOS version, source codec/resolution/frame rate, quality, render time,
dropped frames and thermal behavior for each run. No device is certified yet.

## Device coverage

| Device class | Starting preset | Required coverage |
| --- | --- | --- |
| Oldest available iOS 15 iPhone/iPad | Low | Memory pressure, 720p/1080p, 20-minute playback |
| Recent A-series iPhone | Medium / Automatic | 1080p, 24/30/60 fps, battery and charging |
| M1/M2 iPad | Medium / manual High | Rotation, split view, external display |
| M4/M5 iPad | High / Automatic | Sustained 1080p→display upscale, GPU time and thermals |

## Functional coverage

- Install a signed build on an iPhone and an iPad; confirm icon, Roxy Player name
  and independent library storage while the official VLC app is also installed.
- Open files from Files, local library, HTTP and network shares. Test MKV, MP4,
  H.264, HEVC, AV1 where supported by the bundled VLC decoder, and audio-only media.
- Compare disabled, Low, Medium and High on the same anime frame. Verify actual
  x2 processing when both output dimensions exceed the shader's 1.2x threshold.
- Test every advanced shader on a short clip at a modest resolution; allow time
  for pipeline preparation. Exercise all experimental/GAN shaders under memory pressure.
- Seek, pause, resume, change playback speed, advance/loop playlists, stop and
  reopen, and play files with changing coded dimensions.
- Check SRT/ASS subtitles, subtitle delays, audio sync and multiple tracks.
- Test portrait/landscape, fill/fit, each custom aspect ratio, external displays,
  background/foreground, lock/unlock and playback route interruptions.
- Disable Anime4K, stop/reopen and verify native hardware playback and Picture
  in Picture. Re-enable, stop/reopen and verify Metal output returns.
- Confirm selecting Chromecast uses receiver playback; local enhancements should
  not be represented as receiver-side processing.
- Trigger Low Power Mode, serious/critical thermal states using development
  tooling where available, and memory warnings. Confirm downshift/bypass status
  and that the player remains responsive without an accumulating frame queue.

## Media opening regression checks (4.0.1)

- Force quit Roxy, share an MKV from Files to Roxy, and confirm the player
  appears and video starts. Repeat while Roxy is already open and while another
  video is playing. Include a filename containing spaces and non-Latin text.
- Repeat with iCloud Drive and an installed third-party file provider, including
  a file that needs downloading. Keep playing after the Files sheet disappears.
- Share two different videos with the same filename. The second import should
  play the new video and preserve the first copy under its own library filename.
- Open a local video with no extension through the document picker. Open a
  folder named `Season.01` and check the natural episode order.
- Open an invalid video, dismiss its error, then open a valid MKV. Also check
  rapid switching, seeking, pausing, reaching the end, and stopping playback.
- Repeat sharing with Anime4K off and Low enabled; confirm actual moving video
  in both modes. Simulator tests cannot verify external provider grants or
  real-device share-sheet behavior.

## Tools and release gate

Use Xcode Metal API Validation, Address Sanitizer for callback lifetime testing,
Instruments Allocations/Leaks and Metal System Trace. Run at least one 20-minute
session on the lowest-memory supported device and the fastest available iPad.
Resolve any compile failures from the first GitHub Actions run before making
compatibility or performance claims. HDR preservation, enhanced Picture in
Picture and zero-copy hardware decoding need additional implementation.
