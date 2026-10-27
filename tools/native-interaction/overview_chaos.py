"""Real production Overview controls with scoped-directory and geometry oracles."""
import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import plistlib
import random
import signal
import subprocess
import tempfile
import time
import unicodedata

import client as api
from settings_chaos import Runtime


REPO = Path(__file__).resolve().parents[2]


def fixture(root):
    """Real filesystem metadata, not a replacement app, renderer or Runtime."""
    paths = {name: root / relative for name, relative in {
        "left": "left/project", "right": "right/project", "nested": "left/project/nested",
        "unicode": "中文目录/项目 space", "repo": "repo", "worktree": "repo-linked",
        "inbox": "runtime-workspace/tmp-workspaces/owned", "alias": "project-alias"}.items()}
    for key in ("left", "right", "nested", "unicode", "repo", "inbox"):
        paths[key].mkdir(parents=True)
    paths["alias"].symlink_to(paths["left"], target_is_directory=True)
    git_env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    def git(*args):
        subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                        "-c", "user.name=Overview Chaos", "-c", "user.email=chaos@example.invalid", *args],
                       check=True, env=git_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    git("init", "--initial-branch=main", str(paths["repo"]))
    git("-C", str(paths["repo"]), "commit", "--allow-empty", "-m", "Seed isolated Overview replay")
    git("-C", str(paths["repo"]), "worktree", "add", "-b", "chaos", str(paths["worktree"]))
    (paths["worktree"] / "src").mkdir()
    rows = []
    def row(name, directory, tags, archived=False, suffix=""):
        rows.append({"threadId": "overview-" + name, "cwd": str(paths[directory] / suffix),
                     "title": "Overview replay needle" + name, "tags": tags, "archived": archived})
    row("leftalpha", "left", ["alpha"])
    row("leftbeta", "left", ["beta"])
    row("rightalpha", "right", ["alpha"])
    row("symlink", "alias", ["beta"])
    row("nested", "nested", ["alpha"])
    row("repo", "repo", ["alpha"])
    row("worktree", "worktree", ["beta"], suffix="src")
    row("unicode", "unicode", ["共同标签"])
    row("inbox", "inbox", ["inbox"])
    row("equalmembers", "left", ["equal-a", "equal-b"])
    row("archived", "left", ["archived-only"], archived=True)
    value = {"rows": rows, "paths": {key: str(path) for key, path in paths.items()}}
    path = root / "fixture.json"
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    return path, value


def key(text):
    return " ".join(unicodedata.normalize("NFKC", text).lower().split())


