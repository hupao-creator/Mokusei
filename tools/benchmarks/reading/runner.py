"""Owned production reader experiments; all semantic reads are outside timing."""
import json
import os
from pathlib import Path
import shutil
import time
import uuid

from adapter import Runtime, UI, wait_for
from analysis.report import seal, write_report
from lifecycle import Application, native, save, sha256
from runner import collect, existing_fixture, boundary_outcome
from reading.corpus import document
from reading.plan import interaction
from reading.provider import ReadingProvider
from reading.public import content, verify_reply


def controls(snapshot, role):
    return [item for item in snapshot.get("reading", {}).get("controls", []) if item["role"] == role]


def settled(application):
    def ready(snapshot):
        if not snapshot or snapshot.get("errors"):
            return False
        items = snapshot.get("reading", {}).get("controls", [])
        for item in items:
            if item["role"] in ("row.load", "execution.load") and item["value"].get("state") == "error":
                raise ValueError("reader content failed: " + str(item["value"]))
        return (snapshot.get("page") == "thread" and snapshot.get("mounted") is True
                and not snapshot.get("transitioning") and bool(controls(snapshot, "turn"))
                and all(item["value"].get("state") == "ready" for item in items
                        if item["role"] in ("row.load", "execution.load"))
                and not any(item.get("pending") for item in items)
                and not any(item["value"].get("transitioning") for item in controls(snapshot, "conversation")))
    return wait_for(application.ui.request, ready, 45)


def control(application, item, operation="activate", value=None):
    return application.ui.request({"name": "reading.control", "controlId": item["id"], "handle": item["handle"],
                                   "operation": operation, "value": value})


def center(bounds):
    return {"x": bounds["x"] + bounds["width"] / 2, "y": bounds["y"] + bounds["height"] / 2}


def element(owner, predicate):
    matches = [item for item in owner["accessibility"] if predicate(item) and item.get("bounds")
               and item["bounds"]["width"] > 0 and item["bounds"]["height"] > 0]
    if len(matches) != 1:
        raise ValueError(f"external accessibility target is not unique ({len(matches)} matches)")
    return matches[0]


def prepare_reply(application, kib):
    thread_id = application.threads[1]
    expected = application.provider.receipts["bench_create_01"]["executionId"]

    def completed(state):
        if application.provider.failures:
            raise ValueError("reader provider failed: " + str(application.provider.failures))
        threads = [thread for thread in state["threads"] if thread["id"] == thread_id]
        if len(threads) != 1:
            raise ValueError("prepared reader thread disappeared")
        execution = threads[0].get("observation", {}).get("latestExecution") or {}
        if execution.get("executionId") != expected:
            return False
        if execution.get("status") in ("failed", "interrupted"):
            raise ValueError("fixture execution did not complete")
        return execution.get("status") == "completed"

    wait_for(application.runtime.state, completed, 90)
    snapshot = content(application.runtime, thread_id, {"kind": "turn", "key": "turn:" + expected})
    reply = verify_reply(snapshot, expected, document(1, kib))
    save(application.root / "prepared-reply.json", snapshot)
    save(application.root / "reading-fixture.json", {"bodyKiB": kib, "reply": reply})
    return expected


def restart(application):
    receipt = application.stop()
    if receipt["errors"]:
        raise ValueError("fixture shutdown did not join its owners: " + str(receipt["errors"]))
    application.owned.clear()
    application.socket = application.root / ("ui-" + uuid.uuid4().hex[:8] + ".sock")
    application.launch()
    application.runtime = Runtime(application.profile)
    application.ui = UI(application.socket, application.app.pid)
    wait_for(application.ui.request, lambda state: state and state.get("runtimeAvailable")
             and state.get("page") == "overview" and not state.get("transitioning"), 90)
    connection = json.loads((application.profile / "runtime/connection.json").read_text())
    runtime = native(application.helper, "process", connection["pid"])
    if (Path(runtime["path"]).resolve() != (application.bundle / "Contents/MacOS/mokusei-runtime").resolve()
            or Path(connection["dataDir"]).resolve() != application.profile.resolve()):
        raise ValueError("restarted bundled Runtime/profile identity mismatch")
    application.owned[connection["pid"]] = runtime
    return receipt


