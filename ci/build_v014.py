#!/usr/bin/env python3
import os
import pathlib
import re
import shutil
import subprocess
import sys


def write_text(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", errors="replace")


def replace_once(path: pathlib.Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"{label}: already applied", flush=True)
        return
    if old not in text:
        raise RuntimeError(f"{label}: expected anchor not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"{label}: applied", flush=True)


def restore_v013_libtorrent_baseline(source_root: pathlib.Path) -> None:
    core = source_root / "Submodules" / "LibTorrent-Swift" / "LibTorrent" / "Core"
    handle_h = core / "TorrentHandle" / "TorrentHandle.h"
    handle_mm = core / "TorrentHandle" / "TorrentHandle.mm"
    settings_mm = core / "SessionSettings" / "SessionSettings.mm"

    # V0.1.3 stable peer API used by TorrentDetailsViewModel.
    replace_once(
        handle_h,
        "@property (readonly) BOOL isPrivate;\n",
        "@property (readonly) BOOL isPrivate;\n@property (readonly) NSArray<NSDictionary<NSString *, NSString *> *> *peerStats;\n",
        "V0.1.3 peerStats header",
    )

    peer_method = r'''- (NSArray<NSDictionary<NSString *, NSString *> *> *)peerStats {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *result = [NSMutableArray array];
    [self performOperation:@"peerStats" action:^(lt::torrent_handle const &handle) {
        std::vector<lt::peer_info> peers;
        handle.get_peer_info(peers);
        for (auto const &peer : peers) {
            auto endpoint = peer.remote_endpoint();
            auto addressString = endpoint.address().to_string();
            if (addressString.empty()) { continue; }
            NSString *host = [NSString stringWithUTF8String:addressString.c_str()];
            if (host == nil || host.length == 0) { continue; }
            unsigned int port = static_cast<unsigned int>(endpoint.port());
            NSString *client = peer.client.empty() ? @"" : ([NSString stringWithUTF8String:peer.client.c_str()] ?: @"");
            NSString *transport = (peer.flags & lt::peer_info::utp_socket) ? @"uTP" : @"TCP";
            NSString *direction = (peer.flags & lt::peer_info::outgoing_connection) ? @"OUT" : @"IN";
            NSString *holepunched = (peer.flags & lt::peer_info::holepunched) ? @"1" : @"0";
            [result addObject:@{
                @"ip": host,
                @"port": [NSString stringWithFormat:@"%u", port],
                @"downloadRate": [NSString stringWithFormat:@"%d", peer.payload_down_speed],
                @"uploadRate": [NSString stringWithFormat:@"%d", peer.payload_up_speed],
                @"totalDownload": [NSString stringWithFormat:@"%lld", (long long)peer.total_download],
                @"totalUpload": [NSString stringWithFormat:@"%lld", (long long)peer.total_upload],
                @"client": client,
                @"transport": transport,
                @"direction": direction,
                @"holepunched": holepunched,
            }];
        }
    }];
    return result;
}

'''
    mm_text = handle_mm.read_text(encoding="utf-8")
    if "- (NSArray<NSDictionary<NSString *, NSString *> *> *)peerStats" not in mm_text:
        anchor = "- (void)updateSnapshot {"
        if anchor not in mm_text:
            raise RuntimeError("V0.1.3 peerStats implementation: updateSnapshot anchor not found")
        handle_mm.write_text(mm_text.replace(anchor, peer_method + anchor, 1), encoding="utf-8")
        print("V0.1.3 peerStats implementation: applied", flush=True)
    else:
        print("V0.1.3 peerStats implementation: already applied", flush=True)

    dht_block = '''    // BTMobile: make trackerless magnets discover peers reliably via DHT.\n    if (_isDhtEnabled) {\n        settings.set_str(lt::settings_pack::dht_bootstrap_nodes,\n                         "dht.libtorrent.org:25401,router.bittorrent.com:6881,dht.transmissionbt.com:6881,router.bt.ouinet.work:6881");\n        settings.set_bool(lt::settings_pack::use_dht_as_fallback, false);\n    }\n    settings.set_bool(lt::settings_pack::announce_to_all_tiers, true);\n    settings.set_bool(lt::settings_pack::announce_to_all_trackers, true);\n    settings.set_bool(lt::settings_pack::prefer_udp_trackers, true);\n\n'''
    settings_text = settings_mm.read_text(encoding="utf-8")
    if "router.bt.ouinet.work:6881" not in settings_text:
        anchor = "    settings.set_str(lt::settings_pack::peer_fingerprint, [_peerFingerprint UTF8String]);\n\n"
        if anchor not in settings_text:
            raise RuntimeError("V0.1.3 DHT baseline: peer_fingerprint anchor not found")
        settings_mm.write_text(settings_text.replace(anchor, anchor + dht_block, 1), encoding="utf-8")
        print("V0.1.3 DHT/bootstrap baseline: applied", flush=True)
    else:
        print("V0.1.3 DHT/bootstrap baseline: already applied", flush=True)


def fix_v014_storage_combine(source_root: pathlib.Path) -> None:
    path = source_root / "iTorrent" / "Services" / "TorrentService" / "TorrentService.swift"
    old = '''            Publishers.combineLatest(\n                preferences.$storageScopes,\n                preferences.$btMobileManagedStorageScopes\n            )\n            .sink { [unowned self] external, managed in\n                session.storages = external.merging(managed) { external, _ in external }\n            }\n'''
    new = '''            Publishers.CombineLatest(\n                preferences.$storageScopes,\n                preferences.$btMobileManagedStorageScopes\n            )\n            .sink { [unowned self] values in\n                let (external, managed) = values\n                session.storages = external.merging(managed) { external, _ in external }\n            }\n'''
    replace_once(path, old, new, "V0.1.4 managed storage CombineLatest")


def main() -> int:
    temp = pathlib.Path(os.environ["RUNNER_TEMP"])
    log_path = temp / "xcodebuild.log"
    summary_path = temp / "xcode-summary.txt"
    exit_path = temp / "xcodebuild.exit"
    result_bundle = temp / "BuildResult.xcresult"
    derived = temp / "DerivedData"
    source_root = pathlib.Path.cwd()

    # The compact CI overlay intentionally excludes this upstream Firebase plist.
    # Restore the exact V0.1.3 baseline file before Xcode evaluates build inputs.
    script_dir = pathlib.Path(__file__).resolve().parent
    firebase_source = script_dir / "GoogleService-Info.plist"
    firebase_target = source_root / "iTorrent" / "Core" / "Assets" / "GoogleService-Info.plist"
    if not firebase_source.is_file():
        print(f"Missing CI Firebase plist: {firebase_source}", file=sys.stderr)
        return 90
    firebase_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(firebase_source, firebase_target)
    print(f"Restored baseline Firebase plist: {firebase_target}", flush=True)

    try:
        restore_v013_libtorrent_baseline(source_root)
        fix_v014_storage_combine(source_root)
    except Exception as exc:
        print(f"CI source preparation failed: {exc}", file=sys.stderr)
        return 91

    if result_bundle.exists():
        subprocess.run(["rm", "-rf", str(result_bundle)], check=False)

    cmd = [
        "xcodebuild",
        "-workspace", "iTorrent.xcworkspace",
        "-scheme", "iTorrent",
        "-configuration", "Release",
        "-sdk", "iphoneos",
        "-destination", "generic/platform=iOS",
        "-derivedDataPath", str(derived),
        "-resultBundlePath", str(result_bundle),
        "-skipMacroValidation",
        "-skipPackagePluginValidation",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "COMPILER_INDEX_STORE_ENABLE=NO",
        "clean", "build",
    ]

    marker = "Executing: " + " ".join(cmd)
    print(marker, flush=True)
    write_text(summary_path, marker + "\n")

    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    output = proc.stdout or ""
    write_text(log_path, marker + "\n" + output)
    write_text(exit_path, str(proc.returncode) + "\n")

    interesting = []
    patterns = [
        re.compile(r"\berror:\s", re.I),
        re.compile(r"\bfatal error:\s", re.I),
        re.compile(r"undefined symbols", re.I),
        re.compile(r"linker command failed", re.I),
        re.compile(r"could not build", re.I),
        re.compile(r"could not resolve", re.I),
        re.compile(r"failed with", re.I),
        re.compile(r"BUILD FAILED", re.I),
    ]
    lines = output.splitlines()
    for idx, line in enumerate(lines):
        if any(p.search(line) for p in patterns):
            start = max(0, idx - 2)
            end = min(len(lines), idx + 4)
            block = "\n".join(lines[start:end])
            if block not in interesting:
                interesting.append(block)

    tail = "\n".join(lines[-250:])
    compact = [
        marker,
        f"xcodebuild_exit={proc.returncode}",
        f"result_bundle_exists={result_bundle.exists()}",
        "",
        "=== MATCHED ERROR CONTEXT ===",
        "\n\n---\n\n".join(interesting[-80:]) if interesting else "(no regex error lines matched)",
        "",
        "=== LAST 250 LINES ===",
        tail,
        "",
    ]
    write_text(summary_path, "\n".join(compact))

    print(summary_path.read_text(encoding="utf-8", errors="replace"), flush=True)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
