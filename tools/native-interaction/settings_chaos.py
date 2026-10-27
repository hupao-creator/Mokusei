"""Mounted Settings controls, independent persistence oracle and seeded chaos."""
import argparse
import copy
from pathlib import Path
import json
import random
import time
import urllib.error
import urllib.request
import uuid

import client as api


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
        try:
            with self.http.open(request, timeout=30) as response:
                value = json.load(response)
        except urllib.error.HTTPError as error:
            raise AssertionError(f"Runtime rejected {channel}: HTTP {error.code}: {error.read().decode('utf-8', errors='replace')}") from error
        if not value["ok"]:
            raise AssertionError(f"Runtime rejected {channel}: {value.get('error')}")
        return value["value"]

    def state(self):
        return self.invoke("state:load", [])

    def update(self, edit):
        state = self.state()
        settings = copy.deepcopy(state["settings"])
        edit(settings)
        result = self.invoke("app:update-settings", [{"settings": settings, "expectedSettingsRevision": state["settingsRevision"]}])
        assert result.get("status") != "conflict", result
        return result


def controls(state):
    return {item["id"]: item for item in state["settings"]["controls"]}


class Driver:
    def __init__(self, client, trace, runtime=None, harnesses=None):
        self.client, self.trace, self.runtime = client, trace, runtime
        self.harnesses = set(harnesses) if harnesses else None
        self.coverage = {}

    def check(self, state, conflict=False):
        # Only the deliberately induced, identified settings conflict is allowed.
        if conflict and state["settings"]["conflicted"]:
            permitted = state["settings"]["error"]
            assert permitted and all(error == permitted for error in state["errors"]), state["errors"]
        else:
            api.validate_snapshot(state)
        ids = [item["id"] for item in state["settings"]["controls"]]
        assert len(ids) == len(set(ids)), "Duplicate mounted control identity"

    def settle(self, predicate=lambda state: True, conflict=False, timeout=15):
        state = self.client.settle(lambda state: all(not c["pending"] for c in state["settings"]["controls"]) and predicate(state), timeout)
        self.check(state, conflict)
        return state

    def action(self, action, expected=None, conflict=False, wait=True):
        before = self.client.snapshot()
        self.trace.write({"kind": "action", "action": action, "before": before, "expectedError": expected, "wait": wait, "conflict": conflict})
        try:
            response = self.client.request(action)
            self.trace.write({"kind": "response", "response": response})
            if expected:
                assert not response["ok"] and response["error"]["code"] == expected, response
            else:
                assert response["ok"], response
            state = self.settle(api.postcondition(action, before) if not expected else lambda _: True, conflict) if wait else response["snapshot"]
            self.trace.write({"kind": "settled", "snapshot": state})
            return state
        except BaseException as error:
            self.trace.write({"kind": "failure", "error": str(error)})
            raise

    def section(self, section):
        if self.client.snapshot()["page"] != "settings":
            self.action({"name": "settings.open"})
        return self.action({"name": "settings.select", "section": section})

    def control(self, id, operation, value=None, expected=None, conflict=False, wait=True):
        state = self.settle(lambda state: id in controls(state), conflict)
        item = controls(state)[id]
        self.coverage[id + ":" + operation] = self.coverage.get(id + ":" + operation, 0) + 1
        return self.action({"name": "settings.control", "controlId": id, "handle": item["handle"], "operation": operation, "value": value}, expected, conflict, wait)

    def saved(self):
        # Native catalog discovery has a 30-second bound (Pi), plus joined
        # process cleanup. Keep the shorter UI-settle deadline for other actions.
        return self.settle(lambda s: s["settings"]["status"] not in ("pending", "saving") and not s["settings"]["composing"] and not s["settings"]["conflicted"], timeout=45)

    def persisted(self, predicate, label):
        self.saved()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = self.runtime.state()
            if predicate(state["settings"]):
                self.trace.write({"kind": "persistence", "label": label, "revision": state["settingsRevision"], "settings": state["settings"]})
                return state
            time.sleep(.05)
        raise AssertionError(f"Persistence postcondition failed: {label}")


