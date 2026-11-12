"""Owned production artifact, isolated public profile and deterministic provider."""
import hashlib
import json
import os
from pathlib import Path
from types import SimpleNamespace
import plistlib
import re
import signal
import subprocess
import time

from adapter import Runtime, UI, wait_for
from provider import Provider, title, body


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def sha256(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def native(helper, *arguments):
    result = subprocess.run([str(helper), *map(str, arguments)], capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(f"native {arguments[0]} failed: {result.stdout} {result.stderr}")
    return json.loads(result.stdout)


class Application:
    def __init__(self, bundle, directory, count, helper):
        self.bundle, self.root, self.count, self.helper = bundle.resolve(), directory, count, helper
        self.profile = directory / "profile"
        self.socket = directory / "ui.sock"
        self.app = None
        self.provider = None
        self.owned = {}
        self.env = {key: value for key, value in os.environ.items()
                    if key in ("PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL")}
        self.log = None

    def start(self):
        self.root.mkdir(mode=0o700, parents=True, exist_ok=False)
        info = plistlib.loads((self.bundle / "Contents/Info.plist").read_bytes())
        provenance = json.loads((self.bundle / "Contents/Resources/build-provenance.json").read_text())
        if info.get("CFBundleIdentifier") != "com.mokusei.desktop" or provenance.get("channel") != "production" or provenance.get("configuration") != "release":
            raise ValueError("benchmark requires a production Release artifact")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(self.bundle)], check=True, capture_output=True)
        signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(self.bundle)], capture_output=True, text=True, check=True)
        team = re.search(r'^TeamIdentifier=(.+)$', signature.stderr, re.MULTILINE)
        if not team or team[1] == 'not set' or 'runtime)' not in signature.stderr:
            raise ValueError('production artifact requires a team signature and hardened runtime')
        runtime_signature = subprocess.run(['codesign','-dv','--verbose=4',str(self.bundle/'Contents/MacOS/mokusei-runtime')],
                                           capture_output=True,text=True,check=True).stderr
        if f'TeamIdentifier={team[1]}\n' not in runtime_signature or 'runtime)' not in runtime_signature:
            raise ValueError('bundled Runtime must have the same hardened team signature')
        self.executable = self.bundle / "Contents/MacOS" / info["CFBundleExecutable"]
        save(self.root / "artifact.json", {"app": str(self.bundle), "provenance": provenance,
             "executableSHA256": sha256(self.executable), "signature": signature.stderr, "runtimeSignature":runtime_signature,
             "files": {str(p.relative_to(self.bundle)): sha256(p) for p in sorted((self.bundle / "Contents/MacOS").iterdir()) if p.is_file()}})
        self.provider = Provider(self.root, self.count)
        for name in ("home", "native", "tmp", "config"):
            (self.root / name).mkdir(mode=0o700)
        config = '''model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
web_search = "disabled"
[model_providers.fixture]
name = "Overview benchmark fixture"
base_url = BASE_URL
wire_api = "responses"
env_key = "FIXTURE_KEY"
requires_openai_auth = false
supports_websockets = false
[features]
apps = false
plugins = false
remote_plugin = false
hooks = false
goals = false
memories = false
shell_snapshot = false
multi_agent = false
image_generation = false
responses_websockets = false
responses_websockets_v2 = false
[otel]
exporter = "none"
trace_exporter = "none"
'''.replace("BASE_URL", json.dumps(self.provider.url + "/v1"))
        (self.root / "native/config.toml").write_text(config)
        for key in list(self.env):
            if key.endswith("API_KEY") or key.startswith("MOKUSEI_"):
                self.env.pop(key)
        # Per-child environment isolation is intentional. The caller's shell,
        # daily native configuration and production embedding mode are untouched.
        self.env.update({"HOME": str(self.root / "home"), "CODEX_HOME": str(self.root / "native"),
                         "CODEX_SQLITE_HOME": str(self.root / "native"), "TMPDIR": str(self.root / "tmp"),
                         "XDG_CONFIG_HOME": str(self.root / "config"), "FIXTURE_KEY": "fixture-only",
                         "HTTP_PROXY": self.provider.url, "HTTPS_PROXY": self.provider.url,
                         "ALL_PROXY": self.provider.url, "NO_PROXY": "127.0.0.1,localhost,::1"})
        self.launch()
        self.runtime = Runtime(self.profile)
        self.ui = UI(self.socket, self.app.pid)
        wait_for(self.ui.request, lambda s: s and s.get("runtimeAvailable"), 90)
        connection = json.loads((self.profile / "runtime/connection.json").read_text())
        runtime_process = native(self.helper, "process", connection["pid"])
        if (Path(runtime_process["path"]).resolve() != (self.bundle / "Contents/MacOS/mokusei-runtime").resolve()
                or Path(connection["dataDir"]).resolve() != self.profile.resolve()):
            raise ValueError("bundled Runtime/profile identity mismatch")
        self.owned[connection["pid"]] = runtime_process
        state = self.runtime.state()
        save(self.root / "initial-state.json", state)
        selection = self.runtime.configure()
        save(self.root / "selection.json", selection)
        cli = Path(selection["cli"]["executable"])
        actual_version = subprocess.check_output([str(cli), "--version"], env=self.env, text=True).strip()
        if actual_version != selection["cli"]["version"]:
            raise ValueError("native CLI version differs from public discovery")
        save(self.root / "native-cli.json", {**selection["cli"], "sha256": sha256(cli), "verifiedVersion": actual_version})
        self.provider.model = selection["selection"]["threadSettings"]["model"]
        self.provider.effort = selection["selection"]["threadSettings"]["thinking"]["effort"]
        self.runtime.invoke("moku:submit", [{"input": {"parts": [{"kind": "text", "text": f"BENCHMARK CREATE {self.count} completed tasks."}]}}])
        def completed(state):
            if self.provider.failures:
                raise ValueError("fixture provider failed: " + str(self.provider.failures))
            threads = {t["id"]: t for t in state.get("threads", []) if not t.get("moku") and not t.get("archived")}
            if len(self.provider.receipts) != self.count or len(threads) != self.count:
                return False
            for n in range(1, self.count + 1):
                receipt = self.provider.receipts[f"bench_create_{n:02d}"]
                thread = threads.get(receipt["threadId"], {})
                execution = thread.get("observation", {}).get("latestExecution") or {}
                if (thread.get("title") != title(n) or execution.get("status") != "completed"
                        or execution.get("summary") != body(n)):
                    return False
            return True
        state = wait_for(self.runtime.state, completed, 180)
        self.threads = {n: self.provider.receipts[f"bench_create_{n:02d}"]["threadId"] for n in range(1, self.count + 1)}
        save(self.root / "prepared-state.json", state)
        save(self.root / "prepared-ui.json", self.ui.request())
        if self.ui.request().get("page") == "onboarding":
            raise ValueError("benchmark scenario did not bypass onboarding")
        return self

    def launch(self):
        config = {"app": str(self.bundle), "arguments": ["--data-dir", str(self.profile),
                  "--automation-socket", str(self.socket), "--benchmark-scenario", "overview"], "environment": self.env}
        started = time.monotonic_ns()
        launch = subprocess.run([str(self.helper), "launch", "-"], input=json.dumps(config), text=True,
                                capture_output=True, timeout=45, check=True)
        value = json.loads(launch.stdout)
        self.app = SimpleNamespace(pid=value["process"]["pid"])
        self.owned[self.app.pid] = value["process"]
        save(self.root/"launch.json", {"requestedNS": started, "returnedNS": time.monotonic_ns(), **value})
        deadline = time.monotonic() + 60
        while not self.socket.exists():
            if not self.alive(self.app.pid):
                raise RuntimeError("application exited before public socket became ready")
            if time.monotonic() >= deadline:
                raise TimeoutError("application socket startup timeout")
            time.sleep(.1)

    def alive(self, pid):
        try:
            actual = native(self.helper, "process", pid)
        except RuntimeError:
            return False
        if actual["identity"] != self.owned[pid]["identity"]:
            raise RuntimeError("PID identity changed; refusing to signal")
        return True

    def live_roots(self):
        roots=[]
        for pid in list(self.owned):
            try:
                actual=native(self.helper,"process",pid)
            except RuntimeError:
                continue
            if actual["identity"]==self.owned[pid]["identity"]:roots.append(pid)
        return roots

    def discover_owned(self):
        roots={pid:self.owned[pid]['identity'] for pid in self.live_roots()}
        if not roots:return []
        rows=native(self.helper,'tree',*roots)['processes']
        # A PID-only tree query must not replace our birth identities. Fence
        # roots again after enumeration before adopting any new descendants.
        admitted={}
        for pid,identity in roots.items():
            try:current=native(self.helper,'process',pid)
            except RuntimeError:continue
            if current['identity']!=identity:
                raise RuntimeError('process root changed during descendant discovery')
            admitted[pid]=identity
        owned={p['pid']:p for p in rows if admitted.get(p['pid'])==p['identity']}
        changed=True
        while changed:
            changed=False
            for row in rows:
                if row['pid'] not in roots and row['pid'] not in owned and row['ppid'] in owned:
                    owned[row['pid']]=row;changed=True
        self.owned.update(owned)
        return list(owned.values())

    def stop(self):
        receipt = {"owned": self.owned.copy(), "actions": [], "errors": []}
        try:self.discover_owned()
        except Exception as error:receipt['errors'].append(str(error))
        # Ask the app to shut down first. Surviving owned descendants are then
        # joined separately; every signal is fenced by PID plus OS birth time.
        for pid in list(self.owned):
            try:
                if not self.alive(pid): continue
                if self.app and pid==self.app.pid:
                    native(self.helper,"quit",pid,self.owned[pid]["identity"])
                    receipt["actions"].append({"pid":pid,"action":"application quit"})
                elif Path(self.owned[pid]["path"]).name=="mokusei-runtime":
                    stopped=subprocess.run([self.owned[pid]["path"],"stop","--data-dir",str(self.profile)],
                                           env=self.env,capture_output=True,text=True,timeout=20)
                    receipt["actions"].append({"pid":pid,"action":"public Runtime stop","exitStatus":stopped.returncode})
                else:
                    os.kill(pid, signal.SIGTERM)
                    receipt["actions"].append({"pid": pid, "signal": "TERM"})
                deadline = time.monotonic() + 10
                while self.alive(pid) and time.monotonic() < deadline: time.sleep(.1)
                if self.alive(pid):
                    os.kill(pid, signal.SIGKILL)
                    receipt["actions"].append({"pid": pid, "signal": "KILL"})
                    deadline = time.monotonic() + 3
                    while self.alive(pid) and time.monotonic() < deadline: time.sleep(.1)
                    if self.alive(pid): raise RuntimeError(f"owned process {pid} did not exit")
            except Exception as error:
                receipt["errors"].append(str(error))
        receipt["owned"] = self.owned.copy()
        return receipt

    def close(self):
        try: receipt = self.stop()
        except Exception as error: receipt = {"owned": self.owned, "errors": [str(error)]}
        if self.provider: self.provider.close()
        if self.root.exists(): save(self.root / "cleanup.json", receipt)
        return receipt
