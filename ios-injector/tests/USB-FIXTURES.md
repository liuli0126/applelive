# USB decoder fixtures

`native-usb.alusb` is an exact recording from AppleLive's Windows native OBS
output (OBS 30.2.3, 640x360, 30 fps, x264 baseline / ffmpeg AAC 48 kHz stereo).
The media source was this repository's `fixture.mp4`. It contains 65 video
access units, one ASC, and 100 AAC packets. No phone/user media is included.
Recreate it with `native-obs-usb/tests/obs_host.py` and use `native-0.alusb`.

`multislice-usb.alusb` contains 20 video frames at 320x180/10 fps. It was created
from FFmpeg's `testsrc2` with x264 baseline, zerolatency, slices=4,
keyint=10, scenecut=0, AUD and repeated headers. With this size and encoder's
sliced threading, the actual output has three slices per picture. The Annex-B output was grouped
using `sender.AccessUnitParser`, then wrapped in ALUSB frames with flags bit 1
(complete access unit) set. This exercises the former partial-picture defect.

The fixtures are project-generated test patterns. Each file uses a big-endian
uint32 payload size followed by the documented AppleLive media payload.