def smoke(driver):
    d = driver
    d.section("general")
    for field, values in (("appearance", ["1", "2", "0"]), ("locale", ["0", "1"])):
        for value in values:
            state = d.control("general." + field, "select", value)
            assert controls(state)["general." + field]["value"] == value
    stale = controls(d.client.snapshot())["general.appearance"]
    d.control("general.locale", "select", "1")
    d.action({"name": "settings.control", "controlId": stale["id"], "handle": stale["handle"], "operation": "select", "value": "0"}, expected="stale_control")
    d.control("general.appearance", "select", "not-an-option", expected="invalid_request")
    d.section("moku")
    d.action({"name": "settings.control", "controlId": stale["id"], "handle": stale["handle"], "operation": "select", "value": "0"}, expected="unavailable")
    # Initialization legitimately commits a new native execution profile. Admit
    # ordinary edit cases after that boundary; discovery races have a separate
    # Runtime replay and must still return a genuine stale-save conflict.
    d.control("moku.host.codex", "activate")
    d.settle(lambda s: "moku.codex.model" in controls(s) and len(controls(s)["moku.codex.model"]["options"]) > 1, timeout=60)
    d.persisted(lambda s: "codex" in s["moku"]["executionHarnesses"], "initial Codex execution profile")
    # All edits travel through the mounted native editor and its delegates.
    d.control("moku.routingEnabled", "set", True)
    d.control("moku.routingGuidance", "set", "  Chaos 中文 🚀\nsecond line  ")
    d.control("moku.routingGuidance", "blur")
    d.persisted(lambda s: s["moku"].get("routingGuidance") == "Chaos 中文 🚀\nsecond line", "trimmed Unicode routing guidance")
    d.control("moku.routingGuidance", "set", "Prefer small tasks\n多语言")
    d.control("moku.routingGuidance", "blur")
    d.persisted(lambda s: s["moku"]["routingGuidance"] == "Prefer small tasks\n多语言", "routing text")
    d.control("moku.routingEnabled", "set", False)
    d.persisted(lambda s: s["moku"]["routingGuidance"] is None, "routing disabled")
    # UTF-16 boundary, astral text and invalid-field close gate.
    d.control("moku.routingEnabled", "set", True)
    d.control("moku.routingGuidance", "set", "🚀" * 6000)
    d.control("moku.routingGuidance", "blur")
    baseline = d.persisted(lambda s: s["moku"]["routingGuidance"] == "🚀" * 6000, "12000 UTF-16 boundary")
    state = d.control("moku.routingGuidance", "set", "🚀" * 6001)
    assert state["settings"]["invalidField"] == "routingGuidance"
    d.action({"name": "settings.close"}, expected="blocked")
    assert d.runtime.state()["settingsRevision"] == baseline["settingsRevision"]
    d.control("moku.routingGuidance", "set", "valid again")
    d.control("moku.routingGuidance", "blur")
    d.persisted(lambda s: s["moku"]["routingGuidance"] == "valid again", "invalid draft recovered")
    # Native IME must block both autosave and close until committed.
    baseline = d.runtime.state()
    state = d.control("moku.routingGuidance", "compose", "正在输入")
    assert state["settings"]["composing"]
    time.sleep(.45)
    assert d.runtime.state()["settingsRevision"] == baseline["settingsRevision"]
    d.action({"name": "settings.close"}, expected="blocked")
    d.control("moku.routingGuidance", "commit", "输入完成 🚀")
    d.control("moku.routingGuidance", "blur")
    d.persisted(lambda s: s["moku"]["routingGuidance"] == "输入完成 🚀", "IME committed")
    # Real second-client CAS conflicts, using production public commands.
    for resolution in ("retry", "discard"):
        # Marked text alone is editor-owned until commit. Start a real dirty
        # draft, then freeze its debounce with IME before the peer saves.
        baseline = d.runtime.state()["settingsRevision"]
        d.control("moku.routingGuidance", "set", "local " + resolution, wait=False)
        d.control("moku.routingGuidance", "compose", "local " + resolution)
        assert d.runtime.state()["settingsRevision"] == baseline, "CAS draft saved before composition"
        remote_text = "peer " + resolution
        # Reordering the distinct dispatch targets changes an independent Moku
        # field without changing Harness profiles or plugin enablement.
        targets = list(reversed(d.runtime.state()["settings"]["moku"]["targetHarnessIds"]))
        assert len(targets) > 1, "CAS fixture needs multiple dispatch targets"
        patch = {"routingGuidance": remote_text, "targetHarnessIds": targets}
        d.trace.write({"kind": "peer", "moku": patch})
        peer = d.runtime.update(lambda s: s["moku"].update(patch))
        d.settle(lambda s: s["settings"]["catalogRevision"] >= peer["settingsRevision"])
        d.control("moku.routingGuidance", "commit", "local " + resolution, conflict=True)
        d.control("moku.routingGuidance", "blur", conflict=True)
        d.settle(lambda s: s["settings"]["conflicted"], conflict=True)
        d.control("moku." + resolution, "activate", conflict=True)
        expected = "local retry" if resolution == "retry" else remote_text
        d.persisted(lambda s: s["moku"].get("routingGuidance") == expected and s["moku"]["targetHarnessIds"] == targets, "CAS " + resolution)
    d.trace.write({"kind": "complete", "phase": "settings-smoke", "coverage": d.coverage})


