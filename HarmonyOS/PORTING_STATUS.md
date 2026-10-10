# BTMobile HarmonyOS V0.1.1

Source baseline: iOS V1.2.5, main commit d331eb51ff9a3d33d1ea6233de690e1430e37f1c.
This is a new ArkTS/ArkUI + NDK C++ implementation, not an iOS binary wrapper.
Minimum API: HarmonyOS 5.0, API 12. Target architecture: arm64-v8a.
V0.1.1 change baseline: HarmonyOS V0.1.0 commit 918a9ffeab73b57aa7b2e97a419599d5b469b470.
BT client identity: `Htorrent/0.1.1`, peer fingerprint prefix `-HT0110-`.

## V0.1.1 scope and verification boundary

- Replace Linux NETLINK interface/route enumeration with HarmonyOS NetworkKit (API 11+, minimum app API remains 12). Only use the OS default network; never select an alternate bearer to bypass a VPN.
- Preferred default BT TCP/UDP port 6882; preserve libtorrent's native retry (10 alternate ports), OS-selected port fallback, outgoing ephemeral ports and IPv4/IPv6 discovery. UPnP/NAT-PMP negotiate external mappings themselves; the external port is not forced to 6882. DHT, LSD, NAT-PMP, UPnP and incoming/outgoing uTP are enabled. Existing default Tracker list is deduplicated into new and restored tasks.
- Network changes trigger in-place socket recovery, not session destruction. Unchanged healthy connections are not restarted by polling. Failed listener retries are limited to once per 30 seconds.
- Bounded DHT/Tracker/listener diagnostics in the app and privacy-safe native logs.
- Persist background opt-in independently of the actual OS continuous-task approval. Errors remain visible, with retry backoff; the UI does not claim approval merely because the switch is on.
- File manager, archive implementation, TXT and AVPlayer are unchanged from V0.1.0.

Reserved N-API operations (no new settings controls yet): `getNetworkSettings`, `setNetworkSettings` with partial `settings` object (`listenPort`, `dht`, `lsd`, `natPmp`, `upnp`, `utp`), and `setListenPort` with integer `port`. Preferred ports are 1024–65535. Values are atomically saved to `.state/network.json`, restored on launch, and applied in the existing session. Diagnostics distinguish the configured preference from the effective port. Local playback HTTP uses a separate loopback port.

V0.1.0 was successfully built, signed locally and installed on nova13. Its real-device magnet/download test failed despite the same link working on iOS/Android. Only the local playback listener was observed, not BT sockets. V0.1.1 targets that failure; passing cloud compilation or host tests must NOT be represented as passing nova13 downloads.

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
- A nova13-bound debug Profile is available locally. Cloud output is an unsigned HAP; private keys and signing passwords remain local. V0.1.1 needs a separate on-device download/background regression test after installation.

## Build

The GitHub workflow `.github/workflows/harmony-v010.yml` uses the official Huawei command-line tools, verifies their SHA-256, compiles native dependencies and ArkTS, and verifies that the resulting HAP contains `ets/modules.abc` and `libbtmobile.so`.
No private signing material is required or uploaded. Signing is performed locally with the existing matching debug Profile.

## Safety and tests

`tests/range_test.cpp` tests byte-range edge cases and archive traversal rejection. It does not substitute for network or device integration tests.
`tests/core_test.cpp` uses a generated local payload and a real HTTP tracker response to test peer discovery without `x.pe`, magnet metadata, byte-verified download, pause, HTTP ranges, ZIP roundtrip and settings validation/persistence. `tests/network_test.cpp` checks IPv4/IPv6 conversion against the SDK's own structures, routes, VPN isolation and unavailable/denied network inputs. These host tests do not replace real-device NetworkKit access, public DHT or lock-screen tests.
Extraction writes to a new destination, never overwrites source data. Partial output is retained on cancellation/failure.
Only user-selected document-picker files are imported into the sandbox. Local media file handles are released with the player.
