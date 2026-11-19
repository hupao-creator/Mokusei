"""Own foreground production processes; never attach to a daily profile."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time

from adapter import Runtime
from peer import Peer
from report import save, sha256


class Blocked(Exception):
    pass


class ObservedRuntime(Runtime):
    def __init__(self, profile, output):
        super().__init__(profile)
        self.output = output

    def invoke(self, channel, args):
        record = {"atNS": time.monotonic_ns(), "channel": channel, "args": args}
        try:
            result = super().invoke(channel, args)
            if channel == "state:load":
                record["result"] = {"settingsRevision": result["settingsRevision"],
                    "threads": [{k: t[k] for k in ("id", "title", "observation", "cancellationId") if k in t}
                                for t in result["threads"]]}
            else:
                record["result"] = result
            return result
        except Exception as error:
            record["error"] = f"{type(error).__name__}: {error}"
            raise
        finally:
            with (self.output / "api.jsonl").open("a") as stream:
                stream.write(json.dumps(record) + "\n")


def processes():
    result = subprocess.run(["ps", "-axo", "pid=,ppid=,stat=,lstart=,command="],
                            capture_output=True, text=True, check=True, timeout=5)
    rows = {}
    for line in result.stdout.splitlines():
        fields = line.split(None, 8)
        if len(fields) == 9 and not fields[2].startswith("Z"):
            rows[int(fields[0])] = {"parent": int(fields[1]), "identity": " ".join(fields[3:])}
    return rows


def descendants(rows, roots):
    owned = set(roots)
    while True:
        expanded = owned | {pid for pid, row in rows.items() if row["parent"] in owned}
        if expanded == owned:
            return {pid: rows[pid] for pid in owned if pid in rows}
        owned = expanded


class Session:
    def __init__(self, binary, output, nonce, event):
        self.binary, self.output, self.event = binary, output, event
        self.root = Path(tempfile.mkdtemp(prefix="me2e-", dir="/private/tmp" if Path("/private/tmp").exists() else "/tmp"))
        self.profile = self.root / "profile"
        self.runtime = ObservedRuntime(self.profile, output)
        self.process = None
        self.app = None
        self.logs = []
        self.children = []
        self.cleanup_errors = []
        self.peer = None
        self.nonce = nonce
        self.roots = {}
        self.owned = {}
        self.process_lock = threading.Lock()
        self.monitor_stop = threading.Event()
        self.monitor = None

    def prepare(self):
        self.peer = Peer(self.root, self.nonce)
        for name in ("home", "native", "tmp", "config"):
            (self.root / name).mkdir(mode=0o700)
        config = '''model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
cli_auth_credentials_store = "file"
check_for_update_on_startup = false
web_search = "disabled"
[model_providers.fixture]
name = "E2E deterministic external input"
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
'''.replace("BASE_URL", json.dumps(self.peer.url + "/v1"))
        (self.root / "native/config.toml").write_text(config)
        # These are per-child homes, not modifications to shell variables or the
        # user's native configuration. No account/API credentials are inherited.
        self.env = {key: value for key, value in os.environ.items()
                    if key in ("PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL")}
        self.env.update({"HOME": str(self.root / "home"), "CODEX_HOME": str(self.root / "native"),
                         "CODEX_SQLITE_HOME": str(self.root / "native"), "TMPDIR": str(self.root / "tmp"),
                         "XDG_CONFIG_HOME": str(self.root / "config"), "FIXTURE_KEY": "fixture-only",
                         "HTTP_PROXY": self.peer.url, "HTTPS_PROXY": self.peer.url,
                         "ALL_PROXY": self.peer.url, "NO_PROXY": "127.0.0.1,localhost,::1"})
        self.monitor = threading.Thread(target=self.observe_processes, daemon=True)
        self.monitor.start()

    def observe_processes(self):
        while not self.monitor_stop.wait(.25):
            try:
                rows = processes()
                with self.process_lock:
                    # Retain identities before a crashed parent can reparent its
                    # native engines. Sampling is evidence, not OS containment.
                    roots = {pid for pid, row in self.roots.items()
                        if rows.get(pid, {}).get("identity") == row["identity"]} | {pid for pid, row in self.owned.items()
                        if rows.get(pid, {}).get("identity") == row["identity"]}
                    self.owned.update(descendants(rows, roots))
            except Exception as error:
                self.cleanup_errors.append(f"process inventory unavailable: {error}")
                return

    def spawn(self, argv, name):
        log = (self.root / (name + ".txt")).open("ab")
        self.logs.append(log)
        # Register ownership before a pending run deadline can unwind startup.
        pending = []
        previous = {sig: signal.getsignal(sig) for sig in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT)}
        for sig in previous:
            signal.signal(sig, lambda number, frame: pending.append(number))
        try:
            process = subprocess.Popen(list(map(str, argv)), cwd=self.root, env=self.env,
                                       stdout=log, stderr=log, start_new_session=True)
            self.children.append((process, name))
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        if pending:
            previous[pending[0]](pending[0], None)
        with self.process_lock:
            row = processes().get(process.pid)
            if row:
                self.roots[process.pid] = row
        self.event("process-start", name=name, pid=process.pid)
        return process

    def start(self):
        if not self.binary.is_file() or not os.access(self.binary, os.X_OK):
            raise Blocked("build the production Runtime executable first")
        self.process = self.spawn([self.binary, "serve", "--data-dir", self.profile], "runtime")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(f"Runtime exited during startup: {self.process.returncode}; private diagnostics at {self.root}")
            connection = self.profile / "runtime/connection.json"
            if connection.exists():
                value = json.loads(connection.read_text())
                if value["pid"] == self.process.pid and Path(value["dataDir"]).resolve() == self.profile.resolve():
                    self.runtime.state()
                    self.event("runtime-ready", pid=value["pid"], epoch=value["epoch"])
                    return value["epoch"]
            time.sleep(.1)
        raise TimeoutError("Runtime startup deadline")

    def configure(self):
        try:
            selection = self.runtime.configure()
        except ValueError as error:
            raise Blocked(f"native catalog/configuration prerequisite: {error}") from error
        cli = Path(selection["cli"]["executable"])
        actual = subprocess.run([str(cli), "--version"], env=self.env, capture_output=True,
                                text=True, check=True, timeout=10).stdout.strip()
        if actual != selection["cli"]["version"]:
            raise RuntimeError("native discovery and executed CLI versions differ")
        save(self.output / "native-cli.json", {**selection["cli"], "sha256": sha256(cli), "verifiedVersion": actual})
        self.peer.model = selection["selection"]["threadSettings"]["model"]
        self.peer.effort = selection["selection"]["threadSettings"]["thinking"]["effort"]
        save(self.output / "selection.json", selection)

    def stop(self, process, name):
        if process is None:
            return
        rows = processes()
        with self.process_lock:
            self.owned.update(descendants(rows, [process.pid]) if process.poll() is None else {})
        owned = descendants(rows, [process.pid]) if process.poll() is None else {}
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self.cleanup_errors.append(f"{name} graceful stop timed out")
        if process.poll() not in (0, -signal.SIGTERM):
            self.cleanup_errors.append(f"{name} exited {process.poll()}")
        # Native engines own separate process groups. A group-only kill misses
        # them, so retain OS identities before revocation and fence every signal.
        forced = set()
        for sig in (signal.SIGTERM, signal.SIGKILL):
            now = processes()
            remaining = [pid for pid, row in owned.items() if now.get(pid, {}).get("identity") == row["identity"]]
            forced.update(remaining)
            for pid in remaining:
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass
            if remaining:
                time.sleep(.2)
        process.wait(timeout=5)
        if forced:
            self.cleanup_errors.append(f"{name} required forced descendant cleanup: {sorted(forced)}")
        self.event("process-stop", name=name, pid=process.pid, returncode=process.returncode)

    def close(self):
        for process, name in reversed(self.children):
            try:
                self.stop(process, name)
            except Exception as error:
                self.cleanup_errors.append(f"{name}: {error}")
        self.monitor_stop.set()
        if self.monitor:
            self.monitor.join(timeout=6)
            if self.monitor.is_alive():
                self.cleanup_errors.append("process inventory did not stop")
        try:
            rows = processes() if self.children else {}
            with self.process_lock:
                survivors = {pid: row for pid, row in self.owned.items()
                             if rows.get(pid, {}).get("identity") == row["identity"]}
            if survivors:
                self.cleanup_errors.append(f"owned processes survived graceful teardown: {list(survivors)}")
                for pid, row in survivors.items():
                    if processes().get(pid, {}).get("identity") == row["identity"]:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
            save(self.output / "processes.json", {"observed": self.owned, "forcedSurvivors": survivors,
                 "boundary": "OS identity sampling; not containment of unobserved children"})
        except Exception as error:
            self.cleanup_errors.append(f"final process inventory/cleanup: {error}")
        if self.peer:
            self.peer.close()
            if self.peer.failures:
                self.cleanup_errors.append("external peer failed: " + str(self.peer.failures))
            save(self.output / "peer.json", self.peer.evidence())
        for log in self.logs:
            log.close()
        return {"ok": not self.cleanup_errors, "errors": self.cleanup_errors,
                "privateDirectory": str(self.root), "retention": "local only; never uploaded"}
