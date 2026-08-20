#!/usr/bin/env python3
import os
import pathlib
import re
import shutil
import subprocess
import sys


def write_text(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", errors="replace")


def main() -> int:
    temp = pathlib.Path(os.environ["RUNNER_TEMP"])
    log_path = temp / "xcodebuild.log"
    summary_path = temp / "xcode-summary.txt"
    exit_path = temp / "xcodebuild.exit"
    result_bundle = temp / "BuildResult.xcresult"
    derived = temp / "DerivedData"

    # The compact CI overlay intentionally excludes this upstream Firebase plist.
    # Restore the exact V0.1.3 baseline file before Xcode evaluates build inputs.
    script_dir = pathlib.Path(__file__).resolve().parent
    firebase_source = script_dir / "GoogleService-Info.plist"
    firebase_target = pathlib.Path.cwd() / "iTorrent" / "Core" / "Assets" / "GoogleService-Info.plist"
    if not firebase_source.is_file():
        print(f"Missing CI Firebase plist: {firebase_source}", file=sys.stderr)
        return 90
    firebase_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(firebase_source, firebase_target)
    print(f"Restored baseline Firebase plist: {firebase_target}", flush=True)

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

    # Keep a compact error-oriented file that GitHub's file API can always return.
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

    # Emit to Actions log as well, capped to the compact summary.
    print(summary_path.read_text(encoding="utf-8", errors="replace"), flush=True)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