def open_reader(application):
    state = application.ui.request()
    if state.get("page") == "thread":
        application.ui.request({"name": "overview.show"})
        wait_for(application.ui.request, lambda snapshot: snapshot.get("page") == "overview"
                 and not snapshot.get("transitioning"), 30)
    application.ui.request({"name": "thread.open", "threadId": application.threads[1], "typeId": "agent"})
    return settled(application)


def body_position(application, execution_id, directory):
    snapshot = settled(application)
    timelines = controls(snapshot, "timeline")
    selected = [item for item in timelines if "turn:" + execution_id in item["value"].get("visibleRowIds", [])]
    if len(selected) != 1:
        raise ValueError("cannot identify the selected execution's public timeline")
    control(application, selected[0], "scrollTo", 0)
    snapshot = settled(application)
    owner = native(application.helper, "inspect", application.app.pid)
    capture = native(application.helper, "capture", application.app.pid, directory / "prepared-body.png")
    observed = native(application.helper, "ocr", directory / "prepared-body.png")
    save(directory / "prepared-body.json", {"capture": capture, "ocr": observed, "semantic": snapshot})
    markers = [item for item in observed["texts"] if item["text"].startswith("READ ")
               and item["confidence"] >= .5 and not item.get("edgeClipped", False)]
    if not markers:
        raise ValueError("reader preparation has no visible body checkpoint")
    marker = min(markers, key=lambda item: item["x"])
    scale = capture["width"] / capture["pointsWidth"]
    point = {"x": owner["bounds"]["x"] + (marker["x"] + marker["width"] / 2) / scale,
             "y": owner["bounds"]["y"] + (marker["y"] + marker["height"] / 2) / scale}
    return point, owner


def roots(application):
    rows = application.discover_owned()
    result = []
    for row in rows:
        role = "application" if row["pid"] == application.app.pid else (
            "runtime" if Path(row["path"]).name == "mokusei-runtime" else "helper")
        result.append({**row, "role": role})
    result.append({**native(application.helper, "process", os.getpid()), "role": "source"})
    return result