def forms(driver):
    d = driver
    d.section("moku")
    state = d.settle(lambda s: "moku.host.codex" in controls(s), timeout=45)
    d.control("moku.host.codex", "activate")
    d.settle(lambda s: "moku.codex.model" in controls(s) and len(controls(s)["moku.codex.model"]["options"]) > 1, timeout=60)
    d.saved()
    for iteration in range(2):
        state = d.client.snapshot()
        field = controls(state)["moku.codex.model"]
        alternatives = [option["id"] for option in field["options"] if option["enabled"] and option["id"] != field["value"]]
        if not alternatives:
            raise AssertionError("Codex catalog needs two models to exercise dependencies")
        chosen = alternatives[iteration % len(alternatives)]
        d.control(field["id"], "select", chosen)
        for key in ("effort", "serviceTier"):
            state = d.settle(lambda s: "moku.codex." + key in controls(s))
            control = controls(state)["moku.codex." + key]
            options = [o["id"] for o in control["options"] if o["enabled"]]
            if control["enabled"] and options:
                d.control(control["id"], "select", options[-1])
        state = d.saved()
        expected = {key: controls(state)["moku.codex." + key]["value"] for key in ("model", "effort", "serviceTier")}
        d.persisted(lambda s: all(s["moku"]["executionHarnesses"]["codex"]["threadSettings"].get(k, "") == v for k, v in expected.items()), "Codex dependent profile")
    # At least one dispatch target remains. The mounted last-target button must reject.
    for id in [c["id"] for c in controls(d.client.snapshot()).values() if c["id"].startswith("moku.target.") and c["value"]]:
        state = d.client.snapshot()
        target = controls(state)[id]
        d.control(id, "activate", expected=None if target["enabled"] else "unavailable")
    d.persisted(lambda s: len(s["moku"]["targetHarnessIds"]) >= 1, "dispatch target floor")
    d.section("report.settings")
    d.control("report.settings.inherit", "set", False)
    d.saved()
    d.control("report.settings.inherit", "set", True)
    state = d.saved()
    assert not controls(state)["report.settings.harness"]["enabled"]
    d.control("report.settings.harness", "select", "codex", expected="unavailable")
    d.control("report.settings.inherit", "set", False)
    d.saved()
    d.persisted(lambda s: next(p["value"] for p in s["pluginSettings"] if p["id"] == "report.settings").get("mode") == "override", "application independent mode restored")
    d.trace.write({"kind": "complete", "phase": "settings-forms", "coverage": d.coverage})


