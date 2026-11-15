# Round-video capture cadence

Build 23 removes the legacy round-video dual-camera 30 fps cap. Its format selector prioritizes an
actual supported cadence closest to 60 fps before resolution/photo quality, inspects every advertised
frame-rate range and accepts formats whose maximum exceeds 60. MultiCam capture requires a compatible
format and limits each input to VGA to keep the two-stream budget bounded; final round-video output
size is unchanged. A device without a compatible 60 fps format falls back to its real supported rate.
Ordinary photo/video format selection keeps its existing policy.

The selected cadence is applied to both active device frame durations and the round-video capture
input override. On supported OS versions automatic video frame-rate adjustment is disabled before
setting explicit durations. This prevents a 60 fps encoder hint from masking a 30 fps capture source.
The modern camera path already selects 60 fps and retains its current mode routing.

Nine host tests exercise the pure format/cadence decisions, including a 60 fps range after a 30 fps
range, high-speed formats, resolution priority, MultiCam constraints and hardware fallback. A full
app build checks AVFoundation integration. These checks cannot establish real recorded frame cadence:
record and send a circle on the affected iPhone, inspect the output frame timestamps, and compare
front/rear camera, camera switching, dual mode, preview and received playback. That device validation
remains outstanding because the affected model and clip are unavailable.

The Foundation cadence cases are available as the repository host target
`//submodules/Camera:CameraCadenceTests`. Run with the pinned Bazel executable and full Xcode;
set `--macos_minimum_os=14.0 --host_macos_minimum_os=14.0` when the SDK is newer than the host.

If xcode-select points to Command Line Tools, the host XCTest runtime also needs test environment
paths to full Xcode's MacOSX Developer `usr/lib`, `Library/Frameworks` and `Library/PrivateFrameworks`
(`DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH`). This does not require changing the system selection.