def run_case(application, tools, directory, scenario, kib, execution_id, mode, capability):
    directory.mkdir()
    for name in ("artifact.json", "native-cli.json", "selection.json", "reading-fixture.json"):
        shutil.copy2(application.root / name, directory / name)
    corpus = document(1, kib)
    save(directory / "body-corpus.json", corpus.manifest())
    token = None
    if scenario == "reading.first-open":
        save(directory / "restart-cleanup.json", restart(application))
    owner = native(application.helper, "prepare", application.app.pid)
    fixture = existing_fixture(application, directory)
    card = None
    body_point = center(owner["bounds"])
    if scenario in ("reading.first-open", "reading.reopen"):
        if scenario == "reading.reopen":
            open_reader(application)
            application.ui.request({"name": "overview.show"})
            wait_for(application.ui.request, lambda state: state.get("page") == "overview"
                     and not state.get("transitioning"), 30)
        identifier = "overview-card-" + application.threads[1]
        owner = wait_for(lambda: native(application.helper, "inspect", application.app.pid),
                         lambda state: any(item.get("AXIdentifier") == identifier and item.get("bounds", {}).get("width", 0) > 0
                                           for item in state["accessibility"]), 30)
        target = element(owner, lambda item: item.get("AXIdentifier") == identifier)
        card = center(target["bounds"])
    else:
        open_reader(application)
        if scenario == "reading.output-scroll":
            token = application.provider.prepare_reading_stream(2)
            result = application.runtime.invoke("thread:follow-up", [{"threadId": application.threads[1],
                "expectedExecutionId": execution_id, "input": {"parts": [{"kind": "text",
                "text": f"BENCH ITEM 01: BENCH STREAM 01 {token}. Review the document and report each completed stage."}]}}])
            save(directory / "active-execution.json", result)
            wait_for(lambda: application.provider.streams[token]["ready"], lambda ready: ready == {1}, 60)
            # A Runtime follow-up does not request a sidecard reveal in an
            # already mounted reader. Re-entering the running thread uses its
            # ordinary entry behavior to show that execution beside the body.
            open_reader(application)
            wait_for(application.ui.request, lambda state: any(
                "turn:" + result["executionId"] in item["value"].get("visibleRowIds", [])
                for item in controls(state, "timeline")), 30)
        body_point, owner = body_position(application, execution_id, directory)
    schedule = interaction(scenario, body_point, card)
    plan = {"version": 1, "kind": "plan", "clock": "macos.mach_absolute_time.nanoseconds",
            "scenario": scenario, "count": 1, "mode": mode, "targetKind": "application",
            "pid": application.app.pid, "processIdentity": owner["process"]["identity"],
            "windowID": owner["windowID"], "windowBounds": owner["bounds"],
            "startNS": time.monotonic_ns() + 2_000_000_000, "warmupSeconds": 1.0,
            "formalSeconds": schedule["formalSeconds"], "tailSeconds": schedule["tailSeconds"],
            "sampleHz": 10.0, "captureHz": 5.0, "maximumNoProgressSeconds": .65,
            "maximumCaptureGapSeconds": .65, "motionTolerancePixels": 14.0,
            "anchors": list(corpus.anchors), "processRoots": roots(application), "events": schedule["events"],
            "fixture": fixture,
            "reading": {"corpus": corpus.manifest(), "executionId": execution_id,
                        "segments": schedule["segments"], "entryTrigger": schedule["entryTrigger"]}}
    if token:
        plan["reading"]["source"] = application.provider.streams[token]["workload"]
    save(directory / "prepared-window.json", owner)
    collect(tools, directory, plan, application.bundle, capability,
            arm=(lambda start: application.provider.arm(token, start)) if token else None,
            checkpoint=lambda: boundary_outcome(application))
    if token:
        save(directory / "source.json", application.provider.source_evidence(token))
    state = application.runtime.state()
    thread = next(item for item in state["threads"] if item["id"] == application.threads[1])
    outcome_corpus = document(2, kib) if token else corpus
    outcome_id = thread["observation"]["latestExecution"]["executionId"] if token else execution_id
    snapshot = content(application.runtime, application.threads[1], {"kind": "turn", "key": "turn:" + outcome_id})
    reply = verify_reply(snapshot, outcome_id, outcome_corpus)
    save(directory / "public-content.json", snapshot)
    save(directory / "outcome.json", {"status": "passed", "threads": [{"id": thread["id"], "title": thread["title"]}],
         "readingReply": reply, "semanticAfter": application.ui.request(),
         "controlCancellations": list(application.provider.cancellations)})


