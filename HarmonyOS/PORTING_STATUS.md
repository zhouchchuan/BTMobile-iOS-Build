# BTMobile HarmonyOS V0.1.0

Source baseline: iOS V1.2.5, main commit d331eb51ff9a3d33d1ea6233de690e1430e37f1c.
This is a new ArkTS/ArkUI + NDK C++ implementation, not an iOS binary wrapper.
Minimum API: HarmonyOS 5.0, API 12. Target architecture: arm64-v8a.
BT client identity: `Htorrent/0.1.0`, peer fingerprint prefix `-HT0100-`.

## Implemented in source, pending build/device validation

- Real libtorrent 2.1 source at 75a08775ba32bdb62157f9e49a786ecdd9f0a0fa (same revision as iOS).
- Magnet/torrent addition, metadata exchange, DHT, UDP/HTTP trackers, TCP/uTP, pause/resume, seeding and resume files.
- Task file selection and file-manager resolution of incomplete video files.
- Loopback-only, unguessable-token HTTP byte-range endpoint. Reads wait for verified pieces, do not read sparse holes, and do not resume manually paused tasks.
- Native AVPlayer surface, seek bar, fullscreen orientation, audio/subtitle track selection and timed subtitle overlay; animated controls auto-hide after two seconds.
- Sandboxed download directory browsing/import; UTF-8 TXT editing and link detection.
- libarchive extraction with password input, Chinese failures, progress and cancellation, traversal/symlink rejection.
- ZIP creation, file rename and native image preview.
- Opt-in background data-transfer continuous task registration while downloads/seeding are active. Stops when all tasks are paused. Registration errors are surfaced, not silently treated as success.

## Not yet at iOS feature parity

- System AVPlayer is NOT VLC. MKV codecs, ASS styling and bitmap subtitles depend on system capability and need real-device testing.
- Background continuous task registration is implemented but lock-screen survival has not been tested; no guarantee of uninterrupted downloading.
- Subscription/policy/heartbeat/remote Tracker administration, WebDAV, PiP, file sharing, and advanced file operations are not yet ported.
- Complete encrypted/split-volume compatibility is not yet implemented. ZIP creation is supported; libarchive does not support every encryption scheme accepted by iOS's 7-Zip backend.
- No real device has been tested. No UDID-bound debug Profile is available. Cloud output must be called an unsigned HAP, not a directly installable signed package.

## Build

The GitHub workflow `.github/workflows/harmony-v010.yml` uses the official Huawei command-line tools, verifies their SHA-256, compiles native dependencies and ArkTS, and verifies that the resulting HAP contains `ets/modules.abc` and `libbtmobile.so`.
No private signing material is required or uploaded. Signing will be performed locally after a matching debug Profile is supplied.

## Safety and tests

`tests/range_test.cpp` tests byte-range edge cases and archive traversal rejection. It does not substitute for network or device integration tests.
Extraction writes to a new destination, never overwrites source data. Partial output is retained on cancellation/failure.
Only user-selected document-picker files are imported into the sandbox. Local media file handles are released with the player.
