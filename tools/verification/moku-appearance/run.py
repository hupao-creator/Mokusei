"""Exercise production Moku appearance boundaries without opening app windows."""
import argparse
import os
from pathlib import Path
import platform
import sys
import tempfile

repo = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(repo / "scripts/ci"))
from deadline import run

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--skip-build", action="store_true")
parser.add_argument("--scratch-path", type=Path, default=repo / "app/macos/.build")
options = parser.parse_args()
scratch = options.scratch_path.resolve()
package = repo / "app/macos"
environment = {**os.environ, "MOKUSEI_TEST_HEADLESS": "1"}
if not options.skip_build:
    status = run(["xcrun", "swift", "build", "--package-path", str(package),
                  "--scratch-path", str(scratch)], timeout=1800, env=environment)
    if status:
        raise SystemExit(status)
build = scratch / f"{platform.machine()}-apple-macosx/debug"
link_list = build / "Mokusei.product/Objects.LinkFileList"
objects = [line.strip().strip('"') for line in link_list.read_text().splitlines()
           if "/Mokusei.build/" not in line]
if not objects or any(not Path(item).is_file() for item in objects):
    raise SystemExit("Build current production modules before --skip-build")
with tempfile.TemporaryDirectory(prefix="mokusei-moku-appearance-") as output:
    binary = Path(output) / "moku-appearance"
    args = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
            "-warnings-as-errors", "-target", f"{platform.machine()}-apple-macosx26.0",
            "-I", str(build / "Modules"), "-F", str(build),
            "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker", str(build),
            "-module-cache-path", str(Path(output) / "modules")]
    for relative in ["swift-cmark/src/include", "swift-cmark/extensions/include",
                     "swift-markdown/Sources/CAtomic/include", "swift-system/Sources/CSystem/include"]:
        include = scratch / "checkouts" / relative
        args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
    status = run([*args, str(Path(__file__).with_name("main.swift")), *objects,
                  "-o", str(binary)], timeout=300, env=environment)
    if status:
        raise SystemExit(status)
    raise SystemExit(run([str(binary)], timeout=60, env=environment))