class Driver:
    def __init__(self, client, trace, runtime, fixture_value):
        self.client, self.trace, self.runtime = client, trace, runtime
        self.fixture = fixture_value
        self.coverage = Counter()
        self.records = {}
        self.baseline = None

    def oracle(self):
        state = self.runtime.state()
        ids = {row["threadId"] for row in self.fixture["rows"]}
        records = {thread["id"]: thread for thread in state["threads"] if thread["id"] in ids}
        assert set(records) == ids, "Runtime lost seeded records"
        durable = {identity: {field: record.get(field) for field in ("cwd", "title", "tags", "archived")}
                   for identity, record in records.items()}
        if self.baseline is None:
            self.baseline = durable
        else:
            assert durable == self.baseline, "Browsing unexpectedly changed durable thread metadata"
        self.records = {identity: record for identity, record in records.items() if not record.get("archived")}
        paths = self.fixture["paths"]
        assert self.records["overview-leftalpha"]["directoryScope"] == self.records["overview-symlink"]["directoryScope"], "Symlink scope did not canonicalize"
        assert self.records["overview-repo"]["directoryScope"] == self.records["overview-worktree"]["directoryScope"], "Linked worktree lost repository scope"
        assert self.records["overview-leftalpha"]["directoryScope"] != self.records["overview-rightalpha"]["directoryScope"], "Same-basename directories collapsed"
        assert self.records["overview-inbox"]["directoryScope"] == "inbox"
        assert self.records["overview-inbox"]["directoryTag"] == "", "Managed temporary directory leaked into directory tags"
        assert self.records["overview-nested"]["directoryScope"] == str(Path(paths["nested"]).resolve())
        self.coverage["independent-runtime-oracle"] += 1
        self.trace.write({"kind": "oracle", "records": records})

    def members(self, selected=None):
        records = self.records
        if selected is None:
            return set(records)
        scoped = {identity: row for identity, row in records.items() if row["directoryScope"] == selected["scope"]}
        if selected["kind"] == "directory":
            return set(scoped)
        tags = {key(selected["tag"]), *(key(alias) for alias in selected["aliases"])}
        return {identity for identity, row in scoped.items() if tags.intersection(map(key, row["tags"]))}

    def check(self, state):
        api.validate_snapshot(state)
        if state["page"] != "overview":
            return
        overview = state["overview"]
        filters = overview["filters"]
        flat = filters + [child for parent in filters for child in parent["children"]]
        assert len({item["id"] for item in flat}) == len(flat), "Duplicate scoped filter identity"
        for item in flat:
            assert item["count"] == len(self.members(item)), f"Filter count differs from Runtime scope: {item}"
            for child in item["children"]:
                assert child["scope"] == item["scope"] and child["kind"] == "semantic"
                assert self.members(child) <= self.members(item), "Child tag escaped directory scope"
        selected = next((item for item in flat if item["id"] == state["selectedFilterId"]), None)
        actual = {card["id"] for card in overview["cards"]}
        allowed = self.members(selected)
        assert actual <= allowed, f"Cards escaped current scope: {actual - allowed}"
        if not state["search"]["active"] or not state["search"]["query"].strip():
            assert actual == allowed, f"Missing scoped cards: {allowed - actual}"
        if not overview["layingOut"] and overview["stage"] is None:
            placements = overview["placements"]
            assert {placement["id"] for placement in placements} == actual, "Settled layout membership differs from visible cards"
            occupied = set()
            for placement in placements:
                assert placement["columns"] > 0 and placement["rows"] > 0
                cells = {(x, y) for x in range(placement["column"], placement["column"] + placement["columns"])
                         for y in range(placement["row"], placement["row"] + placement["rows"])}
                assert not cells & occupied, "Settled cards overlap"
                occupied |= cells
            assert actual <= set(overview["mountedCardIds"]), "Settled semantic card is not mounted"
        camera = overview["camera"]
        assert all(math.isfinite(camera[field]) for field in ("x", "y", "scale")), "Nonfinite camera transform"
        if camera["initialized"]:
            assert camera["minimumScale"] - 1e-6 <= camera["scale"] <= camera["maximumScale"] + 1e-6, "Camera escaped readable scale limits"
        if state["search"]["active"]:
            assert not overview["menu"]["mountedMenuIds"], "Directory submenu remained mounted over search"

    def settle(self, predicate=lambda state: True, timeout=20):
        def ready(state):
            overview = state["overview"]
            camera = overview["camera"]
            # A camera can acknowledge manual=false before a stage reservation
            # starts, or defer explicit fitting while Compose owns interaction.
            # Only that deliberate pause is a stable pending-fit state here.
            fit_ready = (not camera["automaticFitPending"] or
                         (overview["dock"]["inputOpen"] and camera["automaticFitBlocked"] == "interaction"))
            geometry_ready = (state["page"] != "overview" or
                              (not overview["layingOut"] and overview["stage"] is None and
                               not camera["animating"] and not camera["motionPending"] and fit_ready and
                               {p["id"] for p in overview["placements"]} == {c["id"] for c in overview["cards"]} and
                               {c["id"] for c in overview["cards"]} <= set(overview["mountedCardIds"])))
            menu_ready = not state["search"]["active"] or not overview["menu"]["mountedMenuIds"]
            return geometry_ready and menu_ready and not overview["dock"]["inputLeaving"] and predicate(state)
        state = self.client.settle(ready, timeout)
        self.check(state)
        return state

    @staticmethod
    def automatic_fit_applied(state):
        camera = state["overview"]["camera"]
        target = camera["automaticFitTarget"]
        return (target is not None and not camera["manual"] and not camera["automaticFitPending"] and
                not camera["motionPending"] and not camera["animating"] and
                all(abs(camera[field] - target[field]) < 0.01 for field in ("x", "y", "scale")))

    def action(self, action, expected=None, wait=True, predicate=None):
        before = self.client.snapshot()
        self.trace.write({"kind": "action", "action": action, "before": before, "wait": wait, "expectedError": expected})
        response = self.client.request(action)
        self.trace.write({"kind": "response", "response": response})
        if expected:
            assert not response["ok"] and response["error"]["code"] == expected, response
            self.coverage["rejected:" + expected] += 1
        elif not response["ok"]:
            # An asynchronous route can finish between observation and dispatch.
            # Only admission that actually disappeared is an expected stale choice.
            if response["error"]["code"] == "unavailable" and action["name"] not in response["snapshot"]["actions"]:
                self.coverage["stale-choice-rejected"] += 1
                return self.settle()
            raise AssertionError(f"Unexpected action rejection: {response}")
        else:
            self.coverage[action["name"]] += 1
        if wait:
            post = predicate or (api.postcondition(action, before) if not expected else lambda state: True)
            if predicate is None and not expected:
                if action["name"] == "overview.directory.open":
                    post = lambda s: action["directoryId"] in s["overview"]["menu"]["mountedMenuIds"]
                elif action["name"] == "overview.directory.close":
                    post = lambda s: action["directoryId"] not in s["overview"]["menu"]["mountedMenuIds"]
                elif action["name"] == "overview.filters.scroll":
                    target = next(item for item in before["overview"]["filters"] if item["id"] == action["filterId"])
                    if target["kind"] == "directory":
                        post = lambda s: action["filterId"] in s["overview"]["menu"]["mountedDirectoryIds"]
                elif action["name"] == "overview.auto" and not before["overview"]["dock"]["inputOpen"]:
                    post = self.automatic_fit_applied
            if not expected and action["name"] == "overview.directory.select":
                requested = post
                parent = next(item for item in before["overview"]["filters"] if item["id"] == action["directoryId"])
                # Production selection closes the glass menu. Its retiring
                # controls cannot be used as the next child's selection surface.
                post = lambda s: (requested(s) and s["selectedFilterId"] == action["filterId"] and
                                  action["directoryId"] not in s["overview"]["menu"]["mountedMenuIds"] and
                                  s["overview"]["menu"]["openScope"] != parent["scope"])
            after = self.settle(post)
            self.trace.write({"kind": "settled", "snapshot": after})
            return after
        return response["snapshot"]

    def open_directory(self, parent):
        # The selected child changes the parent chip width after menu exit, so
        # expose its current control again before reopening the real submenu.
        self.action({"name": "overview.filters.scroll", "filterId": parent["id"]},
                    predicate=lambda s: parent["id"] in s["overview"]["menu"]["mountedDirectoryIds"])
        self.action({"name": "overview.directory.open", "directoryId": parent["id"]},
                    predicate=lambda s: (parent["id"] in s["overview"]["menu"]["mountedMenuIds"] and
                                         s["overview"]["menu"]["openScope"] == parent["scope"]))

    def reset(self):
        state = self.client.snapshot()
        if state["page"] != "overview":
            self.action({"name": "overview.show"})
        if self.client.snapshot()["search"]["active"]:
            self.action({"name": "search.end"})
        state = self.settle()
        if state["overview"]["dock"]["inputOpen"]:
            self.action({"name": "moku.input.toggle"})
        if self.client.snapshot()["overview"]["dock"]["noteOpen"]:
            self.action({"name": "moku.note.toggle"})
        self.action({"name": "filter.select", "filterId": None})
        self.action({"name": "overview.auto"})

    def smoke(self):
        self.oracle()
        initial = self.settle(lambda s: s["runtimeAvailable"] and len(s["overview"]["cards"]) == len(self.records))
        filters = sorted(initial["overview"]["filters"], key=lambda item: item["id"])
        directories = [item for item in filters if item["kind"] == "directory"]
        assert len(directories) >= 5, "Fixture did not expose directory coverage"
        same_names = [item for item in directories if item["tag"] == "project"]
        assert len(same_names) == 2 and len({item["label"] for item in same_names}) == 2, "Same-name directory labels are ambiguous"
        left = next(item for item in directories if item["scope"] == self.records["overview-leftalpha"]["directoryScope"])
        equal_tags = [child for child in left["children"] if child["tag"] in ("equal-a", "equal-b")]
        assert len(equal_tags) == 2 and self.members(equal_tags[0]) == self.members(equal_tags[1]), "Equal-membership tags lost their independent controls"
        for parent in filters:
            self.action({"name": "filter.select", "filterId": parent["id"]})
            self.coverage["filter:" + parent["kind"]] += 1
            if parent["kind"] != "directory" or not parent["children"]:
                continue
            for child in parent["children"]:
                self.open_directory(parent)
                self.action({"name": "overview.directory.select", "directoryId": parent["id"], "filterId": child["id"]})
                self.coverage["mounted-child-selection"] += 1
            self.open_directory(parent)
            self.action({"name": "overview.directory.select", "directoryId": parent["id"], "filterId": "missing-child"}, expected="not_found")
            self.action({"name": "overview.directory.close", "directoryId": parent["id"]},
                        predicate=lambda s: not s["overview"]["menu"]["mountedMenuIds"])
            self.action({"name": "overview.directory.select", "directoryId": parent["id"], "filterId": parent["children"][0]["id"]}, expected="unavailable")
        self.coverage.update({"same-basename-scopes": 1, "symlink-scope": 1, "linked-worktree-scope": 1,
                              "nested-directory-scope": 1, "unicode-directory": 1, "temporary-inbox": 1,
                              "equal-membership-tags": 1, "archived-exclusion": 1})
        self.action({"name": "filter.select", "filterId": left["id"]})
        self.action({"name": "search.begin"})
        scoped = self.action({"name": "search.update", "query": "alpha"})
        assert "overview-leftalpha" in {card["id"] for card in scoped["overview"]["cards"]}
        assert "overview-rightalpha" not in {card["id"] for card in scoped["overview"]["cards"]}, "Search escaped selected same-name directory"
        self.coverage["scoped-search"] += 1
        self.action({"name": "search.end"})
        self.reset()
        self.action({"name": "overview.pan", "deltaX": 127, "deltaY": -81})
        baseline = self.action({"name": "overview.zoom", "delta": -90, "x": 0.37, "y": 0.62})["overview"]["camera"]
        self.action({"name": "search.begin"})
        result = self.action({"name": "search.update", "query": "needleleftalpha"})
        assert "overview-leftalpha" in {card["id"] for card in result["overview"]["cards"]}, "Keyword match disappeared"
        result = self.action({"name": "search.end"})
        restored = result["overview"]["camera"]
        assert restored["manual"] and all(abs(restored[k] - baseline[k]) < 0.01 for k in ("x", "y", "scale")), "Search did not restore manual camera"
        self.coverage["search-camera-restoration"] += 1
        self.action({"name": "overview.zoom", "delta": 1000, "x": 0.5, "y": 0.5})
        self.action({"name": "overview.zoom", "delta": -1000, "x": 0.5, "y": 0.5})
        self.action({"name": "overview.zoom", "delta": 0, "x": -0.1, "y": 0.5}, expected="invalid_request")
        self.action({"name": "overview.pan", "deltaX": 10001, "deltaY": 0}, expected="invalid_request")
        automatic = self.action({"name": "overview.auto"}, predicate=self.automatic_fit_applied)["overview"]["camera"]
        moved = self.action({"name": "overview.pan", "deltaX": 181, "deltaY": 97})["overview"]["camera"]
        self.action({"name": "moku.input.toggle"}, predicate=lambda s: s["overview"]["dock"]["inputOpen"])
        deferred = self.action({"name": "overview.auto"})["overview"]["camera"]
        assert not deferred["manual"] and deferred["automaticFitPending"] and deferred["automaticFitBlocked"] == "interaction", "Automatic fit was not deferred by Compose"
        assert all(abs(deferred[k] - moved[k]) < 0.01 for k in ("x", "y", "scale")), "Automatic fit did not wait for composer dismissal"
        resumed = self.action({"name": "moku.input.toggle"},
                              predicate=lambda s: not s["overview"]["dock"]["inputOpen"] and self.automatic_fit_applied(s))["overview"]["camera"]
        assert all(abs(resumed[k] - automatic[k]) < 0.01 for k in ("x", "y", "scale")), "Deferred automatic fit did not resume"
        self.coverage["deferred-auto-fit"] += 1
        self.action({"name": "search.begin"})
        result = self.action({"name": "search.update", "query": "absent-864bddb4-no-match"})
        if result["search"]["mode"] == "keyword":
            assert result["overview"]["cards"] == []
            self.coverage["empty-result"] += 1
        self.action({"name": "search.end"})
        for ref in self.client.snapshot()["threads"]:
            self.action({"name": "thread.open", **ref})
            self.action({"name": "navigation.back"}, predicate=lambda s: s["page"] == "overview")
        for name, field in (("moku.input.toggle", "inputOpen"), ("moku.note.toggle", "noteOpen")):
            self.action({"name": name}, predicate=lambda s, f=field: s["overview"]["dock"][f])
            self.action({"name": name}, predicate=lambda s, f=field: not s["overview"]["dock"][f])
        self.action({"name": "moku.history.toggle"}, predicate=lambda s: s["page"] == "moku")
        self.action({"name": "moku.history.toggle"}, predicate=lambda s: s["page"] == "overview")
        self.oracle()

    def monkey(self, seed, steps):
        rng = random.Random(seed)
        for index in range(steps):
            state = self.settle()
            overview = state["overview"]
            choices = []
            if state["page"] != "overview":
                choices = [{"name": "overview.show"}]
            else:
                for name in state["actions"]:
                    if name in ("search.begin", "search.end", "overview.auto", "moku.input.toggle", "moku.note.toggle", "moku.history.toggle"):
                        choices.append({"name": name})
                    elif name == "filter.select":
                        choices.extend({"name": name, "filterId": target} for target in [None] + [item["id"] for item in state["filters"]])
                    elif name == "search.update":
                        choices.extend({"name": name, "query": q} for q in ("", "alpha", "needleleftalpha", "共同标签", "absent-864bddb4-no-match", "🙂"))
                    elif name == "overview.pan":
                        choices.append({"name": name, "deltaX": rng.uniform(-250, 250), "deltaY": rng.uniform(-200, 200)})
                    elif name == "overview.zoom":
                        choices.append({"name": name, "delta": rng.choice([-1000, -100, 100, 1000]), "x": rng.random(), "y": rng.random()})
                    elif name == "thread.open":
                        choices.extend({"name": name, **ref} for ref in state["threads"])
                    elif name == "overview.filters.scroll":
                        choices.extend({"name": name, "filterId": f["id"]} for f in overview["filters"])
                    elif name == "overview.directory.open":
                        choices.extend({"name": name, "directoryId": identity} for identity in overview["menu"]["mountedDirectoryIds"])
                    elif name in ("overview.directory.close", "overview.directory.select"):
                        for parent in overview["filters"]:
                            if (parent["id"] not in overview["menu"]["mountedMenuIds"] or
                                parent["id"] not in overview["menu"]["mountedDirectoryIds"] or
                                overview["menu"]["openScope"] != parent["scope"]):
                                continue
                            if name.endswith("close"):
                                choices.append({"name": name, "directoryId": parent["id"]})
                            else:
                                choices.extend({"name": name, "directoryId": parent["id"], "filterId": child["id"]} for child in parent["children"])
            assert choices, "No supported Overview action available"
            choices.sort(key=lambda action: json.dumps(action, sort_keys=True))
            chosen = rng.choice(choices)
            if chosen["name"] == "overview.directory.select":
                self.open_directory(next(parent for parent in overview["filters"] if parent["id"] == chosen["directoryId"]))
            self.action(chosen)
            if index % 20 == 0:
                self.oracle()
        self.reset()
        self.oracle()
        self.trace.write({"kind": "complete", "steps": steps, "coverage": dict(self.coverage)})


