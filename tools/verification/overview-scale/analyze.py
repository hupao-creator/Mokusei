"""Summarize Overview scale evidence. Raw samples stay untouched."""
import argparse
import csv
import glob
import json
from pathlib import Path
import statistics


def median(values):
    return statistics.median(values) if values else None


def p95(values):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(0.95 * (len(ordered) - 1))))]


def load(path):
    return json.loads(Path(path).read_text())


def find(root, pattern):
    return sorted(path for path in glob.glob(str(root / pattern)) if not path.endswith(".run.json"))


def write_csv(path, rows, fields):
    with open(path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def model_summary(root):
    rows = []
    for path in find(root, "raw/model/model-*.json"):
        data = load(path)
        n = data["n"]
        for record in data["records"]:
            scenario = record["scenario"]
            if scenario in ("first-install", "warm-install"):
                rows.append({"n": n, "scenario": scenario, "attempt": record.get("attempt"),
                             "process": Path(path).name,
                             "medianMs": median(record.get("elapsedMs", [])),
                             "receiveMedianMs": median(record.get("receiveMs", [])),
                             "membershipBuilds": record.get("membershipBuilds"),
                             "items": record.get("items"),
                             "structuralIdentityChanged": record.get("structuralIdentityChanged"),
                             "changedPresentations": median(record.get("changedPresentations", []))})
            elif scenario.startswith("k1-latency") or scenario == "k0-latency":
                samples = record.get("elapsedMs", [])
                receives = record.get("receiveMs", [])
                rows.append({"n": n, "scenario": scenario, "attempt": record.get("attempt"),
                             "process": Path(path).name, "target": record.get("target"),
                             "count": len(samples), "medianMs": median(samples), "p95Ms": p95(samples),
                             "receiveMedianMs": median(receives), "receiveP95Ms": p95(receives),
                             "membershipBuilds": record.get("membershipBuilds"),
                             "structuralIdentityChanged": record.get("structuralIdentityChanged"),
                             "changedPresentations": median(record.get("changedPresentations", []))})
            elif scenario == "k1-clock":
                late = record.get("latenessMs", [])
                rows.append({"n": n, "scenario": scenario, "attempt": record.get("attempt"),
                             "process": Path(path).name, "hz": record.get("hz"),
                             "medianMs": median(record.get("elapsedMs", [])),
                             "p95Ms": p95(record.get("elapsedMs", [])),
                             "latenessMedianMs": median(late), "latenessP95Ms": p95(late),
                             "latenessMaxMs": max(late) if late else None})
    return rows


def runtime_summary(root):
    rows = []
    for path in find(root, "raw/runtime/runtime-*.json"):
        data = load(path)
        n = data["n"]
        for record in data["records"]:
            rows.append({
                "n": n, "process": Path(path).name,
                "snapshotBytes": record.get("snapshotBytes"), "mutationBytes": record.get("mutationBytes"),
                "snapshotParseMs": record.get("snapshotParseStats", {}).get("medianMs"),
                "mutationParseMs": record.get("mutationParseStats", {}).get("medianMs"),
                "applyMs": record.get("applyStats", {}).get("medianMs"),
                "acceptMs": median(record.get("acceptMs", [])),
                "waitMs": median(record.get("waitMs", [])),
                "installMs": median(record.get("installMs", [])),
                "receiveMs": median(record.get("receiveMs", [])),
                "totalMs": record.get("totalStats", {}).get("medianMs"),
                "totalP95Ms": record.get("totalStats", {}).get("p95Ms")})
    return rows


def layout_summary(root):
    rows = []
    for path in find(root, "raw/layout/layout*.json"):
        data = load(path)
        for record in data["records"]:
            work = record.get("work") or {}
            diagnostics = record.get("diagnostics") or {}
            rows.append({"file": Path(path).name, "scenario": record["scenario"], "n": record["n"],
                         "medianMs": record.get("timeStats", {}).get("medianMs"),
                         "p95Ms": record.get("timeStats", {}).get("p95Ms"),
                         "steps": work.get("steps"), "candidateSteps": work.get("candidateSteps"),
                         "searchComplete": work.get("searchComplete"), "requiresRepack": work.get("requiresRepack"),
                         "moveOrder": work.get("moveOrder"), "shifted": work.get("shifted"),
                         "validatePairs": diagnostics.get("validatePairs"),
                         "intersectCalls": diagnostics.get("intersectCalls"),
                         "straightPairs": diagnostics.get("straightPairs"),
                         "visibleFull": record.get("visibleFull"), "visiblePartial": record.get("visiblePartial"),
                         "visibleAreaFill": record.get("visibleAreaFill"), "error": record.get("error")})
    return rows


def gui_summary(root):
    idle, update, motion, first = [], [], [], []
    for path in (find(root, "raw/gui/idle-*.json") + find(root, "raw/gui/profile-idle-*.json")):
        data = load(path)
        idle_value = data.get("idle", {})
        diagnostics = idle_value.get("diagnostics", {}) or {}
        n = data.get("n")
        idle.append({"file": Path(path).name, "n": n, "running": data.get("label") or Path(path).stem,
                     "seconds": idle_value.get("seconds"),
                     "cpuPercent": idle_value.get("processCPUPercent"),
                     "interruptWakeups": idle_value.get("wakeups", {}).get("interrupt"),
                     "platformIdleWakeups": idle_value.get("wakeups", {}).get("platformIdle"),
                     "timerWakeups": idle_value.get("wakeups", {}).get("timer"),
                     "residentBytes": idle_value.get("end", {}).get("residentBytes"),
                     "physicalFootprintBytes": idle_value.get("end", {}).get("physicalFootprintBytes"),
                     "shellTicks": diagnostics.get("shellTicks"),
                     "semanticTicks": diagnostics.get("semanticTicks"),
                     "motionSamples": diagnostics.get("motionSamples"),
                     "invalid": ",".join(data.get("invalidReasons", [])),
                     "fixedFull": data.get("fixedCamera", {}).get("visibleFull"),
                     "fixedPartial": data.get("fixedCamera", {}).get("visiblePartial")})
    for path in find(root, "raw/gui/update-*.json"):
        data = load(path)
        value = data.get("update", {})
        diagnostics_before = value.get("diagnosticsBefore", {}) or {}
        diagnostics_after = value.get("diagnostics", {}) or {}
        counters_before = data.get("countersBefore", {}) or {}
        counters_after = data.get("countersAfter", {}) or {}
        update.append({"file": Path(path).name, "n": data.get("n"), "target": value.get("target"),
                       "sequence": value.get("sequence") or "content", "hz": value.get("hz"),
                       "measured": value.get("measuredUpdates"),
                       "medianMs": value.get("timeStats", {}).get("medianMs"),
                       "p95Ms": value.get("timeStats", {}).get("p95Ms"),
                       "receiveMedianMs": value.get("receiveStats", {}).get("medianMs"),
                       "latenessMedianMs": value.get("latenessStats", {}).get("medianMs"),
                       "latenessP95Ms": value.get("latenessStats", {}).get("p95Ms"),
                       "latenessMaxMs": value.get("latenessStats", {}).get("maxMs"),
                       "cpuPercent": value.get("processCPUPercent"),
                       "layoutSolveDelta": (counters_after.get("layoutSolveCount") or 0) - (counters_before.get("layoutSolveCount") or 0),
                       "geometryReuseDelta": (counters_after.get("geometryReuseCount") or 0) - (counters_before.get("geometryReuseCount") or 0),
                       "mounted": counters_after.get("mounted"),
                       "changed": diagnostics_after.get("itemsChanges"),
                       "shellTicks": (diagnostics_after.get("shellTicks") or 0) - (diagnostics_before.get("shellTicks") or 0),
                       "semanticTicks": (diagnostics_after.get("semanticTicks") or 0) - (diagnostics_before.get("semanticTicks") or 0),
                       "canvasBodies": (diagnostics_after.get("canvasBodies") or 0) - (diagnostics_before.get("canvasBodies") or 0),
                       "shellBuilds": (diagnostics_after.get("shellCardBuilds") or 0) - (diagnostics_before.get("shellCardBuilds") or 0),
                       "semanticBuilds": (diagnostics_after.get("semanticCardBuilds") or 0) - (diagnostics_before.get("semanticCardBuilds") or 0),
                       "projectionMisses": (diagnostics_after.get("harnessProjectionMisses") or 0) - (diagnostics_before.get("harnessProjectionMisses") or 0),
                       "projectionHits": (diagnostics_after.get("harnessProjectionHits") or 0) - (diagnostics_before.get("harnessProjectionHits") or 0),
                       "snapshotCount": diagnostics_after.get("snapshotCount"),
                       "invalid": ",".join(data.get("invalidReasons", [])),
                       "fixedFull": value.get("fixedCamera", {}).get("visibleFull"),
                       "fixedPartial": value.get("fixedCamera", {}).get("visiblePartial")})
    for path in find(root, "raw/gui/motion-*.json"):
        data = load(path)
        value = data.get("motion", {})
        motion.append({"file": Path(path).name, "n": data.get("n"), "scenario": value.get("scenario"),
                       "settledMs": value.get("settledMs"), "expectedSeconds": value.get("expectedPolicyWaitSeconds"),
                       "modelReturnedMs": value.get("modelReturnedMs"),
                       "latenessMedianMs": median(value.get("wakeLatenessMs", [])),
                       "latenessMaxMs": max(value.get("wakeLatenessMs", [])) if value.get("wakeLatenessMs") else None,
                       "cpuSeconds": value.get("cpuSeconds"),
                       "cameraSubmissions": value.get("cameraSubmissions"),
                       "mountedAfter": value.get("mountedAfter"), "placementsAfter": value.get("placementsAfter"),
                       "shellTicks": value.get("diagnostics", {}).get("shellTicks"),
                       "semanticTicks": value.get("diagnostics", {}).get("semanticTicks"),
                       "motionSamples": value.get("diagnostics", {}).get("motionSamples"),
                       "zeroTravelSamples": value.get("diagnostics", {}).get("zeroTravelSamples"),
                       "activeMotions": value.get("diagnostics", {}).get("activeMotions"),
                       "invalid": ",".join(data.get("invalidReasons", []))})
    for path in find(root, "raw/gui/first-load-*.json"):
        data = load(path)
        value = data.get("firstLoad", {})
        settle = value.get("settle", {}) or {}
        first.append({"file": Path(path).name, "n": data.get("n"),
                      "installMs": value.get("installMs"),
                      "receiveMs": median(value.get("receiveMs", [])),
                      "firstLayoutMs": settle.get("firstLayoutMs"),
                      "allMountedMs": settle.get("allMountedMs"),
                      "settleMs": settle.get("settleMs"),
                      "firstPixelChangeMs": value.get("firstPixelChangeAfterInstallMs"),
                      "layoutSolveCount": settle.get("layoutSolveCount"),
                      "mounted": settle.get("mounted"),
                      "physicalFootprintBytes": value.get("resource", {}).get("physicalFootprintBytes"),
                      "windowSize": value.get("windowContentSize"),
                      "captureError": data.get("captureError"),
                      "invalid": ",".join(data.get("invalidReasons", []))})
    return idle, update, motion, first


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    summary = root / "summary"
    summary.mkdir(parents=True, exist_ok=True)
    model = model_summary(root)
    runtime = runtime_summary(root)
    layout = layout_summary(root)
    idle, update, motion, first = gui_summary(root)
    write_csv(summary / "model.csv", model, ["n", "scenario", "attempt", "process", "target", "count", "hz",
        "medianMs", "p95Ms", "receiveMedianMs", "receiveP95Ms", "latenessMedianMs", "latenessP95Ms",
        "latenessMaxMs", "membershipBuilds", "items", "structuralIdentityChanged", "changedPresentations"])
    write_csv(summary / "runtime.csv", runtime, ["n", "process", "snapshotBytes", "mutationBytes",
        "snapshotParseMs", "mutationParseMs", "applyMs", "acceptMs", "waitMs", "installMs", "receiveMs",
        "totalMs", "totalP95Ms"])
    write_csv(summary / "layout.csv", layout, ["file", "scenario", "n", "medianMs", "p95Ms", "steps",
        "candidateSteps", "searchComplete", "requiresRepack", "moveOrder", "shifted",
        "validatePairs", "intersectCalls", "straightPairs", "visibleFull", "visiblePartial",
        "visibleAreaFill", "error"])
    write_csv(summary / "gui-idle.csv", idle, ["file", "n", "running", "seconds", "cpuPercent",
        "interruptWakeups", "platformIdleWakeups", "timerWakeups", "residentBytes", "physicalFootprintBytes",
        "shellTicks", "semanticTicks", "motionSamples", "invalid", "fixedFull", "fixedPartial"])
    write_csv(summary / "gui-update.csv", update, ["file", "n", "target", "sequence", "hz", "measured", "medianMs", "p95Ms",
        "receiveMedianMs", "latenessMedianMs", "latenessP95Ms", "latenessMaxMs", "cpuPercent",
        "layoutSolveDelta", "geometryReuseDelta", "mounted", "changed", "shellTicks", "semanticTicks",
        "canvasBodies", "shellBuilds", "semanticBuilds", "projectionMisses", "projectionHits", "snapshotCount",
        "invalid", "fixedFull", "fixedPartial"])
    write_csv(summary / "gui-motion.csv", motion, ["file", "n", "scenario", "settledMs", "expectedSeconds",
        "modelReturnedMs", "latenessMedianMs", "latenessMaxMs", "cpuSeconds", "cameraSubmissions",
        "mountedAfter", "placementsAfter", "shellTicks", "semanticTicks", "motionSamples",
        "zeroTravelSamples", "activeMotions", "invalid"])
    write_csv(summary / "gui-first-load.csv", first, ["file", "n", "installMs", "receiveMs", "firstLayoutMs",
        "allMountedMs", "settleMs", "firstPixelChangeMs", "layoutSolveCount", "mounted",
        "physicalFootprintBytes", "windowSize", "captureError", "invalid"])
    (summary / "summary.json").write_text(json.dumps({"model": model, "runtime": runtime, "layout": layout,
        "idle": idle, "update": update, "motion": motion, "firstLoad": first}, indent=2))
    print("model", len(model), "runtime", len(runtime), "layout", len(layout), "idle", len(idle),
          "update", len(update), "motion", len(motion), "first", len(first))


if __name__ == "__main__":
    main()
