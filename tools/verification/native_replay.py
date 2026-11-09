"""Stage native replay inputs and linked resources outside protected user folders."""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time


def native_module_cache(repo):
    """Reuse compiler imports without sharing replay binaries or runtime state."""
    runner_temp = os.environ.get("RUNNER_TEMP")
    cache = (Path(runner_temp) / "mokusei-native-module-cache" if runner_temp
             else repo / ".build/native-replay/modules")
    cache.mkdir(parents=True, exist_ok=True)
    return cache.resolve()


class NativeReplay:
    def __init__(self, repo, name, bundle_id, configuration="debug"):
        if configuration not in {"debug", "release"}:
            raise ValueError("Native replay configuration must be debug or release")
        self.temporary = tempfile.TemporaryDirectory(prefix="mokusei-native-replay-")
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.application = self.root / (name + ".app")
        self.executable = self.application / "Contents/MacOS" / name
        self.executable.parent.mkdir(parents=True)
        self.build = self.root / "build"
        self.build.mkdir()
        self.module_cache = native_module_cache(repo)
        self.lock = None
        self.process = None
        self.termination_handler = None
        self.stopped_pids = set()
        self.manifest = {"root": str(self.root), "workspace": str(self.workspace),
                         "moduleCache": str(self.module_cache)}
        self.isolation_source = repo / "tools/verification/NativeReplayIsolation.swift"
        package = repo / "app/macos"
        production = package / f".build/{platform.machine()}-apple-macosx/{configuration}"
        self.production = production
        self.configuration = configuration
        link_list = production / "Mokusei.product/Objects.LinkFileList"
        if not link_list.is_file():
            raise RuntimeError("Build current production modules first: make check")
        objects = [Path(line.strip().strip('"')) for line in link_list.read_text().splitlines()
                   if "/Mokusei.build/" not in line]
        if not objects or any(not item.is_file() for item in objects):
            raise RuntimeError("Production link list contains missing objects; run make check")
        self.objects = []
        for index, source in enumerate(objects):
            target = self.build / f"object-{index}.o"
            shutil.copy2(source, target)
            self.objects.append(str(target))
        shutil.copytree(production / "Modules", self.build / "Modules")
        frameworks = self.application / "Contents/Frameworks"
        frameworks.mkdir()
        subprocess.run(["/usr/bin/ditto", str(production / "LiveKitWebRTC.framework"),
                        str(frameworks / "LiveKitWebRTC.framework")], check=True)
        resources = self.application / "Contents/Resources"
        resources.mkdir()
        bundles = []
        for source in production.glob("*.bundle"):
            # Production NativeResources resolves packaged resources here;
            # copy them completely so it never needs a development checkout.
            target = resources / source.name
            shutil.copytree(source, target)
            bundles.append(str(target))
        self.manifest["resourceBundles"] = bundles
        self.includes = []
        for index, relative in enumerate([
            "swift-cmark/src/include", "swift-cmark/extensions/include",
            "swift-markdown/Sources/CAtomic/include", "swift-system/Sources/CSystem/include",
        ]):
            target = self.build / f"include-{index}"
            shutil.copytree(package / ".build/checkouts" / relative, target)
            self.includes.append(target)
        with (self.application / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleName": name,
                          "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
                          "NSHighResolutionCapable": True, "LSMinimumSystemVersion": "26.0"}, output)

    def reuse_test_objects(self, repo, sources_by_target):
        """Stage only the selected source objects from this job's verified build."""
        package = repo / "app/macos"
        manifest_path = package / ".build/ci-manifest.json"
        manifest_bytes = manifest_path.read_bytes()
        verified = Path(os.environ["MOKUSEI_CI_EVIDENCE"]) / "build-manifest.json"
        if verified.read_bytes() != manifest_bytes:
            raise RuntimeError("Swift replay build manifest differs from the verified CI evidence")
        build_manifest = json.loads(manifest_bytes)
        identity = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                    "workspace": str(repo.resolve()), "architecture": platform.machine(),
                    "configuration": self.configuration, "run": os.environ.get("GITHUB_RUN_ID"),
                    "attempt": os.environ.get("GITHUB_RUN_ATTEMPT")}
        if not identity["run"] or not identity["attempt"] or any(
                build_manifest.get(key) != value for key, value in identity.items()):
            raise RuntimeError("Swift replay objects require the current checkout and CI attempt's build")
        roots = {"MokuseiSettingsIntegrationTests": package / "Tests/Integration/Host",
                 "MokuseiGitIntegrationTests": package / "Tests/Integration/Threads",
                 "MokuseiTestSupport": package / "Tests/Support"}
        receipt = {"buildManifestPath": str(manifest_path),
                   "buildManifestSHA256": hashlib.sha256(manifest_bytes).hexdigest(),
                   "revision": build_manifest["revision"], "toolchain": build_manifest["toolchain"],
                   "objects": []}
        self.manifest["swiftPMTestObjects"] = receipt
        staged, seen = [], set()
        try:
            for module, sources in sources_by_target.items():
                if module not in roots or not sources:
                    raise RuntimeError("Unknown or empty Swift replay object selection: " + module)
                target_build = (self.production / (module + ".build")).resolve()
                output_map = target_build / "output-file-map.json"
                map_bytes = output_map.read_bytes()
                outputs = json.loads(map_bytes)
                if "object" in outputs.get("", {}):
                    raise RuntimeError("Swift replay requires per-source objects, not a whole-module object")
                for source in sources:
                    source = source.resolve()
                    if source.parent != roots[module].resolve() or source.suffix != ".swift":
                        raise RuntimeError(f"Unexpected Swift replay source for {module}: {source}")
                    entry = outputs.get(str(source), {})
                    object_name = entry.get("object")
                    if not isinstance(object_name, str) or not object_name:
                        raise RuntimeError(f"No compiled Swift replay object for exact source: {source}")
                    original = Path(object_name)
                    if (not original.is_absolute() or original.resolve().parent != target_build
                            or original.suffix != ".o" or not original.is_file() or original in seen):
                        raise RuntimeError(f"Missing, duplicate or unexpected Swift replay object: {original}")
                    seen.add(original)
                    target = self.build / f"test-object-{len(staged)}.o"
                    shutil.copy2(original, target)
                    staged.append(str(target))
                    receipt["objects"].append({"module": module, "source": str(source.relative_to(repo.resolve())),
                        "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                        "objectPath": str(original), "objectSHA256": hashlib.sha256(target.read_bytes()).hexdigest(),
                        "stagedObject": str(target), "outputFileMap": str(output_map),
                        "outputFileMapSHA256": hashlib.sha256(map_bytes).hexdigest()})
            self.objects.extend(staged)
        finally:
            (self.root / "launch.json").write_text(json.dumps(self.manifest, indent=2) + "\n")
        print(f"NATIVE_REPLAY_SWIFTPM_OBJECTS count={len(staged)} targets={list(sources_by_target)}", flush=True)

    def compile(self, sources, extra_args=()):
        staged = []
        for index, source in enumerate([*sources, self.isolation_source]):
            target = self.root / f"source-{index}" / source.name
            target.parent.mkdir()
            shutil.copy2(source, target)
            staged.append(str(target))
        args = ["/usr/bin/xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
                "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx26.0",
                "-I", str(self.build / "Modules"), "-F", str(self.application / "Contents/Frameworks"),
                "-framework", "LiveKitWebRTC", "-Xlinker", "-rpath", "-Xlinker",
                "@executable_path/../Frameworks", "-module-cache-path", str(self.module_cache)]
        for include in self.includes:
            args += ["-I", str(include), "-Xcc", "-fmodule-map-file=" + str(include / "module.modulemap")]
        subprocess.run([*args, *extra_args, *staged, *self.objects, "-o", str(self.executable)],
                       cwd=self.workspace, check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(self.application)], check=True)
        libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(self.executable)], text=True)
        for line in libraries.splitlines()[1:]:
            path = line.strip().split(" (", 1)[0]
            if path.startswith("/") and not path.startswith(("/System/", "/usr/lib/", "/Applications/Xcode.app/")):
                raise RuntimeError("Replay links a non-system absolute library: " + path)

    def copy_input(self, source, name):
        target = self.workspace / name
        shutil.copy2(source, target)
        return target

    def acquire(self):
        path = Path(tempfile.gettempdir()) / f"mokusei-note-replay-{os.getuid()}.lock"
        self.lock = path.open("a")
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another Note replay owns the graphical session; do not retry concurrently")
        self.termination_handler = signal.getsignal(signal.SIGTERM)
        def terminate(signum, frame):
            raise SystemExit("Native replay launcher terminated; cleaning up its owned app")
        signal.signal(signal.SIGTERM, terminate)

    def run(self, arguments, timeout=180, launch_services=True, env=None, launch_environment=None):
        for name in ("timeout-sample.txt", "timeout-sample.log"):
            (self.root / name).unlink(missing_ok=True)
        self.manifest["arguments"] = list(map(str, arguments))
        (self.root / "launch.json").write_text(json.dumps(self.manifest, indent=2))
        # LaunchServices grants foreground activation, but does not inherit the
        # launcher's environment. Forward only the explicitly named replay
        # flags, never copy the inherited host environment into arguments.
        overrides = [part for key, value in (launch_environment or {}).items()
                     for part in ("--env", f"{key}={value}")]
        command = (["/usr/bin/open", "-W", "-n", "--stdout", str(self.root / "stdout.log"),
                    "--stderr", str(self.root / "stderr.log"), *overrides, str(self.application), "--args"]
                   if launch_services else [str(self.executable)])
        output = (self.root / "stdout.log").open("w") if not launch_services else None
        try:
            self.process = subprocess.Popen([*command, *map(str, arguments)], cwd=self.workspace, env=env,
                                            stdout=output, stderr=subprocess.STDOUT if output else None)
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.sample_timeout()
            raise RuntimeError(f"Native replay exceeded {timeout}s; stopping its owned app. "
                               "Inspect runtime-isolation.json and timeout-sample.log; "
                               "a permission/focus failure must not be blindly retried")
        finally:
            try:
                self.stop()
            finally:
                if output:
                    output.close()

    def sample_timeout(self):
        details = ["Timeout diagnostic: 2-second sample, 8-second sampler limit."]
        try:
            receipt = json.loads((self.root / "runtime-isolation.json").read_text())
            pid = receipt.get("pid")
            if not isinstance(pid, int) or pid <= 1:
                raise ValueError("No valid owned app PID in startup receipt")
            identity = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                                      capture_output=True, text=True, timeout=2)
            if identity.returncode != 0 or identity.stdout.strip() != str(self.executable):
                raise ValueError("Startup PID no longer belongs to this staged executable; sampling skipped")
            details.append(f"Verified PID {pid}: {self.executable}")
            result = subprocess.run(["/usr/bin/sample", str(pid), "2", "1", "-file",
                                     str(self.root / "timeout-sample.txt")],
                                    capture_output=True, text=True, timeout=8)
            details.append(f"Sampler exit code: {result.returncode}")
            details.extend([result.stdout[-8192:], result.stderr[-8192:]])
        except Exception as error:
            # Diagnostics must not replace the original timeout or prevent owned-app cleanup.
            details.append(f"Sample unavailable: {type(error).__name__}: {error}")
        try:
            (self.root / "timeout-sample.log").write_text("\n".join(details) + "\n")
        except OSError as error:
            print(f"Could not retain timeout sampling diagnostic: {error}", flush=True)

    def stop(self):
        # open -W is not the app PID. A startup receipt lets us retire the app
        # even while its event loop is blocked by a Cocoa/TCC modal dialog.
        receipt = self.root / "runtime-isolation.json"
        candidates = set()
        if receipt.is_file():
            pid = json.loads(receipt.read_text()).get("pid")
            if isinstance(pid, int) and pid > 1:
                candidates.add(pid)
        else:
            # A very short timeout may precede main/its receipt. Match only the
            # unique staged executable, never an app name or bundle identifier.
            rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,comm="], text=True)
            for row in rows.splitlines():
                fields = row.strip().split(None, 1)
                if len(fields) == 2 and fields[1] == str(self.executable):
                    candidates.add(int(fields[0]))
        for pid in candidates:
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
            if result.returncode != 0 or result.stdout.strip() != str(self.executable):
                continue
            try:
                os.kill(pid, signal.SIGTERM)
                self.stopped_pids.add(pid)
            except ProcessLookupError:
                pass
            if self.process and pid == self.process.pid:
                self.process.wait(timeout=3)  # Reap direct launches before probing liveness.
                continue
            for _ in range(30):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError(f"Replay PID {pid} did not exit after SIGTERM; stop before launching another replay")
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=5)
        (self.root / "cleanup.json").write_text(json.dumps({"stoppedPIDs": sorted(self.stopped_pids),
            "bootstrapRecorded": receipt.is_file()}, indent=2))

    def export(self, evidence):
        evidence.mkdir(parents=True, exist_ok=True)
        for name in ["launch.json", "runtime-isolation.json", "result.json", "stdout.log", "stderr.log", "cleanup.json",
                     "timeout-sample.txt", "timeout-sample.log"]:
            source = self.root / name
            if source.is_file():
                shutil.copy2(source, evidence / name)
        output = self.workspace / "evidence"
        if output.is_dir():
            shutil.copytree(output, evidence, dirs_exist_ok=True)

    def close(self):
        self.stop()
        if self.termination_handler is not None:
            signal.signal(signal.SIGTERM, self.termination_handler)
        if self.lock:
            self.lock.close()
        self.temporary.cleanup()
