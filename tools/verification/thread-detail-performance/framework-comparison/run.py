"""Compare three actual Release Markdown renderers in one foreground native host."""
import argparse
from datetime import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import statistics
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
RENDERERS = ["production", "textual", "markdownui"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_identity():
    digest = hashlib.sha256()
    paths = []
    for folder in ["Sources/Core", "Sources/Shared/PluginAPI", "Sources/Shared/PluginUI", "Plugins"]:
        paths.extend(p for p in (REPO / "app/macos" / folder).rglob("*") if p.is_file())
    paths.extend([REPO / "app/macos/Package.swift", REPO / "app/macos/Package.resolved"])
    paths.extend(p for p in HERE.rglob("*") if p.is_file() and ".build" not in p.parts
                 and p.suffix in {".swift", ".py"})
    for path in sorted(paths):
        digest.update(str(path.relative_to(REPO)).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def fixtures(destination, supplied):
    prose = "A paragraph with **strong text**, `inline code`, a [link](https://example.com), and 中文阅读。 "
    values = {
        "prose": "\n\n".join(f"Paragraph {i}. " + prose * 4 for i in range(160)),
        "mixed": "\n\n".join(
            f"## Section {i}\n\n" + prose * 3
            + "\n\n- First list item\n- Second list item with a longer sentence that can wrap\n\n"
            + "| Name | Status | Notes |\n|---|---|---|\n"
            + "| Alpha | Ready | A moderately long cell that wraps at narrow widths |\n| Beta | | 中文🙂 |\n\n"
            + f"```swift\nlet value = {i}\nprint(value)\n```" for i in range(40)),
    }
    if supplied:
        values["local-report"] = supplied.read_text()
    paths = {}
    for label, content in values.items():
        path = destination / (label + ".md")
        path.write_text(content)
        paths[label] = path
    return paths


def summarize(samples):
    metrics = ["coldMountCPUMs", "warmMountCPUMs", "coldMountWallMs", "warmMountWallMs",
               "scrollCPUMs", "resizeCPUMs", "mountedFootprintMiB", "nativeTextViews", "nativeViews", "warmHeight"]
    result = {}
    for fixture in sorted({s["fixture"] for s in samples}):
        result[fixture] = {}
        for renderer in RENDERERS:
            rows = [s for s in samples if s["fixture"] == fixture and s["renderer"] == renderer]
            if not rows:
                continue
            stats = {key: {"median": statistics.median(s[key] for s in rows),
                           "min": min(s[key] for s in rows), "max": max(s[key] for s in rows)}
                     for key in metrics}
            lateness = sorted(v for s in rows for v in s["scrollLatenessMs"])
            stats["scrollLatenessP95Ms"] = lateness[int((len(lateness) - 1) * .95)]
            stats["scrollLatenessMaxMs"] = max(lateness)
            stats["samples"] = len(rows)
            result[fixture][renderer] = stats
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Optional private real reply; retained only in local evidence")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--skip-build", action="store_true", help="Only after building this exact source identity")
    parser.add_argument("--capture", action="store_true", help="Separate visual run; never pool its timing with normal runs")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("rounds must be positive")
    output = args.output or REPO / ".scratch/markdown-framework-comparison" / datetime.now().strftime("%Y%m%d-%H%M%S")
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    print("Evidence:", output, flush=True)
    fingerprint = source_identity()
    command = ["swift", "build", "--package-path", str(HERE), "-c", "release", "--disable-sandbox"]
    if not args.skip_build:
        with (output / "build.log").open("w") as log:
            subprocess.run(command, cwd=REPO, check=True, stdout=log, stderr=subprocess.STDOUT)
    binary_dir = Path(subprocess.check_output([*command, "--show-bin-path"], text=True).strip())
    if source_identity() != fingerprint:
        raise RuntimeError("Production or benchmark sources changed during build")
    executable = binary_dir / "MarkdownFrameworkComparison"
    metadata = {
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "dirty": subprocess.check_output(["git", "status", "--short"], cwd=REPO, text=True),
        "sourceSHA256": fingerprint, "executableSHA256": sha(executable),
        "packageResolved": json.loads((HERE / "Package.resolved").read_text()),
        "buildCommand": command, "buildSkipped": args.skip_build,
        "swiftPMResourceFallbackDirectory": str(binary_dir),
        "swift": subprocess.check_output(["swift", "--version"], text=True),
        "os": subprocess.check_output(["sw_vers"], text=True),
        "hardware": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "capture": args.capture,
        "scope": "Production NativeMarkdownView and library public views, same ScrollView/NSHostingView; no transport, panel or line entrance",
    }
    samples = []
    with tempfile.TemporaryDirectory(prefix="mokusei-native-replay-framework-") as temporary:
        staging = Path(temporary).resolve()
        app = staging / "MarkdownFrameworkComparison.app"
        macos = app / "Contents/MacOS"
        macos.mkdir(parents=True)
        shutil.copy2(executable, macos / executable.name)
        resources = app / "Contents/Resources"
        resources.mkdir()
        for bundle in binary_dir.glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
            # Production resolves packaged resources here. Candidate SwiftPM
            # accessors can use their generated absolute build-directory fallback;
            # keep that directory intact and record it in the measurement receipt.
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": "com.mokusei.markdown-framework-comparison",
                          "CFBundleName": executable.name, "CFBundleExecutable": executable.name,
                          "CFBundlePackageType": "APPL", "NSHighResolutionCapable": True,
                          "LSMinimumSystemVersion": "26.0"}, file)
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
        inputs = fixtures(staging, args.source)
        metadata["fixtures"] = {key: {"sha256": sha(path), "bytes": path.stat().st_size} for key, path in inputs.items()}
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
        shutil.copy2(HERE / "Sources/Benchmark.swift", output / "Benchmark.swift")
        shutil.copy2(HERE / "Package.resolved", output / "Package.resolved")
        for label, path in inputs.items():
            shutil.copy2(path, output / (label + ".md"))
        lock_path = Path(tempfile.gettempdir()) / f"mokusei-note-replay-{os.getuid()}.lock"
        with lock_path.open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for repetition in range(args.rounds):
                # Rotate all three positions, rather than always warming the OS
                # caches with production first. Every sample is a fresh process.
                order = RENDERERS[repetition % 3:] + RENDERERS[:repetition % 3]
                for fixture, path in inputs.items():
                    for renderer in order:
                        name = f"{repetition}-{fixture}-{renderer}"
                        folder = output / name
                        folder.mkdir()
                        result_path = staging / (name + ".json")
                        launch = ["open", "-W", "-n", "--stdout", str(folder / "stdout.log"),
                                  "--stderr", str(folder / "stderr.log"),
                                  "--env", "MOKUSEI_PERFORMANCE=off", "--env", "MOKUSEI_LAYOUT_LOG=0",
                                  str(app), "--args", renderer, str(path), str(result_path)]
                        if args.capture:
                            launch.append(str(folder))
                        try:
                            subprocess.run(launch, cwd=staging, check=True, timeout=120)
                        finally:
                            # LaunchServices is a separate process: timing out
                            # `open -W` alone must not strand the measured app.
                            receipt = result_path.with_suffix(".pid")
                            if receipt.is_file():
                                pid = int(receipt.read_text())
                                identity = subprocess.run(["ps", "-p", str(pid), "-o", "comm="],
                                                          capture_output=True, text=True, timeout=2)
                                if identity.returncode == 0 and identity.stdout.strip() == str(macos / executable.name):
                                    try:
                                        subprocess.run(["sample", str(pid), "2", "1", "-file", str(folder / "unfinished-sample.txt")],
                                                       capture_output=True, timeout=10)
                                    finally:
                                        try:
                                            os.kill(pid, signal.SIGTERM)
                                        except ProcessLookupError:
                                            pass
                        if not result_path.is_file():
                            raise RuntimeError(f"Incomplete sample {name}; inspect stderr/stdout")
                        sample = json.loads(result_path.read_text())
                        if sample["captured"] != args.capture or sample["renderer"] != renderer:
                            raise RuntimeError("Sample identity mismatch")
                        sample.update(round=repetition, fixture=fixture)
                        samples.append(sample)
                        shutil.copy2(result_path, folder / "result.json")
                        (output / "samples.json").write_text(json.dumps(samples, indent=2))
                        (output / "summary.json").write_text(json.dumps(summarize(samples), indent=2))
                        print(name, "warm CPU", round(sample["warmMountCPUMs"], 2),
                              "scroll CPU", round(sample["scrollCPUMs"], 2), flush=True)
    if source_identity() != fingerprint:
        raise RuntimeError("Sources changed during measurement; evidence cannot certify this checkout")


if __name__ == "__main__":
    main()
