"""Stage native replay inputs and linked resources outside protected user folders."""
from pathlib import Path
import fcntl
import json
import os
import platform
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time


class NativeReplay:
    def __init__(self, repo, name, bundle_id):
        self.temporary = tempfile.TemporaryDirectory(prefix="mokusei-native-replay-")
        self.root = Path(self.temporary.name).resolve()
        self.workspace = self.root / "workspace"
        self.workspace.mkdir()
        self.application = self.root / (name + ".app")
        self.executable = self.application / "Contents/MacOS" / name
        self.executable.parent.mkdir(parents=True)
        self.build = self.root / "build"
        self.build.mkdir()
        self.lock = None
        self.process = None
        self.termination_handler = None
        self.stopped_pids = set()
        self.manifest = {"root": str(self.root), "workspace": str(self.workspace)}
        self.isolation_source = repo / "tools/verification/NativeReplayIsolation.swift"
        package = repo / "app/macos"
        production = package / f".build/{platform.machine()}-apple-macosx/debug"
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
                "@executable_path/../Frameworks", "-module-cache-path", str(self.root / "ModuleCache")]
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
            raise RuntimeError(f"Native replay exceeded {timeout}s; stopping its owned app. "
                               "Inspect runtime-isolation.json; a permission/focus failure must not be blindly retried")
        finally:
            try:
                self.stop()
            finally:
                if output:
                    output.close()

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
        for name in ["launch.json", "runtime-isolation.json", "result.json", "stdout.log", "stderr.log", "cleanup.json"]:
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
