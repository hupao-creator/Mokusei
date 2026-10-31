"""Canvas-pan frame and cost measurement on a prepared real-data profile.

Two independent observations of the same drag, per condition:

* compositor frames  — Instruments' Animation Hitches tables (frame lifetimes,
  per-surface frame intervals, hitches). External to the product, so the same
  numbers can certify any build.
* main-thread cost    — the production camera pan is driven through the
  automation socket at an unbounded request rate; the per-request service time
  on the UI's main actor is the marginal cost of one camera update.

The socket path must be pre-created by the launcher; this tool never touches the
user's daily profile. See README.md for the contract and the retained baseline.

usage:
  python3 tools/verification/overview-pan/run.py \
    --app app/macos/.build/arm64-apple-macosx/release/Mokusei \
    --runtime .build/go/mokusei-runtime \
    --source-profile "$HOME/Library/Application Support/Mokusei Native Dev" \
    --workdir /private/tmp/mokusei-pan --label release --pairs 3 --enforce
"""
import argparse
import json
import math
import os
import platform
import shutil
import socket
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from pathlib import Path

SOURCE = Path(__file__).resolve().parent
ROOT = SOURCE.parents[2]
FRAME_TABLES = ["hitches-frame-lifetimes", "hitches-renders", "hitches"]
DEFAULT_CONDITIONS = [
    {"label": "all", "filterId": None},
    {"label": "yanbao", "filterId": "semantic:inbox:研报"},
]
# Goal for the two real-data conditions: dragging must not cost more with many
# cards than with one. Regression limits compare a candidate against the
# retained baseline instead of against the sibling condition.
TARGET = {"panP50Ratio": 1.1, "framesRatio": 0.95, "cpuRatio": 1.5}
REGRESSION = {"panP50": 1.15, "framesPerSecond": 0.95, "cpuMean": 1.15}


class Failed(SystemExit):
    pass


def fail(message):
    raise Failed(f"FAILED {message}")


# ---------------------------------------------------------------- profiles

def clone_profile(source, destination):
    """Consistent copy: SQLite backup for the store, clone copies for the rest."""
    source, destination = Path(source), Path(destination)
    state = source / "mokusei-go-state-v1"
    if not (state / "state.sqlite").is_file():
        fail(f"no store in {source}")
    if destination.exists():
        shutil.rmtree(destination)
    (destination / "mokusei-go-state-v1").mkdir(parents=True)
    subprocess.run(["sqlite3", "-readonly", str(state / "state.sqlite"),
                    f".backup {destination / 'mokusei-go-state-v1' / 'state.sqlite'}"], check=True)
    for name in ("harnesses", "attachments", "search-models"):
        if (state / name).is_dir():
            subprocess.run(["cp", "-cR", str(state / name), str(destination / "mokusei-go-state-v1")], check=True)
    for name in ("managed-worktrees.json", "moku-telemetry-ledgers"):
        entry = state / name
        if entry.exists():
            subprocess.run(["cp", "-cR", str(entry), str(destination / "mokusei-go-state-v1")], check=True)
    for name in ("client-drafts", "client-reading-cache", "desktop-preferences.json",
                 "client-command-journal.json"):
        entry = source / name
        if entry.exists():
            subprocess.run(["cp", "-cR", str(entry), str(destination)], check=True)
    return destination