def monkey(driver, seed, steps):
    rng = random.Random(seed)
    d = driver
    sections = d.client.snapshot()["settingsSections"]
    index = 0
    attempts = 0
    control_count = sum(d.coverage.values())
    while index < steps:
        attempts += 1
        if attempts > steps * 5:
            raise AssertionError("Too few actionable mounted Settings controls")
        state = d.settle()
        if index % 9 == 0 or state["page"] != "settings":
            available = [s for s in sections if s in state["settingsSections"]]
            state = d.section(rng.choice(available))
        choices = [c for c in controls(state).values() if c["enabled"] and c["operations"] and c["kind"] != "input"]
        if d.harnesses:
            choices = [c for c in choices if not c["id"].startswith("moku.host.")
                       or c["id"].removeprefix("moku.host.") in d.harnesses]
        if not choices:
            d.section("moku")
            continue
        item = rng.choice(sorted(choices, key=lambda c: c["id"]))
        kind, id = item["kind"], item["id"]
        if kind == "select":
            options = [o["id"] for o in item["options"] if o["enabled"]]
            if d.harnesses and id.endswith(".harness"):
                options = [option for option in options if option in d.harnesses]
            if not options:
                continue
            d.control(id, "select", rng.choice(options))
        elif kind == "toggle":
            d.control(id, "set", not item["value"])
        elif kind == "button":
            d.control(id, "activate")
        elif kind == "textarea":
            text = rng.choice(["", " ", f"seed={seed} step={index}\n中文 🚀", "x" * rng.randint(1, 300)])
            if rng.random() < .3:
                d.control(id, "compose", "输入中")
                d.control(id, "commit", text)
            else:
                d.control(id, "set", text)
            d.control(id, "blur")
        index += 1
        d.saved()
        if d.runtime:
            persisted = d.runtime.state()
            d.trace.write({"kind": "persistence", "revision": persisted["settingsRevision"], "settings": persisted["settings"]})
    d.trace.write({"kind": "complete", "phase": "settings-monkey", "seed": seed, "steps": steps, "controls": sum(d.coverage.values()) - control_count, "coverage": d.coverage})


def replay(driver, source):
    records = [json.loads(line) for line in Path(source).read_text().splitlines()]
    if not records or records[0].get("version") != 1:
        raise ValueError("Unsupported trace version")
    for record in records:
        if record["kind"] == "peer":
            peer = driver.runtime.update(lambda s: s["moku"].update(record["moku"]))
            driver.settle(lambda s: s["settings"]["catalogRevision"] >= peer["settingsRevision"])
        elif record["kind"] == "action":
            action = dict(record["action"])
            expected = record.get("expectedError")
            if action.get("name") == "settings.control" and expected not in ("stale_control", "unavailable"):
                state = driver.settle(lambda s: action["controlId"] in controls(s), record.get("conflict", False))
                action["handle"] = controls(state)[action["controlId"]]["handle"]
            driver.action(action, expected, record.get("conflict", False), record.get("wait", True))
        elif record["kind"] == "persistence":
            driver.persisted(lambda value: value == record["settings"], record.get("label", "replayed persistence"))
        elif record["kind"] == "failure":
            break
    driver.trace.write({"kind": "complete", "phase": "settings-replay"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--profile", type=Path, required=True, help="The isolated app profile, for independent Runtime checks")
    parser.add_argument("--trace", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    chaos = sub.add_parser("monkey")
    chaos.add_argument("--seed", type=int, default=1)
    chaos.add_argument("--steps", type=int, default=100)
    playback = sub.add_parser("replay")
    playback.add_argument("source", type=Path)
    args = parser.parse_args()
    if args.command == "monkey" and args.steps < 1:
        parser.error("steps must be positive")
    client = api.Client(args.socket)
    trace = api.Trace(args.trace, command="settings-" + args.command, seed=getattr(args, "seed", None))
    try:
        driver = Driver(client, trace, Runtime(args.profile))
        if args.command == "monkey":
            monkey(driver, args.seed, args.steps)
        else:
            replay(driver, args.source)
    finally:
        trace.close()
        client.close()


if __name__ == "__main__":
    main()