def run_suite(tools, bundle, directory, body_kib, scenarios, mode, capability_dir=None):
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    capability = None
    if capability_dir:
        capability = json.loads((capability_dir / "capabilities.json").read_text())
        if capability.get("collectorSHA256") != sha256(tools / "collector"):
            raise ValueError("calibration belongs to another collector")
        shutil.copytree(capability_dir, directory / "calibration")
    summaries = []
    planned = [f"body-{kib}/{index:02d}-{scenario}" for kib in sorted(body_kib)
               for index, scenario in enumerate(scenarios)]
    for kib in sorted(body_kib):
        group = directory / f"body-{kib}"
        group.mkdir()
        application = Application(bundle, group / "fixture", 1, tools / "collector",
                                  provider_factory=lambda root, total: ReadingProvider(root, total, kib))
        trials = []
        try:
            print(f"Preparing one {kib} KiB reply through the real Harness", flush=True)
            application.start()
            execution_id = prepare_reply(application, kib)
            for index, scenario in enumerate(scenarios):
                case = group / f"{index:02d}-{scenario}"
                trials.append(case)
                print(f"Measuring {scenario}, body={kib} KiB", flush=True)
                try:
                    run_case(application, tools, case, scenario, kib, execution_id, mode, capability)
                except Exception as error:
                    case.mkdir(exist_ok=True)
                    save(case / "failure.json", {"error": str(error), "atNS": time.monotonic_ns()})
                    save(case / "outcome.json", {"status": "timeout" if isinstance(error, TimeoutError) else "unknown",
                                               "error": str(error)})
                    break
        except Exception as error:
            save(group / "preparation-failure.json", {"error": str(error)})
            summaries.append({"path": str(group.relative_to(directory)), "measurement": "incomplete", "product": "unknown",
                              "comparison": "not-comparable", "reasons": [str(error)], "metrics": {}})
        finally:
            cleanup = application.close()
            for case in trials:
                save(case / "cleanup.json", cleanup)
                seal(case)
                report = write_report(case)
                summaries.append({"path": str(case.relative_to(directory)), **report})
    observed_paths = {row["path"] for row in summaries}
    for path in planned:
        if path not in observed_paths:
            summaries.append({"path": path, "measurement": "incomplete", "product": "unknown",
                              "comparison": "not-comparable", "reasons": ["not run after fixture or earlier trial failure"],
                              "metrics": {}})
    save(directory / "summary.json", {"version": 1, "results": summaries, "statisticalRegressionGate": False,
         "requested": {"bodyKiB": body_kib, "scenarios": scenarios, "mode": mode}, "plannedTrials": planned})
    lines = ["# Agent Thread reading measurements", "",
             "Entry and scrolling measure one prepared reply in the production reader.",
             "Default reply sizes are 8 / 32 KiB; 128 KiB is an optional stress workload.",
             "Capture cadence is not display FPS.",
             "Incomplete resource accounting or unvalidated hitch capability remains explicit.", "",
             "Intervals and upper bounds reflect sampled captures; these are individual trials, not confidence intervals.", "",
             "| Trial | Measurement | Product | First body ms (interval) | Scroll response ms (largest upper bound) | No progress ms (largest upper bound) |",
             "| --- | --- | --- | ---: | ---: | ---: |"]
    for row in summaries:
        reading = row.get("metrics", {}).get("reading", {})
        interval = reading.get("presentation", {}).get("firstContentSeconds")
        content_ms = f"{interval['lower'] * 1000:.0f}–{interval['upper'] * 1000:.0f}" if interval else "unavailable"
        segments = reading.get("scroll", [])
        responses = [item["firstVisibleResponseSeconds"]["upper"] for item in segments
                     if item.get("motionCoverageComplete") and item.get("firstVisibleResponseSeconds")]
        gaps = [item["maximumObservedNoProgressSeconds"]["upper"] for item in segments if item.get("maximumObservedNoProgressSeconds") is not None]
        response_ms = f"{max(responses) * 1000:.0f}" if responses else "unavailable"
        gap_ms = f"{max(gaps) * 1000:.0f}" if gaps else "unavailable"
        lines.append(f"| {row['path']} | {row['measurement']} | {row['product']} | {content_ms} | {response_ms} | {gap_ms} |")
    lines += ["", "Observed application-process resources (complete process-tree accounting remains separate):", "",
             "| Trial | Measurement | Product | App CPU seconds | Sampled peak MiB |",
             "| --- | --- | --- | ---: | ---: |"]
    for row in summaries:
        app = row.get("metrics", {}).get("formal", {}).get("roles", {}).get("application", {})
        cpu = f"{app['observedCPUSeconds']:.4f}" if "observedCPUSeconds" in app else "unavailable"
        memory = f"{app['sampledPeakFootprintBytes'] / 2**20:.1f}" if "sampledPeakFootprintBytes" in app else "unavailable"
        lines.append(f"| {row['path']} | {row['measurement']} | {row['product']} | {cpu} | {memory} |")
    (directory / "summary.md").write_text("\n".join(lines) + "\n")
    return summaries