def launch(app, runtime, data_dir, sock, log):
    app = Path(app).resolve()
    if app.is_dir():
        binaries = sorted((app / "Contents" / "MacOS").iterdir())
        binary = next((candidate for candidate in binaries if candidate.name == "Mokusei"), binaries[0])
        args = [str(binary)]
    else:
        args = [str(app)]
    if runtime:
        args += ["--runtime", str(Path(runtime).resolve())]
    args += ["--data-dir", str(data_dir), "--automation-socket", str(sock)]
    handle = open(log, "w")
    process = subprocess.Popen(args, stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
    return process, handle


# ---------------------------------------------------------------- client

class Client:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(30)
        self.socket.connect(path)
        self.reader = self.socket.makefile("rb")
        self.sequence = 0

    def call(self, action=None, snapshot=True):
        self.sequence += 1
        request = {"protocol": 1, "id": str(self.sequence), "op": "snapshot" if action is None else "perform"}
        if action is not None:
            request["action"] = action
            # A drag produces no per-update snapshot in the product, so the
            # measurement must not charge one either.
            if not snapshot:
                request["snapshot"] = False
        started = time.monotonic()
        self.socket.sendall(json.dumps(request, ensure_ascii=False).encode() + b"\n")
        line = self.reader.readline(2 * 1024 * 1024 + 1)
        if not line.endswith(b"\n"):
            fail("automation connection closed")
        return json.loads(line), (time.monotonic() - started) * 1000


def wait_ready(client, seconds=90):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        snapshot = client.call()[0].get("snapshot")
        if snapshot and snapshot.get("page") == "overview" and snapshot.get("runtimeAvailable"):
            overview = snapshot["overview"]
            if overview["cards"] and not overview["layingOut"]:
                return
        time.sleep(0.2)
    fail("overview did not become ready")


def settle(client, filter_id, seconds=20):
    client.call({"name": "overview.auto"})
    time.sleep(0.4)
    response = client.call({"name": "filter.select", "filterId": filter_id})[0]
    if not response.get("ok"):
        fail(f"filter.select rejected: {response.get('error')}")
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        overview = client.call()[0]["snapshot"]["overview"]
        count = len(overview["cards"])
        stable = (count > 0 and len(overview["mountedCardIds"]) == count
                  and len(overview["placements"]) == count and not overview["layingOut"]
                  and not overview["camera"]["animating"] and overview["stage"] is None
                  and not overview["camera"]["motionPending"] and not overview["camera"]["automaticFitPending"])
        if stable:
            return count
        time.sleep(0.05)
    fail("filter did not settle")


def pan_delta(index, period):
    t = index * period
    return 1.6 * math.cos(t * 2.4), 1.1 * math.sin(t * 2.4)


def pan(client, delta_x, delta_y):
    response = client.call({"name": "overview.pan", "deltaX": delta_x, "deltaY": delta_y}, snapshot=False)[0]
    if not response.get("ok"):
        fail(f"overview.pan rejected: {response.get('error')}")


def service_cost(client, seconds=3.0):
    """Main-actor cost of one camera update. Driven faster than any display can."""
    latencies = []
    started = time.monotonic()
    index = 0
    while time.monotonic() - started < seconds:
        index += 1
        delta_x, delta_y = pan_delta(index, 1 / 120)
        _, ms = client.call({"name": "overview.pan", "deltaX": delta_x, "deltaY": delta_y}, snapshot=False)
        latencies.append(ms)
    return latencies, index / (time.monotonic() - started)


# ---------------------------------------------------------------- compositor

def resolve(root):
    ids = {}
    for element in root.iter():
        identifier = element.get("id")
        if identifier is not None:
            ids[identifier] = element

    def value(cell):
        target = cell
        for _ in range(4):
            reference = target.get("ref")
            if reference is None or reference not in ids:
                break
            target = ids[reference]
        if target.text is None:
            return None
        try:
            return float(target.text)
        except ValueError:
            return target.text.strip()

    schema = root.find("node/schema")
    names = [column.findtext("mnemonic") for column in schema.findall("col")]
    rows = []
    for row in root.iter("row"):
        rows.append({name: value(cell) for name, cell in zip(names, list(row))})
    return rows


def export_table(trace, table):
    completed = subprocess.run(
        ["xcrun", "xctrace", "export", "--input", str(trace), "--xpath",
         f'/trace-toc/run[@number="1"]/data/table[@schema="{table}"]'],
        capture_output=True, text=True)
    if completed.returncode != 0 or not completed.stdout.strip():
        return []
    return resolve(ET.fromstring(completed.stdout))


def percentile(values, share):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(round(share / 100 * len(ordered))) - 1))]


