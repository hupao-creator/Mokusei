"""Compile production scrollbar policy into a windowless native boundary replay."""
from pathlib import Path
import os
import platform
import sys
import tempfile

repo = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo / "scripts/ci"))
from deadline import run

cache = repo / ".build/scrollbars/modules"
cache.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="mokusei-scrollbars-") as output:
    binary = Path(output) / "scrollbars"
    status = run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
        "-target", f"{platform.machine()}-apple-macosx26.0",
        "-module-cache-path", str(cache),
        str(repo / "app/macos/Sources/Shared/PluginUI/Design/NativeScrollView.swift"),
        str(repo / "app/macos/Sources/Shared/PluginUI/Design/NativeWebScrollbarStyle.swift"),
        str(Path(__file__).with_name("web.swift")),
        str(Path(__file__).with_name("main.swift")), "-o", str(binary),
    ], timeout=300)
    if status:
        raise SystemExit(status)
    raise SystemExit(run([str(binary)], timeout=30,
                         env={**os.environ, "MOKUSEI_TEST_HEADLESS": "1"}))
