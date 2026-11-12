"""Business-text motion from shared, already validated pixel captures."""
from statistics import median
from pathlib import Path
from contracts.model import CLOCK, integer, load
from reading.contract import terminal_fragment


def pixels(root, plan, observation, frames, times, result, mark):
    reading = plan["reading"]
    expected = set(plan["anchors"])
    rows = []
    for frame in frames:
        anchors = {}
        for item in frame["texts"]:
            # Exact fixture identities prevent a neighboring reader, title or
            # repeated prose from standing in for the selected execution.
            if item["text"] in expected and item["confidence"] >= .5 and not item.get("edgeClipped", False):
                if item["text"] in anchors:
                    mark("ambiguous reader body anchor", "incomplete")
                anchors[item["text"]] = item
        rows.append({"at": frame["atNS"], "request": frame["requestNS"],
                     "scale": frame["width"] / frame["pointsWidth"], "anchors": anchors})
    metrics = {"historyCount": reading["historyCount"], "bodyBytes": reading["corpus"]["bytes"],
               "storedHistoryIsVisibleBody": False, "scroll": [],
               "captureCadenceIsDisplayFPS": False}
    result["metrics"]["reading"] = metrics
    successful = True
    stalled = False
    onset = None
    if reading["entryTrigger"]:
        candidates = [event for event in observation["inputs"]
                      if all(event.get(key) == value for key, value in reading["entryTrigger"].items())]
        if len(candidates) != 1:
            mark("reading entry input is missing or ambiguous", "invalid")
            return
        onset = candidates[0]["postedNS"]
        recognizable = lambda row: len(row["anchors"]) >= 2 and any(" BLOCK " in key for key in row["anchors"])
        before = [row for row in rows if row["at"] <= onset]
        after = [row for row in rows if row["request"] >= onset]
        if not before:
            mark("entry has no pre-input capture", "incomplete"); successful = False
        elif any(recognizable(row) for row in before):
            mark("target body was already readable before entry", "invalid"); successful = False
        content = next((row for row in after if recognizable(row)), None)
        previous = next((row for row in reversed(rows) if content and row["at"] < content["request"]), None)
        metrics["presentation"] = {
            "firstContentSeconds": None if content is None else {
                "lower": max(0, (previous["request"] - onset) / 1e9) if previous else 0,
                "upper": (content["at"] - onset) / 1e9},
            "endpoint": "two recognizable body checkpoints including a non-excerpt block",
            "scheduledUsabilityProbeSeconds": None,
            "usableTimeIsUpperBoundAtScheduledProbe": True}
        if content is None:
            mark("selected execution body never became recognizable", "incomplete")
            successful = False
    for segment in reading["segments"]:
        if segment["viewport"] != "document":
            # Repeated unlabelled TOC marks are not independent text anchors.
            # Its system input is retained; the measured endpoint is opening the
            # known oldest execution, not a claim of directory optical FPS.
            metrics["historyDirectoryInputPixels"] = metrics.get("historyDirectoryInputPixels", 0) + segment["inputPixels"]
            continue
        events = [event for event in observation["inputs"] if event["kind"] == "scroll"
                  and segment["startSeconds"] <= event["atSeconds"] <= segment["endSeconds"]]
        if len(events) < 3:
            mark("document scroll input ledger incomplete", "incomplete")
            successful = False
            continue
        start, end = events[0]["postedNS"], events[-1]["postedNS"]
        baseline = next((row for row in reversed(rows) if row["at"] <= start and row["anchors"]), None)
        progress = start
        maximum_stall = 0
        minimum_stall = 0
        displacement = 0
        first_response = None
        pairs = 0
        missing = 0
        wrong = False
        sequence = [row for row in rows if start < row["at"] <= end + 300_000_000]
        previous = baseline
        if baseline is None or start - baseline["at"] > plan["maximumCaptureGapSeconds"] * 1e9:
            mark("document scroll lacks a recent pre-input body frame", "incomplete")
            successful = False
        for row in sequence:
            common = row["anchors"].keys() & previous["anchors"].keys() if previous else set()
            if not common:
                missing += 1
                previous = row
                continue
            if row["request"] - previous["at"] > plan["maximumCaptureGapSeconds"] * 1e9:
                missing += 1
                previous = row
                continue
            shifts = [(row["anchors"][name]["y"] - previous["anchors"][name]["y"]) / row["scale"] for name in common]
            dy = median(shifts)
            if max(abs(value - dy) for value in shifts) > 8:
                mark("reader anchor motion is inconsistent with one document", "incomplete")
                successful = False
            pairs += 1
            displacement += dy
            maximum_stall = max(maximum_stall, max(0, min(row["at"], end) - progress) / 1e9)
            if abs(dy) > 2:
                if dy * segment["direction"] < 0:
                    wrong = True
                else:
                    progress = row["at"]
                    if first_response is None:
                        first_response = {"lower": max(0, (previous["request"] - start) / 1e9),
                                          "upper": (row["at"] - start) / 1e9}
            else:
                # A capture that already contains motion supplies an upper
                # bound, not proof that the whole preceding gap was stalled.
                minimum_stall = max(minimum_stall, max(0, min(row["request"], end) - progress) / 1e9)
            previous = row
        maximum_stall = max(maximum_stall, max(0, end - progress) / 1e9)
        complete = pairs >= 3 and missing == 0 and baseline is not None and bool(sequence)
        entry = {"startSeconds": segment["startSeconds"], "direction": segment["direction"],
                 "inputPixels": segment["inputPixels"], "observedDisplacementPoints": displacement,
                 "minimumTravelPoints": segment["minimumTravelPoints"],
                 "firstVisibleResponseSeconds": first_response, "matchedFramePairs": pairs,
                 "unmatchedFramePairs": missing,
                 "maximumObservedNoProgressSeconds": {"lower": minimum_stall, "upper": maximum_stall} if complete else None,
                 "motionCoverageComplete": complete}
        metrics["scroll"].append(entry)
        if not complete:
            mark("continuous reader motion correspondence is incomplete", "incomplete")
            successful = False
        if wrong:
            mark("reader moved against the declared scroll direction", product="wrong-result")
            successful = False
        if complete and (first_response is None or minimum_stall > plan["maximumNoProgressSeconds"]):
            stalled = True
            successful = False
        elif complete and abs(displacement) < segment["minimumTravelPoints"] - 24:
            mark("reader did not complete the declared minimum scroll travel", product="wrong-result")
            successful = False
        if (complete and first_response and not wrong and minimum_stall <= plan["maximumNoProgressSeconds"]
                and abs(displacement) >= segment["minimumTravelPoints"] - 24
                and onset is not None and metrics["presentation"]["scheduledUsabilityProbeSeconds"] is None):
            metrics["presentation"]["scheduledUsabilityProbeSeconds"] = (start - onset) / 1e9 + first_response["upper"]
    if stalled:
        if plan["targetKind"] == "application" and not any(
                abs(segment["observedDisplacementPoints"]) > 24 for segment in metrics["scroll"]):
            # A system-post receipt and a body hit point cannot prove that the
            # product accepted the gesture. Fully inert input remains ambiguous.
            mark("no reader motion established; input acceptance or responsiveness is unknown", "incomplete")
        else:
            mark("reader stopped making progress during supplied scroll input", product="overloaded")
    result["scenarioEvidence"] = successful
    if plan["scenario"] == "reading.output-scroll":
        source(root, plan, frames, times, result, mark)


