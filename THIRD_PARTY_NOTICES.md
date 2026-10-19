# Third-party notices

Roxy Player is an independent modification of VLC for iOS and incorporates the
Anime4K shader corpus supplied in this workspace. It is not an official VLC
release and is not endorsed by VideoLAN or Anime4K's authors.

| Component | Attribution and license |
| --- | --- |
| VLC iOS application source | VLC authors and VideoLAN; GPLv2 or later and MPLv2, as described in `vlc-ios-master/COPYING` |
| VLCKit / libvlc | VideoLAN and contributors; retain their bundled LGPL/GPL and dependency notices |
| Anime4K shaders | Copyright (c) 2019–2021 bloc97; MIT notices retained verbatim in generated sources |
| Anime4K AutoDownscalePre x2/x4 | Public-domain/Unlicense notice retained verbatim from those input files |
| Other VLC dependencies | Respective authors and licenses, as retained by the upstream source and dependency distributions |

Original projects: [VLC iOS](https://code.videolan.org/videolan/vlc-ios/),
[VLCKit](https://code.videolan.org/videolan/VLCKit),
[Anime4K](https://github.com/bloc97/Anime4K).
The existing [Anime4KMetal](https://github.com/imxieyi/Anime4KMetal) project was
consulted as a reference for GLSL-to-Metal feasibility; its source is not bundled
in this implementation.

The Roxy integration files and build tooling in this folder are supplied under
GPLv2 or later. The generated shader sources retain their upstream MIT or
public-domain notices. When distributing binaries, include applicable notices
and make corresponding source available according to the relevant licenses.
The build workflow does not publish an app to an app store.
