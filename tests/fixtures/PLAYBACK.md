`shared.mkv` and `shared.mp4` contain a generated color sequence, with no external
images, audio, or copyrighted video. Each contains 12 seconds / 288 frames of
64x48 H.264 video at 24 fps. Keeping these small files in the repository makes
the hosted iOS tests independent of Homebrew and encoder availability.

Generated with Python 3.12.14 and PyAV 19.0.1. To regenerate, install the optional
`av==19.0.1` Python package and run
`python tools/make_playback_fixtures.py`. The generator also decodes both samples
and verifies the frame counts and dimensions. CI does not require PyAV.
