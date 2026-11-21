"""Reproduce the offscreen native contact sheet on macOS with Xcode."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

STUDY = Path(__file__).resolve().parent
ROOT = STUDY.parents[2]
sys.path.insert(0, str(ROOT / "tools/benchmarks"))
from gate.ux import native_lease


def render(scratch, destination):
    build = ["xcrun", "swift", "build", "--package-path", str(ROOT / "app/macos"),
             "--scratch-path", str(scratch), "--disable-automatic-resolution",
             "--target", "ChiefPluginUI", "-c", "debug", "-j", "3"]
    subprocess.run(build, check=True)
    binary = Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
    # This private scratch directory contains objects only for the target and
    # its dependencies. Keep the probe beside the SwiftPM resource bundle.
    objects = sorted(binary.glob("*.build/**/*.o"))
    compiler = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                "-target", f"{platform.machine()}-apple-macosx26.0", "-I", str(binary / "Modules"),
                "-module-cache-path", str(scratch / "probe-module-cache")]
    for include in ["swift-cmark/src/include", "swift-cmark/extensions/include",
                    "swift-markdown/Sources/CAtomic/include", "swift-system/Sources/CSystem/include"]:
        path = scratch / "checkouts" / include
        compiler.extend(["-I", str(path), "-Xcc", "-fmodule-map-file=" + str(path / "module.modulemap")])
    probe = binary / "sizing-sheet"
    subprocess.run([*compiler, str(STUDY / "render.swift"), *map(str, objects), "-o", str(probe)], check=True)
    subprocess.run([str(probe), str(destination)], check=True)


if __name__ == "__main__":
    with native_lease(), tempfile.TemporaryDirectory(prefix="chief-sizing-") as scratch:
        render(Path(scratch), Path(sys.argv[1]).resolve())