def source(root, plan, frames, times, result, mark):
    if not (root / "source.json").exists():
        mark("reader source evidence absent", "incomplete")
        result["scenarioEvidence"] = False
        return
    observed = load(root / "source.json")
    expected = plan["reading"]["source"]
    if observed.get("clock") != CLOCK or observed.get("startNS") != times[1] or observed.get("workload") != expected:
        mark("reader source identity/window differs from the plan", "invalid")
        result["scenarioEvidence"] = False
        return
    valid = True
    sent_messages = {}
    for name, planned in (("events", [*expected["events"], terminal_fragment(expected)]),
                          ("messages", [*expected["messages"], expected["terminal"]])):
        actual = observed[name]
        if len(actual) != len(planned):
            mark("reader output omitted or added planned work", "incomplete"); valid = False
        for sent, event in zip(actual, planned):
            if any(sent.get(key) != value for key, value in event.items()):
                mark("reader source payload/order changed", "invalid"); valid = False
            deadline = times[1] + round(event["atSeconds"] * 1e9)
            at = integer(sent["sentNS"], "source send timestamp", 1)
            if sent.get("plannedNS") != deadline or not deadline <= at <= deadline + 50_000_000:
                mark("reader source missed its declared deadline", "invalid"); valid = False
            if name == "messages":
                sent_messages[event["message"]] = at
    if observed.get("complete") is not True or observed.get("failures"):
        mark("reader source did not complete normally", "incomplete"); valid = False
    latencies = []
    for message in expected["messages"]:
        appeared = next((frame for frame in frames if any(message["checkpoint"] in item["text"]
                         and item["confidence"] >= .5 and not item.get("edgeClipped", False)
                         for item in frame["texts"])), None)
        sent = sent_messages.get(message["message"])
        if appeared and sent:
            if appeared["atNS"] < sent:
                mark("visible reply predates its source completion", "invalid"); valid = False
            latencies.append({"message": message["message"], "checkpoint": message["checkpoint"],
                              "sourceCompletionToCaptureUpperSeconds": (appeared["atNS"] - sent) / 1e9})
    metrics = result["metrics"]["reading"]
    metrics["output"] = {"fragmentCount": len(observed["events"]),
                         "fragmentBytes": sum(event["bytes"] for event in observed["events"]),
                         "completedMessages": len(observed["messages"]), "visibleCheckpoints": latencies,
                         "streamFragmentsAreRenderedFrames": False,
                         "hiddenStreamingBodiesAreExpected": True}
    if len(latencies) < 2:
        mark("insufficient visible settled-reply checkpoints during reading", "incomplete")
        valid = False
    result["scenarioEvidence"] = result.get("scenarioEvidence", False) and valid


