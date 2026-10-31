"""Semantic macOS UI client and deterministic navigation chaos runner (stdlib only)."""
import argparse
import json
import os
from pathlib import Path
import random
import socket
import time
import uuid


# Control runners supply their own arguments and postconditions. A newly exposed
# page action must not accidentally become a parameterless navigation candidate.
NAVIGATION_ACTIONS = frozenset({
    "settings.open", "settings.close", "settings.select", "overview.show",
    "navigation.back", "thread.open", "search.begin", "search.update",
    "search.end", "filter.select",
})


class Client:
    def __init__(self, path, timeout=5):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout)
        try:
            self.socket.connect(str(path))
        except BaseException:
            self.socket.close()
            raise
        self.reader = self.socket.makefile("rb")
        self.sequence = 0
        self.session = None
        self.response_sequence = 0

    def close(self):
        self.reader.close()
        self.socket.close()

    def request(self, action=None, snapshot=True):
        self.sequence += 1
        request = {"protocol": 1, "id": str(self.sequence), "op": "perform" if action is not None else "snapshot"}
        if action is not None:
            request["action"] = action
            # High-rate input replay omits the per-action snapshot; the caller
            # observes state with a separate request when it needs to.
            if not snapshot:
                request["snapshot"] = False
        self.socket.sendall(json.dumps(request, ensure_ascii=False).encode() + b"\n")
        line = self.reader.readline(2 * 1024 * 1024 + 1)
        if not line.endswith(b"\n") or len(line) > 2 * 1024 * 1024:
            raise RuntimeError("Automation connection closed or response exceeded its limit")
        response = json.loads(line)
        if response.get("protocol") != 1 or response.get("id") != request["id"]:
            raise RuntimeError("Automation response identity mismatch")
        if self.session is not None and self.session != response["session"]:
            raise RuntimeError("App session changed during the run")
        if response["sequence"] <= self.response_sequence:
            raise RuntimeError("Automation responses arrived out of order")
        self.session = response["session"]
        self.response_sequence = response["sequence"]
        return response

    def snapshot(self):
        response = self.request()
        if not response["ok"] or response["snapshot"] is None:
            raise RuntimeError(f"Workspace is unavailable: {response}")
        return response["snapshot"]

    def settle(self, predicate=lambda state: True, timeout=8):
        deadline = time.monotonic() + timeout
        stable_since = None
        previous = None
        while time.monotonic() < deadline:
            state = self.snapshot()
            # Require repeated observations across UI updates: an immediate reply
            # may precede SwiftUI installing its animation or page lifecycle.
            key = (state["page"], state["settingsSection"], state["selectedThread"], state["search"], state["selectedFilterId"])
            if state["mounted"] and not state["transitioning"] and predicate(state):
                if key != previous:
                    stable_since = time.monotonic()
                elif stable_since is not None and time.monotonic() - stable_since >= 0.15:
                    return state
                previous = key
            else:
                stable_since = None
                previous = None
            time.sleep(0.03)
        raise TimeoutError(f"Workspace did not reach the requested stable state: {state}")


class Trace:
    def __init__(self, path, **metadata):
        self.file = os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w")
        self.write({"kind": "header", "version": 1, **metadata})

    def write(self, record):
        self.file.write(json.dumps(record, ensure_ascii=True, sort_keys=True) + "\n")
        self.file.flush()

    def close(self):
        self.file.close()


def postcondition(action, before):
    name = action["name"]
    if name == "settings.open":
        return lambda state: state["page"] == "settings"
    if name == "settings.select":
        return lambda state: state["settingsSection"] == action["section"]
    if name == "settings.close" or (name == "navigation.back" and before["page"] == "settings"):
        return lambda state: state["page"] != "settings"
    if name == "overview.show":
        return lambda state: state["page"] == "overview"
    if name == "thread.open":
        ref = {key: action[key] for key in ("typeId", "threadId")}
        return lambda state: state["page"] == "thread" and state["selectedThread"] == ref and "navigation.back" in state["actions"]
    if name == "search.begin":
        return lambda state: state["search"]["active"]
    if name == "search.update":
        return lambda state: state["search"]["query"] == action["query"]
    if name == "search.end":
        return lambda state: not state["search"]["active"] and state["search"]["query"] == ""
    if name == "filter.select":
        return lambda state: state["selectedFilterId"] == action["filterId"]
    return lambda state: True


def candidate_available(action, state):
    name = action["name"]
    if name not in NAVIGATION_ACTIONS or name not in state["actions"]:
        return False
    if name == "settings.select":
        return action["section"] in state["settingsSections"]
    if name == "thread.open":
        return {key: action[key] for key in ("threadId", "typeId")} in state["threads"]
    if name == "filter.select":
        return action["filterId"] is None or any(item["id"] == action["filterId"] for item in state["filters"])
    return True


