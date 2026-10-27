"""Mounted production reading-control replay and seeded chaos (no model actions)."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import random
import time

from client import Client, Trace, step, validate_snapshot


class ReadingDriver:
    def __init__(self, client, trace, timeout=20):
        self.client = client
        self.trace = trace
        self.timeout = timeout
        self.coverage = Counter()

    @staticmethod
    def controls(state, role=None):
        return [control for control in state.get("reading", {}).get("controls", [])
                if role is None or control["role"] == role]

    @staticmethod
    def value(state, role):
        matches = ReadingDriver.controls(state, role)
        if len(matches) != 1:
            raise AssertionError(f"Expected one {role}, observed {len(matches)}")
        return matches[0]["value"]

    def validate(self, state):
        validate_snapshot(state)
        controls = self.controls(state)
        ids = [control["id"] for control in controls]
        if len(ids) != len(set(ids)):
            raise AssertionError("Reading control identities collide")
        for control in controls:
            value = control.get("value")
            if control["role"] in ("row.load", "execution.load") and value["state"] == "error":
                raise AssertionError(f"Reader content failed: {control}")
            if control["role"] == "turn" and not 0 <= value["visibleRowCount"] <= value["rowCount"]:
                raise AssertionError(f"Inconsistent rendered turn: {value}")
            if control["role"] == "timeline":
                if not all(math.isfinite(value[key]) for key in ("top", "height", "viewport", "contentOffset", "insetTop")):
                    raise AssertionError(f"Non-finite reading geometry: {value}")
                if abs(value["top"] - value["contentOffset"] - value["insetTop"]) > 0.01:
                    raise AssertionError(f"Reading offset lost its native inset conversion: {value}")
                if value["visibleCount"] != len(value["visibleRowIds"]) or not 0 <= value["firstIndex"] <= value["rowCount"]:
                    raise AssertionError(f"Inconsistent reading window: {value}")
                if value["firstIndex"] + value["visibleCount"] < value["rowCount"]:
                    raise AssertionError(f"Reading window dropped a tail row: {value}")

    def wait(self, predicate=lambda state: True):
        deadline = time.monotonic() + self.timeout
        previous = None
        since = None
        state = None
        while time.monotonic() < deadline:
            state = self.client.snapshot()
            self.validate(state)
            controls = self.controls(state)
            loaded = all(control.get("value", {}).get("state") != "loading"
                         for control in controls if control["role"] in ("row.load", "execution.load"))
            settled = all(not control["pending"] for control in controls)
            moving = any(control["value"].get("transitioning", False)
                         for control in controls if control["role"] == "conversation")
            expects_turn = any(control["value"]["rowCount"] > 0 and control["value"]["destination"] != "unavailable"
                               for control in controls if control["role"] == "conversation")
            rendered = not expects_turn or bool(self.controls(state, "turn"))
            usable = state["page"] == "thread" and state["mounted"] and not state["transitioning"] and controls
            if usable and loaded and rendered and settled and not moving and predicate(state):
                key = json.dumps(state["reading"], sort_keys=True)
                if key != previous:
                    since = time.monotonic()
                elif since is not None and time.monotonic() - since >= 0.15:
                    return state
                previous = key
            else:
                previous = None
                since = None
            time.sleep(0.03)
        self.trace.write({"kind": "failure", "snapshot": state, "error": "Reading state did not settle"})
        raise TimeoutError(f"Reading state did not settle: {state}")

    def control(self, role, predicate=lambda control: True):
        state = self.wait(lambda state: any(control["enabled"] and predicate(control)
                                           for control in self.controls(state, role)))
        return next(control for control in self.controls(state, role) if control["enabled"] and predicate(control))

    def invoke(self, control, operation="activate", value=None):
        action = {"name": "reading.control", "controlId": control["id"], "handle": control["handle"],
                  "operation": operation, "value": value}
        self.trace.write({"kind": "reading.action", "action": action, "role": control["role"], "before": self.client.snapshot()})
        response = self.client.request(action)
        self.trace.write({"kind": "response", "response": response})
        if not response["ok"]:
            raise AssertionError(f"Reading action rejected: {response}")
        after = self.wait()
        if control["role"] == "timeline" and operation in ("scrollTo", "scrollBy"):
            self.assert_scroll_result(control, operation, value, after)
        self.coverage[control["role"] + ":" + operation] += 1
        self.trace.write({"kind": "reading.settled", "snapshot": after})
        return after

    def assert_scroll_result(self, control, operation, amount, after):
        before = control["value"]
        target = amount + before["top"] if operation == "scrollBy" else amount
        expected = min(max(0, before["height"] - before["viewport"]), max(0, target))
        actual = next((item["value"] for item in self.controls(after, "timeline") if item["id"] == control["id"]), None)
        if actual is None or abs(actual["top"] - expected) > 0.5:
            raise AssertionError(f"{operation}({amount}) did not reach {expected}: before={before}, after={actual}")
        self.trace.write({"kind": "reading.scroll-verified", "operation": operation, "requested": amount,
                          "before": before["top"], "expected": expected, "actual": actual["top"]})

    def scroll_regression(self):
        # These values expose an inset applied twice by relative scrolling;
        # each result is checked against the last observed native geometry.
        for operation, amount in (("scrollTo", 0), ("scrollTo", 240), ("scrollBy", 120),
                                  ("scrollBy", 120), ("scrollTo", -10000000),
                                  ("scrollTo", 10000000), ("scrollBy", 120), ("scrollTo", 0)):
            self.invoke(self.control("timeline"), operation, amount)

    def toggle(self, role, wanted=None):
        control = self.control(role)
        before = control["value"]
        if wanted is not None and before == wanted:
            return self.wait()
        after = self.invoke(control)
        updated = next((item for item in self.controls(after, role) if item["id"] == control["id"]), None)
        if updated is None or updated["value"] != (not before):
            raise AssertionError(f"{role} did not toggle its mounted state")
        return after

    def expand(self):
        # Execution groups can mount another group only after a real scoped load.
        for _ in range(12):
            state = self.wait()
            choices = [control for control in self.controls(state)
                       if control["role"] in ("execution.group", "disclosure", "activity")
                       and control["enabled"] and control["value"] is False]
            if not choices:
                return state
            self.invoke(choices[0])
        raise AssertionError("Unexpectedly deep reading disclosure tree")

    def route(self, action):
        return step(self.client, self.trace, action)

    def settings_return(self):
        before = self.wait()
        conversation = self.value(before, "conversation")
        history = [item["value"] for item in self.controls(before, "history")]
        self.route({"name": "settings.open"})
        self.route({"name": "settings.close"})
        after = self.wait()
        if self.value(after, "conversation") != conversation:
            raise AssertionError("Settings return changed reading destination or visibility")
        if [item["value"] for item in self.controls(after, "history")] != history:
            raise AssertionError("Settings return changed historical visibility")
        self.coverage["settings:return"] += 1
        return after

    def stale_probe(self):
        control = self.control("visibility.userMessages")
        self.trace.write({"kind": "reading.stale-probe", "controlId": control["id"]})
        action = {"name": "reading.control", "controlId": control["id"], "handle": control["handle"],
                  "operation": "activate", "value": None}
        first = self.client.request(action)
        if not first["ok"]:
            raise AssertionError(f"Stale probe initial action failed: {first}")
        second = self.client.request(action)
        self.trace.write({"kind": "stale-response", "response": second})
        if second["ok"] or second["error"]["code"] != "stale_control":
            raise AssertionError(f"A previous render handle was accepted: {second}")
        self.coverage["stale:rejected"] += 1
        return self.wait()

    def targeted(self):
        initial = self.wait()
        if not self.controls(initial, "conversation"):
            raise AssertionError("No production conversation state is mounted")
        self.toggle("visibility.userMessages", True)
        self.toggle("visibility.work", True)
        self.expand()
        self.settings_return()
        self.stale_probe()
        if self.controls(self.wait(), "history.toggle"):
            self.toggle("history.toggle", True)
            earlier = self.controls(self.wait(), "loadEarlier")
            if earlier:
                before = self.value(self.wait(), "timeline")
                after = self.invoke(earlier[0])
                if self.value(after, "timeline")["firstIndex"] >= before["firstIndex"]:
                    raise AssertionError("Load earlier did not extend the real timeline window")
            entry = self.control("history.open")
            after = self.invoke(entry)
            if self.value(after, "conversation")["historyRow"] != entry["value"]:
                raise AssertionError("Historical row opened the wrong destination")
            self.toggle("visibility.userMessages", True)
            self.toggle("visibility.work", True)
            self.expand()
            self.settings_return()
            self.scroll_regression()
            self.invoke(self.control("history.close"))
        timeline = self.control("timeline")
        self.invoke(timeline, "scrollTo", 0)
        latest = self.controls(self.wait(), "jumpLatest")
        if latest:
            after = self.invoke(latest[0])
            if self.value(after, "conversation")["historyOpen"]:
                raise AssertionError("Jump latest did not collapse historical rows")
        self.invoke(self.control("timeline"), "scrollBy", -500)

    def monkey(self, seed, steps):
        rng = random.Random(seed)
        for index in range(steps):
            state = self.wait()
            if index > 0 and index % 23 == 0:
                self.settings_return()
                continue
            choices = []
            for control in self.controls(state):
                if not control["enabled"] or not control["operations"]:
                    continue
                if "activate" in control["operations"]:
                    choices.append((control, "activate", None))
                if control["role"] == "timeline":
                    for offset in (0, 240, 1200, 10000000):
                        choices.append((control, "scrollTo", offset))
                    for offset in (-800, -120, 120, 800):
                        choices.append((control, "scrollBy", offset))
            if not choices:
                raise AssertionError("Mounted reading document has no available controls")
            control, operation, value = rng.choice(choices)
            before = control["value"]
            after = self.invoke(control, operation, value)
            if isinstance(before, bool) and operation == "activate":
                updated = next((item for item in self.controls(after) if item["id"] == control["id"]), None)
                if updated is not None and updated["value"] != (not before):
                    raise AssertionError(f"Disclosure did not change: {control['id']}")
            if index > 0 and index % 31 == 0:
                self.stale_probe()

    def replay(self, source):
        for record in map(json.loads, Path(source).read_text().splitlines()):
            if record["kind"] == "action":
                self.route(record["action"])
            elif record["kind"] == "reading.action":
                action = record["action"]
                state = self.wait(lambda state: any(item["id"] == action["controlId"] for item in self.controls(state)))
                control = next(item for item in self.controls(state) if item["id"] == action["controlId"])
                self.invoke(control, action["operation"], action["value"])
            elif record["kind"] == "reading.stale-probe":
                self.stale_probe()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--trace", required=True)
    parser.add_argument("--thread-id", help="Existing isolated fixture agent thread to open")
    parser.add_argument("--seed", type=int, default=41)
    parser.add_argument("--steps", type=int, default=100)
    parser.add_argument("--replay", help="Replay a prior thread_chaos trace using fresh mounted handles")
    parser.add_argument("--skip-targeted", action="store_true")
    args = parser.parse_args()
    if args.steps < 1:
        parser.error("steps must be positive")
    client = Client(args.socket)
    trace = Trace(args.trace, command="reading", seed=args.seed)
    try:
        driver = ReadingDriver(client, trace)
        if args.replay:
            driver.replay(args.replay)
        else:
            state = client.settle()
            if args.thread_id:
                if state["page"] != "overview":
                    driver.route({"name": "overview.show"})
                driver.route({"name": "thread.open", "typeId": "agent", "threadId": args.thread_id})
            if not args.skip_targeted:
                driver.targeted()
            driver.monkey(args.seed, args.steps)
        trace.write({"kind": "complete", "coverage": dict(driver.coverage)})
        print(json.dumps({"result": "PASS", "seed": args.seed, "coverage": dict(driver.coverage), "trace": args.trace}))
    except BaseException as error:
        trace.write({"kind": "failure", "error": str(error)})
        raise
    finally:
        trace.close()
        client.close()


if __name__ == "__main__":
    main()
