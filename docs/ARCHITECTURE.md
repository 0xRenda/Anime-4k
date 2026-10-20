# Rendering and shader port

## Pipeline

```text
VLC demux/CPU decode and color conversion
    → vmem lock/unlock/display callbacks at VLC's presentation timestamp
    → aligned BGRX staging storage
    → bounded CVPixelBuffer pool (maximum 3)
    → latest-frame slot
    → CVMetalTextureCache
    → Anime4K compute passes, rgba16Float/r16Float/rg16Float intermediates
    → aspect-fit/fill Metal presentation
```

`RoxyVLCVideoOutput.m` contains the VLCKit compatibility boundary. The pinned
VLCKit source implements `-libVLCMediaPlayer`, although it is not part of the
normal public media player header. Roxy declares the selector locally, checks
for it at runtime, and uses the public libvlc callback API. Future VLCKit updates
must verify this boundary. There are no private object-layout offsets or KVC
lookups. The pinned source can be inspected at
[VLCMediaPlayer.m](https://github.com/videolan/vlckit/blob/8f5ce02f09a7da5d061a24ddac3cb432f2a9b332/Sources/Playback/VLCMediaPlayer.m).

The callback owner is associated with the media player for its full lifetime;
format-specific storage retains its thread-safe frame queue until cleanup. This accounts for
VLC 4's asynchronous stop. Callbacks are reconfigured only for a stopped or new
player. Restoring native rendering uses the original drawable setter: setting
NULL vmem callbacks alone would leave VLC selecting the vmem output.

The UI never reads staging storage concurrently. At display time a complete
frame is copied into an IOSurface-backed pixel buffer. The renderer retains both
the pixel buffer and its CVMetalTexture until GPU completion. It keeps at most
one GPU command in flight and one latest pending frame; it drops frames instead
of building an unbounded queue. Background transitions pause Metal submission.

## Full shader corpus

`tools/port_anime4k.py` translates every `.glsl` under `Anime4K-master/glsl`.
It emits 49 Metal source files and a manifest. Matrix coefficients and column
order are preserved. Offline Metal compilation explicitly targets iOS 15.0 and
Metal language 2.3, rather than inheriting the build machine's newer SDK minimum.
Runtime compilation also uses Metal 2.3 and can fall back to source if a bundled
library cannot load. Differences from the source language are:

- mpv hook/bind/save/size/when directives become an explicit runtime pass graph.
- GLSL vectors become Metal vectors; matrix scalar constructors explicitly form columns.
- Sample positions use pixel centers, and kernels guard excess dispatch threads.
- Helper functions receive their sampler, positions and textures explicitly.
- Bilateral array extents are compile-time constants with thread address spaces.
- The upstream median helper receives a terminal fallback return for a rounding
  or non-finite edge case where the source otherwise has no return.
- Missing conditional BIND textures skip a pass, matching mpv hook behavior.
- A MAIN texture referenced implicitly by a source hook is bound explicitly.

`PREKERNEL` hooks execute in the selected sequential chain before presentation.
The player is an SDR RGB pipeline, rather than mpv's full color-managed rendering
graph. Shipping every shader does not mean every experimental/GAN variant can
run in real time on a phone. The two AutoDownscale shaders are prefilters and
need an appropriate upscaling chain to produce a complete upscale.

## Presets and scheduling

The three default chains are in `manifest.json`. Automatic chooses High for
Apple GPU family 9+ with at least 8 GiB RAM, Medium for family 7+, and Low for
older devices. M5-class GPUs are included through family support. This uses
ordinary Metal compute and does not claim specialized M5 tensor or Neural Engine
kernels. CPU decoding uses VLC's existing scheduling.

Serious thermal state or Low Power Mode caps the effective preset at Low.
Critical thermal state bypasses filtering. Thirty persistently expensive GPU
frames reduce the quality ceiling for that playback session. There is no
automatic upward oscillation during playback. A manually chosen advanced shader
is not automatically replaced by a different model; critical temperature still
bypasses it and memory limits still apply.

Intermediate textures are assigned by last use and reused when dependencies
allow it. Unique intermediate allocations are limited to 192/320/640 MiB for
Low/Medium/High. These budgets exclude VLC's decoder, pipeline objects and CPU
input buffers. A rejected allocation plan falls back to original video and is
not retried each frame. Video dimensions, window size and quality invalidate
the plan. Compilation runs off the main thread, and unprocessed frames remain
visible while shaders prepare.

## Known limits requiring further work

- vmem forces software decoding and copies. A custom VLCKit/libvlc Metal output
  module is needed for a hardware decode/zero-copy enhancement path.
- HDR/wide-color metadata and EDR output are not carried through the BGRA8 path.
- Anime4K output is local. It is not injected into Chromecast receiver playback.
- Native VLC Picture in Picture requires disabling Anime4K and reopening playback.
- Snapshot output remains VLC's own image; it does not capture the Metal upscale.
- Anamorphic sources, unusual rotations/crops, subtitles, output route changes
  and device-specific performance need physical-device testing.
- Devices unable to run iOS 15 are outside this upstream app's deployment range.

## Validation

Python tests verify all generated files, original matrix coefficients, hashes,
49 shader graphs at five scale ratios, conditional skipping, preset dimensions,
settings and target membership. The CPU reference evaluates the original small
CNN directly, including half-float intermediate rounding. `test_metal.sh`
compiles every shader for macOS, typechecks and builds the actual engine, then
compares its GPU result against that reference if a Metal device exists. A
GPU-less runner reports that test as skipped, not passed. The archive step
compiles every shader for iOS and builds the actual iOS renderer and VLC bridge.
`verify_ipa.py` checks the resulting app binary, device families and libraries.


## Explicit pixel layout and live controls (4.0.2)

The pinned VLC 4 ABI defines RV32 as XRGB in memory order. Requesting RV32
and interpreting it as CoreVideo BGRA shifted all color channels. The callback
now requests the explicit BGRA fourcc, matching both the pixel buffer pool and
Metal texture. Synthetic BT.709 H.264 8-bit and HEVC 10-bit MKVs exercise the
complete VLC conversion → callback → CNN → presentation path. Readback uses
an additional render target and the same presentation shader; normal playback
keeps framebuffer-only drawables and performs no CPU readback.

MTKView targets display pixels using the window screen scale, including Retina
iPads. The panel reports actual input/output/display dimensions, encoded passes
and GPU completion timing. Original comparison bypasses the CNN while retaining
the active decoder and frame. Enabling from a native session restarts the video
output asynchronously and restores position/pause; a shared lease retains file
access until both the old reader and replacement session release it.
