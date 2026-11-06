"""Release renderer A/B probe; each sample owns a fresh foreground app process."""
from pathlib import Path
from datetime import datetime
import hashlib
import json
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/verification"))
from native_replay import NativeReplay


def main():
    renderer = ROOT / "app/macos/Sources/Shared/PluginUI/Reading/SwiftUIMarkdownText.swift"
    if not renderer.is_file():
        raise SystemExit("Historical benchmark: SwiftUI text migration is reverted. "
                         "Use revision 39d0941 with matching rebuilt Release modules; "
                         "see swiftui-text-results.md. No benchmark was run.")
    output = ROOT / ".scratch/thread-swiftui-performance" / datetime.now().strftime("%Y%m%d-%H%M%S")
    output.mkdir(parents=True, exist_ok=True)
    print("Evidence:", output, flush=True)
    source = Path(__file__).with_name("SwiftUITextBenchmark.swift")
    replay = NativeReplay(ROOT, "ThreadTextBenchmark", "com.mokusei.thread-text-benchmark", configuration="release")
    samples = []
    try:
        replay.acquire()
        replay.compile([source], extra_args=["-O"])
        metadata = {
            "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
            "dirty": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
            "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
            "executableSHA256": hashlib.sha256(replay.executable.read_bytes()).hexdigest(),
            "configuration": "release, -enable-testing; probe -O",
            "os": subprocess.check_output(["sw_vers"], text=True),
            "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
            "swift": subprocess.check_output(["swift", "--version"], text=True),
        }
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        for round_index in range(4):
            renderers = ["appkit", "swiftui"] if round_index % 2 == 0 else ["swiftui", "appkit"]
            for fixture in ["prose", "mixed"]:
                for scope in ["plain", "thread"]:
                    for renderer in renderers:
                        name = f"{round_index}-{fixture}-{scope}-{renderer}"
                        arguments = ([] if renderer == "appkit" else ["--swiftui"])
                        if fixture == "mixed": arguments.append("--mixed")
                        if scope == "thread": arguments.append("--thread-scope")
                        # LaunchServices appends to redirected files. Each fresh
                        # process must have its own unambiguous terminal record.
                        for filename in ("stdout.log", "stderr.log"):
                            (replay.root / filename).unlink(missing_ok=True)
                        status = replay.run(arguments, timeout=90, env=os.environ)
                        replay.export(output / name)
                        log = (replay.root / "stdout.log").read_text()
                        rows = [line.removeprefix("BENCHMARK_JSON ") for line in log.splitlines() if line.startswith("BENCHMARK_JSON ")]
                        if status or len(rows) != 1:
                            raise RuntimeError(f"Invalid sample {name}: exit {status}; see retained logs")
                        sample = dict(json.loads(rows[0]), round=round_index)
                        samples.append(sample)
                        (output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
                        print(name, "warm CPU ms", round(sample["warmMountCPUMs"], 2), flush=True)
    finally:
        replay.close()


if __name__ == "__main__":
    main()