def outcome(root, plan, observed, mark):
    from reading.corpus import document
    from reading.public import verify_reply
    reading = plan["reading"]
    fixture = load(root / "reading-fixture.json")
    count, kib = reading["historyCount"], reading["corpus"]["targetBytes"] // 1024
    executions = fixture["executions"]
    if (fixture.get("historyCount") != count or fixture.get("bodyKiB") != kib
            or fixture.get("storedHistoryIsVisibleBody") is not False or len(executions) != count
            or len({item["executionId"] for item in executions}) != count):
        raise ValueError("public reading fixture history is incomplete or inconsistent")
    for ordinal, execution in enumerate(executions, 1):
        corpus = document(ordinal, kib).manifest()
        if (execution["bytes"] != corpus["bytes"] or execution["sha256"] != corpus["sha256"]
                or execution["status"] != "completed" or execution["observedNS"] > plan["startNS"]):
            raise ValueError("prepared history omitted or changed declared completed replies")
    ordinal = reading["corpus"]["execution"]
    expected_id = executions[ordinal - 1]["executionId"]
    if expected_id != reading["executionId"]:
        raise ValueError("planned reader does not identify the prepared execution")
    if plan["scenario"] == "reading.history":
        preparation = load(root / "history-preparation.json")
        integer(preparation["completedNS"], "directory preparation completion", 1, plan["startNS"])
        if preparation["firstEntry"]["value"] != "turn:" + expected_id:
            raise ValueError("prepared directory hit point identifies another execution")
        label = preparation["firstEntry"]["label"]
        targets = [item for item in preparation["atBeginning"]["accessibility"]
                   if label in (item.get("AXTitle"), item.get("AXDescription")) and item.get("bounds")]
        if len(targets) != 1:
            raise ValueError("oldest directory hit point has no unique Accessibility evidence")
        bounds = targets[0]["bounds"]
        point = {axis: bounds[axis] + bounds[size] / 2 for axis, size in (("x", "width"), ("y", "height"))}
        entry = next(event for event in plan["events"] if all(
            event.get(key) == value for key, value in reading["entryTrigger"].items()))
        if point != preparation["oldestPoint"] or any(entry[axis] != point[axis] for axis in ("x", "y")):
            raise ValueError("history click differs from its observed entry geometry")
        for name in ("atBeginning", "atEnd"):
            owner = preparation[name]
            if owner["process"]["identity"] != plan["processIdentity"] or owner["bounds"] != plan["windowBounds"]:
                raise ValueError("history input geometry belongs to another process or window")
        if not any(item["role"] == "history.sidebar" and item["value"].get("selectedRow") == "turn:" + executions[-1]["executionId"]
                   for item in preparation["semantic"]["reading"]["controls"]):
            raise ValueError("directory preparation did not preserve the latest selected document")
    if plan["scenario"] == "reading.output-scroll":
        expected_id = load(root / "active-execution.json")["executionId"]
        ordinal = count + 1
        if expected_id in {item["executionId"] for item in executions}:
            raise ValueError("dynamic output did not start a subsequent execution")
    snapshot = load(root / "public-content.json")
    reply = verify_reply(snapshot, expected_id, document(ordinal, kib))
    if reply != observed.get("readingReply"):
        mark("reader outcome does not match its raw public reply", "invalid")
    if observed.get("semanticAfter", {}).get("page") != "thread":
        mark("final public route is not the reader", product="wrong-result")


