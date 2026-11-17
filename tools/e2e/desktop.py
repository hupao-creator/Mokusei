"""Interact with real mounted controls; semantic observations are not pixels."""
import json
import time

from client import Client
from report import save


class Desktop:
    def __init__(self, session):
        self.session = session
        self.client = Client(session.root / "ui.sock")

    def close(self):
        self.client.close()

    def reconnect(self):
        # Operator input may outlive the server's idle connection deadline.
        # Reconnect before a fresh observation, never retry a mutating action.
        self.client.close()
        self.client = Client(self.session.root / "ui.sock")

    def request(self, action=None):
        result = self.client.request(action)
        with (self.session.output / "ui-events.jsonl").open("a") as stream:
            stream.write(json.dumps({"atNS": time.monotonic_ns(), "action": action, "response": result}) + "\n")
        if result["pid"] != self.session.app.pid:
            raise RuntimeError("UI response came from a different process")
        if result.get("ok") is not True:
            raise AssertionError(f"UI rejected operation: {result.get('error')}")
        return result["snapshot"]

    def stable(self, predicate=lambda s: True):
        deadline, since = time.monotonic() + 30, None
        while time.monotonic() < deadline:
            state = self.request()
            if state and state["mounted"] and not state["transitioning"] and predicate(state):
                if since is None:
                    since = time.monotonic()
                if time.monotonic() - since >= .2:
                    return state
            else:
                since = None
            time.sleep(.1)
        raise TimeoutError("mounted UI postcondition did not settle; see ui-events.jsonl")

    @staticmethod
    def has_turn(state, execution, destination="current"):
        controls = state.get("reading", {}).get("controls", [])
        route = any(c["role"] == "conversation" and c["value"].get("destination") == destination
            and c["value"].get("selectedRow") == "turn:" + execution
            and c["value"].get("transitioning") is False for c in controls)
        return route and any(c["role"] == "turn" and c["value"].get("executionId") == execution
            and c["value"].get("state") == "ready" and c["value"].get("visibleRowCount", 0) > 0
            for c in controls)

    def read(self, thread, initial, followup):
        overview = self.stable(lambda s: s["page"] == "overview" and s["runtimeAvailable"])
        target = next(t for t in overview["threads"] if t["threadId"] == thread)
        self.request({"name": "thread.open", "threadId": thread, "typeId": target["typeId"]})
        save(self.session.output / "ui-initial.json", self.stable(lambda s: self.has_turn(s, initial)))
        # External input uses the public Runtime path. Only reader navigation and
        # the mounted result are claimed as UI coverage, never composer submission.
        latest = followup()
        # The turn and its asynchronously mounted TOC have separate admission.
        # Wait for the actual history control, not just the new content seat.
        state = self.stable(lambda s: self.has_turn(s, latest) and any(
            c["role"] == "history.open" and c["value"] == "turn:" + initial
            for c in s["reading"]["controls"]))
        save(self.session.output / "ui-current.json", state)
        control = next(c for c in state["reading"]["controls"] if c["role"] == "history.open" and c["value"] == "turn:" + initial)
        self.request({"name": "reading.control", "controlId": control["id"], "handle": control["handle"],
                      "operation": "activate", "value": None})
        save(self.session.output / "ui-history.json", self.stable(lambda s: self.has_turn(s, initial, "history")))
        self.request({"name": "navigation.back"})
        save(self.session.output / "ui-return.json", self.stable(lambda s: self.has_turn(s, latest)))
        self.request({"name": "overview.show"})
        save(self.session.output / "ui-overview.json", self.stable(lambda s: s["page"] == "overview"))

    def settings(self):
        state = self.stable()
        if state["page"] != "overview":
            self.request({"name": "overview.show"})
            self.stable(lambda s: s["page"] == "overview")
        self.request({"name": "settings.open"})
        self.stable(lambda s: s["page"] == "settings")
        self.request({"name": "settings.select", "section": "moku"})

        def presets(state):
            return {c["id"].removeprefix("moku.routingPreset."): c for c in state["settings"]["controls"]
                    if c["id"].startswith("moku.routingPreset.") and c["enabled"] and not c["pending"]}

        state = self.stable(lambda s: len(presets(s)) == 4)
        options = presets(state)
        expected = "performance" if options["economy"]["value"] else "economy"
        control = options[expected]
        save(self.session.output / "settings-before.json", state)
        self.request({"name": "settings.control", "controlId": control["id"], "handle": control["handle"],
                      "operation": "activate", "value": None})
        state = self.stable(lambda s: expected in presets(s) and presets(s)[expected]["value"] is True)
        save(self.session.output / "settings-edited.json", state)
        self.request({"name": "settings.close"})
        self.stable(lambda s: s["page"] == "overview")
        persisted = self.session.runtime.state()
        actual = persisted["settings"]["moku"]["routingPreset"]
        save(self.session.output / "settings-persisted.json", {"expected": expected, "actual": actual,
             "revision": persisted["settingsRevision"]})
        assert actual == expected, "mounted preset did not persist through public state:load"
        self.request({"name": "settings.open"})
        self.stable(lambda s: s["page"] == "settings")
        self.request({"name": "settings.select", "section": "moku"})
        save(self.session.output / "settings-reopened.json",
             self.stable(lambda s: expected in presets(s) and presets(s)[expected]["value"] is True))
        self.request({"name": "settings.close"})
        self.stable(lambda s: s["page"] == "overview")