def run_seed(bundle, root, seed, steps):
    run = root / f"seed-{seed}"
    run.mkdir(mode=0o700)
    fixture_path, fixture_value = fixture(run)
    profile = run / "profile"
    subprocess.run(["./scripts/go.sh", "run", "./tools/verification/overview-interaction", str(profile), str(fixture_path)], cwd=REPO, check=True)
    macos = bundle / "Contents/MacOS"
    endpoint = run / "ui.sock"
    log = (run / "app.log").open("w")
    app = subprocess.Popen([str(macos / "Mokusei"), "--data-dir", str(profile), "--automation-socket", str(endpoint)],
                           cwd=run, stdout=log, stderr=subprocess.STDOUT)
    client = trace = driver = None
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if app.poll() is not None:
                raise RuntimeError(f"Production app exited with {app.returncode}")
            try:
                client = api.Client(endpoint, timeout=30)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.1)
        if client is None:
            raise TimeoutError("Production semantic socket did not start")
        assert client.request()["pid"] == app.pid
        client.settle(lambda s: s["runtimeAvailable"] and s["page"] == "overview", timeout=60)
        trace = api.Trace(run / "chaos.jsonl", command="overview-chaos", seed=seed, productionApp=str(bundle))
        driver = Driver(client, trace, Runtime(profile), fixture_value)
        driver.smoke()
        driver.monkey(seed, steps)
        print(f"PASS Overview seed {seed}: {steps} random actions plus full feature smoke", flush=True)
    except BaseException as error:
        if trace:
            trace.write({"kind": "failure", "error": str(error)})
        raise
    finally:
        if driver:
            (run / "coverage.json").write_text(json.dumps(dict(driver.coverage), indent=2, sort_keys=True))
        if trace:
            trace.close()
        if client:
            client.close()
        if app.poll() is None:
            app.send_signal(signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(timeout=5)
        log.close()
        subprocess.run([str(macos / "mokusei-runtime"), "stop", "--data-dir", str(profile)], cwd=run, timeout=30, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--steps", type=int, default=200)
    parser.add_argument("--seeds", default="41001,41002,41003")
    args = parser.parse_args()
    if args.steps < 1:
        parser.error("steps must be positive")
    seeds = [int(seed) for seed in args.seeds.split(",")]
    if len(set(seeds)) != len(seeds):
        parser.error("seeds must be unique")
    bundle = args.app.resolve()
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    provenance = json.loads((bundle / "Contents/Resources/build-provenance.json").read_text())
    if info.get("CFBundleIdentifier") != "com.mokusei.desktop" or provenance.get("channel") != "production" or provenance.get("configuration") != "release":
        parser.error("Overview chaos requires the signed production Release application")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    root = Path(tempfile.mkdtemp(prefix="oa-overview-", dir="/private/tmp"))
    (root / "application.json").write_text(json.dumps({"app": str(bundle), "provenance": provenance}, indent=2))
    print(f"Overview evidence: {root}", flush=True)
    for seed in seeds:
        run_seed(bundle, root, seed, args.steps)


if __name__ == "__main__":
    main()
