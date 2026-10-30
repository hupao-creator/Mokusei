"""Extract the report's key metrics from the raw Overview scale evidence."""
import argparse
import glob
import json
from pathlib import Path
import statistics


def load(path):
    return json.loads(Path(path).read_text())


def files(root, pattern):
    return sorted(path for path in glob.glob(str(root / pattern)) if not path.endswith(".run.json"))


def med(values):
    return statistics.median(values) if values else None


def r(value, digits=3):
    return round(value, digits) if value is not None else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    out = {}

    idle_paths = (files(root, "raw/gui/idle-*.json") + files(root, "raw/gui/profile-idle-*.json")
                  + files(root, "raw/gui/diag-idle-*.json"))
    idle = []
    for path in dict.fromkeys(idle_paths):
        data = load(path)
        value = data["idle"]
        diagnostics = value.get("diagnostics") or {}
        idle.append({"file": Path(path).name, "n": data["n"],
                     "cpuPercent": r(value["processCPUPercent"], 2),
                     "seconds": r(value["seconds"], 1),
                     "physicalFootprintMB": r(value["end"]["physicalFootprintBytes"] / 1e6, 1),
                     "wakeups": value["wakeups"],
                     "visibleFull": (value.get("fixedCamera") or {}).get("visibleFull"),
                     "visiblePartial": (value.get("fixedCamera") or {}).get("visiblePartial"),
                     "shellTicks": diagnostics.get("shellTicks"),
                     "semanticTicks": diagnostics.get("semanticTicks"),
                     "motionSamples": diagnostics.get("motionSamples"),
                     "canvasBodies": diagnostics.get("canvasBodies"),
                     "invalid": data.get("invalidReasons", []),
                     "active": (data.get("activation") or {}).get("active"),
                     "key": (data.get("activation") or {}).get("key")})
    out["idle"] = idle

    updates = []
    for path in files(root, "raw/gui/update-*.json"):
        data = load(path)
        value = data.get("update")
        if not value:
            continue
        wall = value["end"]["unix"] - value["start"]["unix"]
        updates.append({"file": Path(path).name, "n": data["n"],
                        "sequence": value.get("sequence") or "content",
                        "target": value.get("target"), "hz": value.get("hz"),
                        "measured": value.get("measuredUpdates"),
                        "wallSeconds": r(wall, 1),
                        "rateHz": r(value["measuredUpdates"] / wall, 2),
                        "medianMs": r(value["timeStats"]["medianMs"], 2),
                        "p95Ms": r(value["timeStats"]["p95Ms"], 2),
                        "cpuPercent": r(value["processCPUPercent"], 2),
                        "latenessMedianMs": r(value["latenessStats"]["medianMs"], 2),
                        "latenessMaxMs": r(value["latenessStats"]["maxMs"], 2),
                        "invalid": data.get("invalidReasons", [])})
    out["updates"] = updates

    diag_updates = []
    for path in files(root, "raw/gui/diag-update-*.json"):
        data = load(path)
        value = data.get("update")
        if not value:
            continue
        before, after = value.get("diagnosticsBefore", {}), value.get("diagnostics", {})
        measured = value["measuredUpdates"]
        per_update = {}
        for key in ["canvasBodies", "shellCardBuilds", "semanticCardBuilds", "shellTicks",
                    "semanticTicks", "itemsChanges", "harnessProjectionMisses",
                    "harnessProjectionHits", "pruneCalls"]:
            per_update[key] = r((after.get(key, 0) - before.get(key, 0)) / measured, 2)
        diag_updates.append({"file": Path(path).name, "n": data["n"],
                             "sequence": value.get("sequence") or "content",
                             "measured": measured, "perUpdate": per_update,
                             "snapshotCount": after.get("snapshotCount"),
                             "harnessCacheCount": after.get("harnessCacheCount")})
    out["diagUpdates"] = diag_updates

    motion = []
    for path in files(root, "raw/gui/*motion-*.json"):
        data = load(path)
        value = data.get("motion")
        if not value:
            continue
        diagnostics = value.get("diagnostics") or {}
        motion.append({"file": Path(path).name, "n": data["n"], "scenario": value.get("scenario"),
                       "settledMs": r(value.get("settledMs"), 1) if value.get("settledMs") else None,
                       "expectedPolicyWaitSeconds": value.get("expectedPolicyWaitSeconds"),
                       "cpuSeconds": r(value.get("cpuSeconds"), 2),
                       "modelReturnedMs": r(value.get("modelReturnedMs"), 2),
                       "firstLayingOutMs": r(value.get("firstLayingOutMs"), 1) if value.get("firstLayingOutMs") else None,
                       "mountedAfter": value.get("mountedAfter"), "placementsAfter": value.get("placementsAfter"),
                       "cameraSubmissions": value.get("cameraSubmissions"),
                       "processCPUPercent": r(value.get("processCPUPercent"), 1),
                       "latenessMedianMs": r(med(value.get("latenessMs") or []), 1),
                       "motionStarts": diagnostics.get("motionStarts"),
                       "motionSamples": diagnostics.get("motionSamples"),
                       "zeroTravelSamples": diagnostics.get("zeroTravelSamples"),
                       "shellTicks": diagnostics.get("shellTicks"),
                       "semanticTicks": diagnostics.get("semanticTicks"),
                       "canvasBodies": diagnostics.get("canvasBodies"),
                       "shellCardBuilds": diagnostics.get("shellCardBuilds"),
                       "semanticCardBuilds": diagnostics.get("semanticCardBuilds"),
                       "invalid": data.get("invalidReasons", [])})
    out["motion"] = motion

    layout = []
    path = root / "raw/layout/layout.json"
    if path.exists():
        for record in load(path)["records"]:
            if record["scenario"].split("-")[0] in {"initial", "insert", "delete", "grow", "shrink", "content", "mixed", "resize"}:
                work = record.get("work") or {}
                layout.append({"scenario": record["scenario"], "n": record["n"],
                               "medianMs": r(record.get("timeStats", {}).get("medianMs"), 3),
                               "steps": work.get("steps"), "candidateSteps": work.get("candidateSteps"),
                               "searchComplete": work.get("searchComplete"),
                               "requiresRepack": work.get("requiresRepack"),
                               "shifted": work.get("shifted"), "moveOrder": work.get("moveOrder")})
    out["layout"] = layout

    layout_diag = []
    path = root / "raw/layout/layout-diag.json"
    if path.exists():
        for record in load(path)["records"]:
            if record["scenario"].split("-")[0] in {"initial", "insert", "delete", "grow", "shrink"}:
                work = record.get("work") or {}
                layout_diag.append({"scenario": record["scenario"], "n": record["n"],
                                    "medianMs": r(record.get("timeStats", {}).get("medianMs"), 2),
                                    "steps": work.get("steps"), "candidateSteps": work.get("candidateSteps"),
                                    "searchComplete": work.get("searchComplete"),
                                    "requiresRepack": work.get("requiresRepack"),
                                    "diagnostics": record.get("diagnostics")})
    out["layoutDiag"] = layout_diag

    first = []
    for n in (10, 40, 100, 500):
        rows = []
        for path in files(root, f"raw/gui/first-load-{n}-r*.json"):
            data = load(path)
            value = data["firstLoad"]
            rows.append((value["installMs"], value["settle"]["firstLayoutMs"],
                         value["settle"]["allMountedMs"], value["settle"]["settleMs"],
                         value["resource"]["physicalFootprintBytes"] / 1e6))
        if rows:
            first.append({"n": n, "installMs": [r(v[0], 2) for v in rows],
                          "firstLayoutMs": [r(v[1], 1) for v in rows],
                          "allMountedMs": [r(v[2], 1) for v in rows],
                          "settleMs": [r(v[3], 1) for v in rows],
                          "physicalFootprintMB": [r(v[4], 1) for v in rows]})
    out["firstLoad"] = first

    diag_first = []
    for n in (100, 500):
        path = root / f"raw/gui/diag-first-load-{n}.json"
        if not path.exists():
            continue
        data = load(path)
        settle = data["firstLoad"]["settle"]
        diagnostics = data.get("diagnostics") or {}
        diag_first.append({"n": n, "firstLayoutMs": r(settle["firstLayoutMs"], 1),
                           "allMountedMs": r(settle["allMountedMs"], 1),
                           "settleMs": r(settle["settleMs"], 1),
                           "layoutSolveCount": settle.get("layoutSolveCount"),
                           "canvasBodies": diagnostics.get("canvasBodies"),
                           "shellCardBuilds": diagnostics.get("shellCardBuilds"),
                           "semanticCardBuilds": diagnostics.get("semanticCardBuilds"),
                           "shellTicks": diagnostics.get("shellTicks"),
                           "semanticTicks": diagnostics.get("semanticTicks"),
                           "projectionMisses": diagnostics.get("harnessProjectionMisses"),
                           "projectionHits": diagnostics.get("harnessProjectionHits")})
    out["diagFirstLoad"] = diag_first

    model = {}
    for n in (0, 5, 10, 40, 100, 500):
        rows = []
        for path in files(root, f"raw/model/model-{n}-r*.json"):
            rows += [record for record in load(path)["records"] if record.get("attempt") == 0]
        def values(scenario, key):
            result = []
            for record in rows:
                if scenario == "k1":
                    if not str(record.get("scenario", "")).startswith("k1-latency"):
                        continue
                elif record.get("scenario") != scenario:
                    continue
                value = record.get(key)
                if isinstance(value, list):
                    result += value
                elif isinstance(value, (int, float)):
                    result.append(value)
            return result
        def summary(scenario, key):
            values_ = values(scenario, key)
            return {"median": r(med(values_), 3), "min": r(min(values_), 3) if values_ else None,
                    "max": r(max(values_), 3) if values_ else None, "count": len(values_)}
        model[str(n)] = {"firstInstall": summary("first-install", "elapsedMs"),
                         "firstReceive": summary("first-install", "receiveMs"),
                         "warmInstall": summary("warm-install", "elapsedMs"),
                         "k1": summary("k1", "elapsedMs"), "k1Receive": summary("k1", "receiveMs"),
                         "k0": summary("k0-latency", "elapsedMs")}
    out["model"] = model

    runtime = {}
    for n in (10, 40, 100, 500):
        rows = []
        for path in files(root, f"raw/runtime/runtime-{n}-r*.json"):
            rows += load(path)["records"]
        def arr(key):
            result = []
            for record in rows:
                value = record.get(key)
                if isinstance(value, list):
                    result += value
            return result
        runtime[str(n)] = {
            "snapshotKB": r(med([record.get("snapshotBytes", 0) for record in rows]) / 1024, 1),
            "mutationBytes": med([record.get("mutationBytes", 0) for record in rows]),
            "snapshotParseMs": r(med([record.get("snapshotParseStats", {}).get("medianMs") for record in rows]), 4),
            "mutationParseMs": r(med([record.get("mutationParseStats", {}).get("medianMs") for record in rows]), 4),
            "applyMs": r(med([record.get("applyStats", {}).get("medianMs") for record in rows]), 4),
            "acceptMs": r(med(arr("acceptMs")), 4), "installMs": r(med(arr("installMs")), 4),
            "receiveMs": r(med(arr("receiveMs")), 4),
            "totalMs": r(med([record.get("totalStats", {}).get("medianMs") for record in rows]), 4)}
    out["runtime"] = runtime

    profile = []
    for path in files(root, "raw/gui/profile-idle-*.json"):
        data = load(path)
        profile.append({"file": Path(path).name, "n": data["n"],
                        "cpuPercent": r(data["idle"]["processCPUPercent"], 2),
                        "seconds": r(data["idle"]["seconds"], 1),
                        "visibleFull": data["idle"]["fixedCamera"].get("visibleFull"),
                        "visiblePartial": data["idle"]["fixedCamera"].get("visiblePartial")})
    out["profileIdle"] = profile

    target = root / "summary/key-metrics.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(out, indent=2))
    print("wrote", target)


if __name__ == "__main__":
    main()