def native_motion_truth(directory, report):
    """Independent AppKit receiver/geometry evidence, never product internals."""
    from contracts.model import loads
    path = directory / "received-scroll.jsonl"
    if not path.is_file():
        return False
    received = [loads(line) for line in path.read_text().splitlines() if line]
    plan = load(directory / "plan.json")
    formal = load(directory / "observation.json")["boundaries"]["formalStart"]
    segments = plan["reading"]["segments"]
    motion = report.get("metrics", {}).get("reading", {}).get("scroll", [])
    if len(received) != len(segments) or len(motion) != len(segments):
        return False
    return all(row["hasPreciseScrollingDeltas"] is True and row["endingPixels"] == 0
               and row["receivedEvents"] > 0 and abs(row["receivedPixels"] - segment["inputPixels"]) < .01
               and formal + segment["endSeconds"] * 1e9 < row["atNS"] < formal + (segment["endSeconds"] + .55) * 1e9
               and abs(row["startTop"] - row["settledTop"] - observed["observedDisplacementPoints"]) <= 8
               for row, segment, observed in zip(received, segments, motion))


def calibration(root, mark):
    from analysis.report import analyze, hash_file
    directory = root.parent.parent / "calibration"
    unavailable = {"pixelsPassed": False, "hitchesPassed": False}
    if not (directory / "manifest.json").is_file():
        mark("retained reading scroll calibration absent", "unsupported")
        return unavailable
    manifest = load(directory / "manifest.json")
    names = ("normal", "frozen", "wrong", "delay", "stall")
    required = {"capabilities.json", "stall/control-events.jsonl", "normal/received-scroll.jsonl",
                *(name + "/manifest.json" for name in names)}
    if manifest.get("version") != 1 or not required <= manifest.get("files", {}).keys():
        mark("reading calibration lacks required control evidence", "incomplete")
        return unavailable
    for name, digest in manifest["files"].items():
        path = directory / name
        if Path(name).is_absolute() or ".." in Path(name).parts or not path.resolve().is_relative_to(directory.resolve()):
            raise ValueError("reading calibration evidence escapes its directory")
        if not path.is_file() or hash_file(path) != digest:
            mark("reading calibration evidence changed: " + name, "invalid")
            return unavailable
    capability = load(directory / "capabilities.json")
    identity = load(root / "identity.json")
    if (any(capability.get(key) != identity.get(key) for key in ("collectorSHA256", "toolBuild"))
            or capability["host"]["os"] != identity["host"]["os"]
            or capability["host"]["screens"] != identity["host"]["screens"]):
        mark("reading calibration belongs to another collector or display environment", "unsupported")
        return unavailable
    controls = {name: analyze(directory / name) for name in names}
    stalls = [load_line for load_line in (directory / "stall/control-events.jsonl").read_text().splitlines() if load_line]
    from contracts.model import loads
    events = [loads(line) for line in stalls]
    bounds = load(directory / "stall/observation.json")["boundaries"]
    real_stall = (len(events) == 2 and events[0]["kind"] == "stall-start" and events[1]["kind"] == "stall-end"
                  and bounds["formalStart"] <= events[0]["atNS"] < events[1]["atNS"] <= bounds["tailEnd"]
                  and events[1]["atNS"] - events[0]["atNS"] >= 1_000_000_000)
    receiver_truth = native_motion_truth(directory / "normal", controls["normal"])
    reversed_motion = any(segment["direction"] * segment["observedDisplacementPoints"] < -24
                          for segment in controls["wrong"].get("metrics", {}).get("reading", {}).get("scroll", []))
    passed = (controls["normal"]["product"] == "passed" and real_stall and receiver_truth and reversed_motion
              and all(controls[name]["product"] in ("overloaded", "wrong-result") for name in names[1:])
              and all(control["measurement"] != "invalid" for control in controls.values()))
    if not passed:
        mark("native reading scroll controls did not establish capability", "unsupported")
    mark("reading scroll controls do not certify native hitch sensitivity or ownership", "unsupported")
    return {"pixelsPassed": passed, "hitchesPassed": False, "realMainThreadStall": real_stall,
            "nativeReceiverAndPixelsAgree": receiver_truth, "reversedMotionDetected": reversed_motion}
