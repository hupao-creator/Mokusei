"""Build the independent NSScrollView control beside the shared collectors."""
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess


def build_control(tools):
    source = Path(__file__).with_name("Control.swift")
    toolchain = subprocess.check_output(["xcodebuild", "-version"], text=True)
    digest = hashlib.sha256(source.read_bytes() + toolchain.encode()).hexdigest()
    stamp = tools / "reading-control-build.json"
    app = tools / "ReadingControl.app"
    executable = app / "Contents/MacOS/ReadingControl"
    if stamp.exists() and executable.exists() and json.loads(stamp.read_text()).get("sourceHash") == digest:
        return app
    executable.parent.mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.mokusei.external-benchmark.reading-control", "CFBundleName": "Reading Control",
        "CFBundleExecutable": "ReadingControl", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "26.0"}))
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-warnings-as-errors", "-parse-as-library",
                    str(source), "-o", str(executable)], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    stamp.write_text(json.dumps({"sourceHash": digest, "toolchain": toolchain,
                                "executableSHA256": hashlib.sha256(executable.read_bytes()).hexdigest()}, indent=2) + "\n")
    return app
