"""Native scroll controls exercise the exact input/capture/analyzer path."""
import json
import os
import time

from analysis.report import seal, write_report
from lifecycle import native, save, sha256
from runner import collect
from reading.build import build_control
from reading.corpus import document
from reading.plan import interaction
from reading.analysis import native_motion_truth


def calibrate(tools, directory, modes=("normal", "frozen", "wrong", "delay", "stall")):
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    app = build_control(tools)
    helper = tools / "collector"
    corpus = document(1, 8)
    reports = {}
    for mode in modes:
        print("Reading scroll control: " + mode, flush=True)
        root = directory / mode
        root.mkdir()
        save(root / "corpus.json", corpus.manifest())
        save(root / "launch-config.json", {"app": str(app),
             "arguments": [mode, str(root / "corpus.json"), str(root / "control-events.jsonl")]})
        launched = native(helper, "launch", root / "launch-config.json")
        identity = launched["process"]
        try:
            time.sleep(.5)
            owner = native(helper, "prepare", identity["pid"])
            point = {"x": owner["bounds"]["x"] + owner["bounds"]["width"] / 2,
                     "y": owner["bounds"]["y"] + owner["bounds"]["height"] / 2}
            schedule = interaction("reading.scroll", point)
            plan = {"version": 1, "kind": "plan", "clock": "macos.mach_absolute_time.nanoseconds",
                    "scenario": "reading.scroll", "count": 1, "mode": "observed", "targetKind": "control",
                    "pid": identity["pid"], "processIdentity": identity["identity"], "windowID": owner["windowID"],
                    "windowBounds": owner["bounds"], "startNS": time.monotonic_ns() + 2_000_000_000,
                    "warmupSeconds": 1.0, "formalSeconds": schedule["formalSeconds"], "tailSeconds": schedule["tailSeconds"],
                    "sampleHz": 10.0, "captureHz": 5.0, "maximumNoProgressSeconds": .65,
                    "maximumCaptureGapSeconds": .65, "motionTolerancePixels": 14.0, "anchors": list(corpus.anchors),
                    "processRoots": [{**identity, "role": "application"},
                                     {**native(helper, "process", os.getpid()), "role": "source"}],
                    "events": schedule["events"], "reading": {"corpus": corpus.manifest(),
                    "executionId": "control-execution",
                    "entryTrigger": None, "segments": schedule["segments"]}}
            collect(tools, root, plan, app)
            if not (root / "observation.json").is_file():
                raise RuntimeError("native collector produced no observation; inspect retained collector.log before continuing controls")
            save(root / "outcome.json", {"status": "passed", "expectedFault": mode})
        except Exception as error:
            save(root / "failure.json", {"error": str(error), "atNS": time.monotonic_ns()})
            raise
        finally:
            errors = []
            try:
                native(helper, "quit", identity["pid"], identity["identity"])
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        actual = native(helper, "process", identity["pid"])
                    except RuntimeError:
                        break
                    if actual["identity"] != identity["identity"]:
                        break
                    time.sleep(.1)
                else:
                    errors.append("reading control did not exit")
            except Exception as error:
                errors.append(str(error))
            save(root / "cleanup.json", {"errors": errors})
            seal(root)
            reports[mode] = write_report(root)
    stalls = directory / "stall/control-events.jsonl"
    events = [json.loads(line) for line in stalls.read_text().splitlines()] if stalls.exists() else []
    real_stall = (len(events) == 2 and events[0]["kind"] == "stall-start" and events[1]["kind"] == "stall-end"
                  and events[1]["atNS"] - events[0]["atNS"] >= 1_000_000_000)
    outcomes = {name: report["product"] for name, report in reports.items()}
    receiver_truth = "normal" in reports and native_motion_truth(directory / "normal", reports["normal"])
    reversed_motion = any(segment["direction"] * segment["observedDisplacementPoints"] < -24
                          for segment in reports.get("wrong", {}).get("metrics", {}).get("reading", {}).get("scroll", []))
    passed = (outcomes.get("normal") == "passed" and real_stall and receiver_truth and reversed_motion
              and all(outcomes.get(name) in ("overloaded", "wrong-result") for name in ("frozen", "wrong", "delay", "stall")))
    result = {"version": 1, "collectorSHA256": sha256(helper),
              "readingScroll": {"passed": passed, "outcomes": outcomes, "realMainThreadStall": real_stall,
                                "nativeReceiverAndPixelsAgree": receiver_truth, "reversedMotionDetected": reversed_motion},
              "passed": False, "normal": False, "stall": False, "wrongOwner": False,
              "hitchScope": "This calibration establishes reading pixels/input, not native hitch capability.",
              "controlBuild": json.loads((tools / "reading-control-build.json").read_text()),
              "toolBuild": json.loads((tools / "build.json").read_text()), "host": native(helper, "probe"),
              "controlManifests": {name: sha256(directory / name / "manifest.json") for name in reports}}
    save(directory / "capabilities.json", result)
    seal(directory)
    return result
