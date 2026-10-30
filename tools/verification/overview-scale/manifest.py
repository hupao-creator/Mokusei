"""Build the evidence manifest: hashes, diffs, environment and file inventory."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--labels", default="formal,diag")
    args = parser.parse_args()
    root, repo = args.root.resolve(), args.repo.resolve()
    tools = root / "tools"
    env = root / "env"
    tools.mkdir(exist_ok=True)
    env.mkdir(exist_ok=True)
    source = repo / "tools/verification/overview-scale"
    for name in ["main.swift", "ScaleSupport.swift", "run.py", "matrix.py", "analyze.py",
                 "metrics.py", "summarize_time_profile.py", "relocated.py", "README.md"]:
        shutil.copy2(source / name, tools / name)
    diff = command("git", "diff", cwd=repo).stdout
    (tools / "working-diff.patch").write_text(diff)
    (tools / "status.txt").write_text(command("git", "status", "--porcelain", cwd=repo).stdout)
    (tools / "head.txt").write_text(command("git", "rev-parse", "HEAD", cwd=repo).stdout)
    (env / "sw-vers.txt").write_text(command("sw_vers").stdout)
    (env / "swift-version.txt").write_text(command("xcrun", "swift", "--version").stdout)
    (env / "xcodebuild-version.txt").write_text(command("xcodebuild", "-version").stdout)
    (env / "sysctl.txt").write_text("".join(
        f"{key}: {command('sysctl', '-n', key).stdout.strip()}\n"
        for key in ["hw.model", "machdep.cpu.brand_string", "hw.memsize", "hw.logicalcpu", "hw.physicalcpu"]))
    (env / "pmset.txt").write_text(command("pmset", "-g", "batt").stdout)
    (env / "displays.txt").write_text(command("system_profiler", "SPDisplaysDataType").stdout)
    (env / "power-settings.txt").write_text(command("pmset", "-g").stdout)
    builds = {}
    for label in args.labels.split(","):
        build_path = repo / ".build/overview-scale" / label / "build.json"
        if build_path.exists():
            data = json.loads(build_path.read_text())
            (env / f"build-{label}.json").write_text(json.dumps(data, indent=2))
            executable = repo / ".build/overview-scale" / label / "OverviewScaleProbe"
            bundle_executable = repo / ".build/overview-scale" / label / "OverviewScaleProbe.app/Contents/MacOS/OverviewScaleProbe"
            builds[label] = {key: data.get(key) for key in
                ["head", "diffSHA256", "productionSourceSHA256", "binarySHA256", "bundleExecutableSHA256",
                 "diagnostics", "buildCommand", "linkCommand", "sources", "toolchain"]}
            if executable.exists():
                builds[label]["executableSHA256"] = sha256(executable)
            if bundle_executable.exists():
                builds[label]["bundleExecutableSHA256"] = sha256(bundle_executable)
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_file() and path.name != "manifest.json":
            files[str(path.relative_to(root))] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    manifest = {"head": (tools / "head.txt").read_text().strip(), "builds": builds,
                "toolFiles": {name: sha256(tools / name) for name in
                    ["main.swift", "ScaleSupport.swift", "run.py", "matrix.py", "analyze.py",
                     "metrics.py", "summarize_time_profile.py", "relocated.py", "README.md",
                     "working-diff.patch", "status.txt"]},
                "files": files}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print("manifest", len(files), "files")


if __name__ == "__main__":
    main()