def step(client, trace, action, wait=True, expected_error=None, *, candidate_state=None):
    """Execute a directed action, or return None for a confirmed stale candidate."""
    if candidate_state is not None and (expected_error or not candidate_available(action, candidate_state)):
        raise ValueError("Random action must be available in its selection snapshot")
    before = client.snapshot()
    if candidate_state is not None:
        validate_snapshot(before)
        if not candidate_available(action, before):
            trace.write({"kind": "candidate-refresh", "action": action, "selectedFrom": candidate_state, "snapshot": before})
            return None
    attempt = uuid.uuid4().hex if candidate_state is not None else None
    trace.write({"kind": "action", "action": action, "before": before, "wait": wait,
                 "expectedError": expected_error, "candidateAttempt": attempt})
    try:
        response = client.request(action)
        trace.write({"kind": "response", "response": response})
        if expected_error:
            if response["ok"] or response["error"]["code"] != expected_error:
                raise AssertionError(f"Expected {expected_error}: {response}")
        elif not response["ok"]:
            after = response["snapshot"]
            code = response["error"]["code"]
            # Only a definite admission rejection can refresh the next choice.
            # A transport failure may have applied the action and must still fail.
            if candidate_state is not None and after is not None and (
                (code == "unavailable" and action["name"] not in after["actions"])
                or (code == "not_found" and action["name"] in {"settings.select", "thread.open", "filter.select"}
                    and not candidate_available(action, after))
            ):
                validate_snapshot(after)
                trace.write({"kind": "candidate-rejected", "candidateAttempt": attempt,
                             "action": action, "error": response["error"]})
                return None
            raise AssertionError(f"Action rejected: {response}")
        if wait:
            after = client.settle(postcondition(action, before) if not expected_error else lambda state: True)
            validate_snapshot(after)
            trace.write({"kind": "settled", "snapshot": after})
            return after
        return response["snapshot"]
    except BaseException as error:
        trace.write({"kind": "failure", "error": str(error)})
        raise


def validate_snapshot(state):
    if state["errors"]:
        raise AssertionError(f"Workspace surfaced errors: {state['errors']}")
    if state["page"] == "overview" and state["selectedThread"] is not None:
        raise AssertionError("Overview retained a selected reading thread")
    if state["page"] == "thread" and state["selectedThread"] is None:
        raise AssertionError("Thread page lost its identity")
    if state["page"] == "settings" and state["settingsSection"] not in state["settingsSections"]:
        raise AssertionError("Settings selected an unavailable section")


def candidates(state):
    result = []
    for name in NAVIGATION_ACTIONS.intersection(state["actions"]):
        if name == "settings.select":
            result.extend({"name": name, "section": section} for section in state["settingsSections"])
        elif name == "thread.open":
            result.extend({"name": name, **ref} for ref in state["threads"])
        elif name == "filter.select":
            result.extend({"name": name, "filterId": value} for value in [None] + [f["id"] for f in state["filters"]])
        elif name == "search.update":
            result.extend({"name": name, "query": text} for text in ("", "replay", "不存在", "settings", "🙂"))
        else:
            result.append({"name": name})
    return sorted(result, key=lambda action: json.dumps(action, sort_keys=True))


def monkey(client, trace, seed, steps, timeout=120):
    rng = random.Random(seed)
    deadline = time.monotonic() + timeout
    client.settle()
    completed = 0
    refreshed = 0
    while completed < steps:
        if time.monotonic() > deadline:
            raise TimeoutError("Chaos run exceeded its total deadline")
        state = client.snapshot()
        validate_snapshot(state)
        choices = candidates(state)
        if not choices:
            raise AssertionError("Mounted workspace has no available actions")
        after = step(client, trace, rng.choice(choices), wait=rng.random() >= 0.3, candidate_state=state)
        if after is None:
            refreshed += 1
        else:
            completed += 1
    client.settle()
    trace.write({"kind": "complete", "steps": completed, "refreshedCandidates": refreshed})


def replay(client, trace, source):
    records = [json.loads(line) for line in Path(source).read_text().splitlines()]
    if not records or records[0].get("version") != 1:
        raise ValueError("Unsupported trace version")
    # Confirmed stale rejections had no effect. Preserve accepted and unanswered
    # attempts; an uncertain action is still replayed only by this explicit call.
    rejected = {record["candidateAttempt"] for record in records if record["kind"] == "candidate-rejected"}
    for record in records:
        if record["kind"] == "action" and record.get("candidateAttempt") not in rejected:
            step(client, trace, record["action"], record["wait"], record.get("expectedError"))
    client.settle()
    trace.write({"kind": "complete"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot")
    perform = sub.add_parser("perform")
    perform.add_argument("action", help='JSON action, e.g. {"name":"settings.open"}')
    perform.add_argument("--no-snapshot", action="store_true",
                         help="omit the response snapshot; observe state separately")
    chaos = sub.add_parser("monkey")
    chaos.add_argument("--seed", type=int, default=1)
    chaos.add_argument("--steps", type=int, default=100)
    chaos.add_argument("--timeout", type=float, default=120)
    chaos.add_argument("--trace", required=True)
    play = sub.add_parser("replay")
    play.add_argument("source")
    play.add_argument("--trace", required=True)
    args = parser.parse_args()
    client = Client(args.socket)
    trace = None
    try:
        if args.command in ("snapshot", "perform"):
            result = client.request(json.loads(args.action) if args.command == "perform" else None,
                                    snapshot=not getattr(args, "no_snapshot", False))
            print(json.dumps(result, ensure_ascii=False, indent=2))
            if not result["ok"]:
                raise SystemExit(1)
        else:
            if args.command == "monkey" and (args.steps < 1 or args.timeout <= 0):
                parser.error("steps and timeout must be positive")
            trace = Trace(args.trace, command=args.command, seed=getattr(args, "seed", None))
            if args.command == "monkey":
                monkey(client, trace, args.seed, args.steps, args.timeout)
            else:
                replay(client, trace, args.source)
            print(f"PASS {args.command}; trace: {args.trace}")
    finally:
        if trace:
            trace.close()
        client.close()


if __name__ == "__main__":
    main()