def compositor(process, client, drag, rate, trace):
    """Record frames while the canvas is dragged for the whole recorded window."""
    subprocess.run(["rm", "-rf", str(trace)], check=False)
    recorder = subprocess.Popen(
        ["xcrun", "xctrace", "record", "--template", "Animation Hitches",
         "--attach", str(process.pid), "--time-limit", f"{int(round(drag))}s", "--output", str(trace)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    stop = {"value": False}
    cpu = []

    def poll():
        while not stop["value"]:
            out = subprocess.run(["ps", "-o", "%cpu=", "-p", str(process.pid)],
                                 capture_output=True, text=True).stdout.strip()
            if out:
                cpu.append(float(out))
            time.sleep(0.25)

    watcher = threading.Thread(target=poll, daemon=True)
    watcher.start()
    # Drive past the recording window so every recorded frame belongs to a drag.
    period = 1 / rate
    started = time.monotonic()
    index = 0
    while time.monotonic() - started < drag + 2.5:
        target = started + index * period
        wait = target - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        index += 1
        pan(client, *pan_delta(index, period))
    stop["value"] = True
    recorder.wait(timeout=180)
    before = client.call()[0]["snapshot"]["overview"]["camera"]
    if not Path(trace).is_dir():
        fail("trace was not written")
    frames, renders, hitches = (export_table(trace, table) for table in FRAME_TABLES)
    starts_by_surface = {}
    lifetimes = []
    for row in frames:
        duration = row.get("duration")
        if isinstance(duration, float) and duration > 0:
            starts_by_surface.setdefault(row.get("surface-id"), []).append(row.get("start") or 0)
            lifetimes.append(duration / 1e6)
    intervals = []
    surfaces = {}
    for surface, starts in starts_by_surface.items():
        starts.sort()
        if len(starts) < 8:
            continue
        deltas = [(b - a) / 1e6 for a, b in zip(starts, starts[1:])]
        surfaces[str(int(surface))] = {"frames": len(starts), "p50": round(percentile(deltas, 50), 2),
                                       "p95": round(percentile(deltas, 95), 2), "max": round(max(deltas), 2)}
        intervals.extend(deltas)
    if not intervals:
        fail("no composed frames captured")
    nominal = percentile(intervals, 50)
    span = max(max(starts) for starts in starts_by_surface.values()) - min(
        min(starts) for starts in starts_by_surface.values())
    return {
        "frames": len(lifetimes),
        "framesPerSecond": round(len(lifetimes) / (span / 1e9), 1),
        "intervalP50": round(nominal, 2),
        "intervalP95": round(percentile(intervals, 95), 2),
        "intervalMax": round(max(intervals), 2),
        "longIntervalRatio": round(sum(1 for value in intervals if value > nominal * 1.5) / len(intervals), 4),
        "lifetimeP50": round(percentile(lifetimes, 50), 2),
        "lifetimeP95": round(percentile(lifetimes, 95), 2),
        "renderP50": round(percentile([r["duration"] / 1e6 for r in renders
                                       if isinstance(r.get("duration"), float)], 50), 2),
        "hitches": len(hitches),
        "hitchRatio": round(sum(h["duration"] for h in hitches
                                if isinstance(h.get("duration"), float)) / 1e9 / (span / 1e9), 4),
        "cpuMean": round(sum(cpu) / len(cpu), 1) if cpu else None,
        "cpuMax": max(cpu) if cpu else None,
        "surfaces": surfaces,
        "camera": {"x": before["x"], "y": before["y"]},
    }


# ---------------------------------------------------------------- conditions

def condition(process, client, spec, drag, rate, trace):
    cards = settle(client, spec["filterId"])
    before = client.call()[0]["snapshot"]["overview"]["camera"]
    latencies, absorption = service_cost(client)
    frames = compositor(process, client, drag, rate, trace)
    after = client.call()[0]["snapshot"]["overview"]["camera"]
    client.call({"name": "overview.auto"})
    moved = abs(after["x"] - before["x"]) + abs(after["y"] - before["y"])
    if moved < 20:
        fail(f"{spec['label']}: camera barely moved ({moved:.1f}px)")
    return {
        "label": spec["label"],
        "filterId": spec["filterId"],
        "cards": cards,
        "panP50": round(percentile(latencies, 50), 2),
        "panP95": round(percentile(latencies, 95), 2),
        "panAbsorption": round(absorption, 1),
        "cameraMovedPx": round(moved, 1),
        **frames,
    }


def median(values):
    ordered = sorted(values)
    return ordered[len(ordered) // 2]


def summarize(results, conditions):
    summary = {}
    for spec in conditions:
        rows = [r for r in results if r["label"] == spec["label"]]
        entry = {}
        for key in ("panP50", "panP95", "framesPerSecond", "intervalP95", "longIntervalRatio",
                    "hitchRatio", "cpuMean", "cpuMax", "renderP50"):
            values = [r[key] for r in rows if r.get(key) is not None]
            entry[key] = round(median(values), 3) if values else None
        entry["cards"] = rows[0]["cards"]
        entry["runs"] = len(rows)
        summary[spec["label"]] = entry
    return summary


def regression(summary, baseline):
    """Worst per-condition change against the retained baseline."""
    worst = {}
    for label, row in summary.items():
        retained = baseline.get("summary", {}).get(label)
        if not retained:
            continue
        if retained.get("cards") != row.get("cards"):
            fail(f"{label}: card count changed from {retained.get('cards')} to {row.get('cards')}")
        worst[label] = {
            "panP50": round(row["panP50"] / retained["panP50"], 3) if retained.get("panP50") else None,
            "framesPerSecond": round(row["framesPerSecond"] / retained["framesPerSecond"], 3)
            if retained.get("framesPerSecond") else None,
            "cpuMean": round(row["cpuMean"] / retained["cpuMean"], 3) if retained.get("cpuMean") else None,
        }
    return worst


def compare(summary, conditions):
    if len(conditions) != 2:
        return {}
    wide, narrow = (summary[c["label"]] for c in conditions)
    return {key: round(wide[key] / narrow[key], 3) if narrow.get(key) else None
            for key in ("panP50", "framesPerSecond", "cpuMean")}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="application bundle or raw executable")
    parser.add_argument("--runtime", help="mokusei-runtime for a raw executable")
    parser.add_argument("--data-dir", help="prepared isolated profile")
    parser.add_argument("--source-profile", help="clone this profile into <workdir>/profile first")
    parser.add_argument("--workdir", default="/private/tmp/mokusei-overview-pan")
    parser.add_argument("--label", default="release")
    parser.add_argument("--pairs", type=int, default=3)
    parser.add_argument("--drag", type=float, default=4.0)
    parser.add_argument("--rate", type=float, default=120.0)
    parser.add_argument("--conditions", help="JSON list of {label, filterId}")
    parser.add_argument("--report", help="write the full JSON report here")
    parser.add_argument("--baseline", help="compare against this retained baseline")
    parser.add_argument("--enforce", choices=["none", "target", "regression", "both"], default="none",
                        help="target: A/B ratios approach 1; regression: stay within the retained baseline")
    parser.add_argument("--keep", action="store_true", help="leave the launched app running")
    args = parser.parse_args()

    workdir = Path(args.workdir)
    workdir.mkdir(parents=True, exist_ok=True)
    os.chmod(workdir, 0o700)
    if args.source_profile:
        data_dir = clone_profile(args.source_profile, workdir / "profile")
    elif args.data_dir:
        data_dir = Path(args.data_dir)
    else:
        fail("either --data-dir or --source-profile is required")
    socket_path = workdir / "ui.sock"
    if socket_path.exists():
        socket_path.unlink()

    conditions = DEFAULT_CONDITIONS
    if args.conditions:
        conditions = json.loads(args.conditions) if args.conditions.strip().startswith("[") \
            else json.loads(Path(args.conditions).read_text())

    process, log = launch(args.app, args.runtime, data_dir, socket_path, workdir / "app.log")
    results = []
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and not socket_path.exists():
            if process.poll() is not None:
                fail(f"app exited: {(workdir / 'app.log').read_text()[-400:]}")
            time.sleep(0.2)
        client = Client(str(socket_path))
        wait_ready(client)
        for pair in range(args.pairs):
            order = conditions if pair % 2 == 0 else list(reversed(conditions))
            for spec in order:
                result = condition(process, client, spec, args.drag, args.rate,
                                   workdir / f"pan-{spec['label']}-p{pair}.trace")
                result["pair"] = pair
                results.append(result)
                print(json.dumps({k: v for k, v in result.items() if k != "surfaces"},
                                 ensure_ascii=False), flush=True)
    finally:
        if not args.keep:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
        log.close()

    summary = summarize(results, conditions)
    ratios = compare(summary, conditions)
    report = {
        "label": args.label,
        "commit": subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                                 capture_output=True, text=True).stdout.strip(),
        "machine": {"model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True,
                                            text=True).stdout.strip(),
                    "os": platform.mac_ver()[0], "python": platform.python_version()},
        "conditions": conditions,
        "dragSeconds": args.drag,
        "ratePerSecond": args.rate,
        "summary": summary,
        "ratios": ratios,
        "results": results,
    }
    print("\n== medians ==")
    for label, row in summary.items():
        print(f"{label:10s} cards={row['cards']:3d} panP50={row['panP50']:7.2f}ms "
              f"frames/s={row['framesPerSecond']:6.1f} p95={row['intervalP95']:6.2f}ms "
              f"cpu={row['cpuMean']:5.1f}%")
    if ratios:
        print(f"== A/B ratios == pan={ratios['panP50']} frames={ratios['framesPerSecond']} cpu={ratios['cpuMean']}")
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=1) + "\n")
    if args.enforce in ("regression", "both"):
        if not args.baseline:
            fail("--enforce regression needs --baseline")
        retained = json.loads(Path(args.baseline).read_text())
        print("== vs baseline ==")
        for label, change in regression(summary, retained).items():
            print(f"{label:10s} panP50={change['panP50']} frames={change['framesPerSecond']} cpu={change['cpuMean']}")
            if (change["panP50"] or 0) > REGRESSION["panP50"]:
                fail(f"{label}: panP50 regressed to {change['panP50']}x of baseline")
            if (change["framesPerSecond"] or 1) < REGRESSION["framesPerSecond"]:
                fail(f"{label}: frames/s regressed to {change['framesPerSecond']}x of baseline")
            if (change["cpuMean"] or 0) > REGRESSION["cpuMean"]:
                fail(f"{label}: CPU regressed to {change['cpuMean']}x of baseline")
    if args.enforce in ("target", "both"):
        if ratios.get("panP50") is None or ratios["panP50"] > TARGET["panP50Ratio"]:
            fail(f"panP50 A/B ratio {ratios.get('panP50')} > {TARGET['panP50Ratio']}")
        if ratios["framesPerSecond"] < TARGET["framesRatio"]:
            fail(f"frames A/B ratio {ratios['framesPerSecond']} < {TARGET['framesRatio']}")
        if ratios["cpuMean"] > TARGET["cpuRatio"]:
            fail(f"cpu A/B ratio {ratios['cpuMean']} > {TARGET['cpuRatio']}")
    print(f"PASS Overview pan measurement ({args.label}, {args.pairs} pairs)")


if __name__ == "__main__":
    main()
