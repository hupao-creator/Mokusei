"""Public HTTP/socket adapter; no product imports or persistence access."""
import copy
import json
import socket
import time
import urllib.request
import uuid


class Runtime:
    def __init__(self, profile):
        self.profile = profile
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def invoke(self, channel, args):
        connection = json.loads((self.profile / "runtime/connection.json").read_text())
        request = urllib.request.Request(f"http://127.0.0.1:{connection['port']}/invoke/{channel}",
            json.dumps({"commandId": f"{time.time_ns() // 1_000_000}_{uuid.uuid4()}", "args": args}).encode(),
            {"Content-Type": "application/json", "Authorization": "Bearer " + connection["token"],
             "X-Mokusei-Protocol": str(connection["protocolVersion"]), "X-Mokusei-Epoch": connection["epoch"]})
        with self.http.open(request, timeout=30) as response:
            value = json.load(response)
        if value.get("ok") is not True:
            raise ValueError(f"Runtime rejected {channel}: {value.get('error')}")
        return value["value"]

    def state(self):
        return self.invoke("state:load", [])

    def configure(self):
        presentation = self.invoke("harness:settings-presentation", [{"scope": "global", "harnessId": "codex", "executionOwner": "moku"}])
        (self.profile.parent / "harness-presentation.json").write_text(json.dumps(presentation, indent=2))
        state = self.state()
        settings = copy.deepcopy(state["settings"])
        settings["moku"]["hostHarnessPreference"] = "codex"
        settings["moku"]["targetHarnessIds"] = ["codex"]
        catalog = presentation.get("value", {})
        if catalog.get("cli", {}).get("available") is not True:
            raise ValueError("native Codex CLI unavailable")
        defaults = [m for m in catalog.get("models", []) if m.get("isDefault") is True]
        if len(defaults) != 1 or not defaults[0].get("defaultReasoningEffort"):
            raise ValueError("native catalog lacks one explicit default model/effort")
        model = defaults[0]
        selection = {"useDefaultThreadSettings": False, "threadSettings": {
            "model": model["value"], "thinking": {"mode": "effort", "effort": model["defaultReasoningEffort"]},
            "serviceTier": "default", "permissionMode": "full-access"}}
        settings["moku"]["executionHarnesses"]["codex"] = selection
        settings["harnesses"]["codex"] = selection
        for entry in settings["pluginSettings"]:
            if entry["id"] in ("tag.settings", "report.settings"):
                entry["value"]["enabled"] = False
        for key in ("harness:claude", "harness:pi", "harness:opencode", "context:artificial-analysis"):
            settings.setdefault("pluginEnabled", {})[key] = False
        result = self.invoke("app:update-settings", [{"settings": settings, "expectedSettingsRevision": state["settingsRevision"]}])
        if result.get("status") == "conflict":
            raise ValueError("isolated fixture settings unexpectedly conflicted")
        return {"selection": selection, "cli": catalog["cli"]}


class UI:
    def __init__(self, path, pid):
        self.path, self.pid = path, pid

    def request(self, action=None):
        request = {"protocol": 1, "id": str(uuid.uuid4()), "op": "perform" if action else "snapshot"}
        if action:
            request["action"] = action
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(10)
            connection.connect(str(self.path))
            connection.sendall(json.dumps(request).encode() + b"\n")
            with connection.makefile("rb") as stream:
                reply = json.loads(stream.readline(8 * 1024 * 1024))
        if reply.get("id") != request["id"] or reply.get("protocol") != 1 or reply.get("pid") != self.pid:
            raise ValueError("UI response identity mismatch")
        if reply.get("ok") is not True:
            raise ValueError(f"UI rejected request: {reply.get('error')}")
        snapshot = reply["snapshot"]
        if snapshot is None: return None
        # Deliberately discard diagnostics of internal camera/layout/render state.
        return {key: snapshot[key] for key in ("page", "threads", "actions", "selectedThread", "settings",
                "onboarding", "errors", "runtimeAvailable", "transitioning", "reading", "mounted") if key in snapshot}


def wait_for(read, predicate, seconds=90):
    deadline = time.monotonic() + seconds
    value = None
    while time.monotonic() < deadline:
        value = read()
        if predicate(value):
            return value
        time.sleep(.25)
    raise TimeoutError(f"public outcome timed out: {str(value)[:1000]}")
