"""Portable adversarial replays of real reading plans, HTTP source and scorer."""
import copy
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import struct
import tempfile
import time
import zlib

from analysis.report import seal, write_report
from conformance.replay import fixture as shared_fixture
from lifecycle import save
from reading.corpus import document
from reading.plan import interaction
from reading.provider import ReadingProvider, workload
from reading.contract import terminal_fragment


def fixture(root):
    plan, observation, frames = shared_fixture(root)
    schedule = interaction("reading.scroll", {"x": 500, "y": 500})
    corpus = document(1, 8)
    plan.update(scenario="reading.scroll", count=1, formalSeconds=10.0, tailSeconds=3.0,
                anchors=list(corpus.anchors), events=schedule["events"],
                reading={"corpus": corpus.manifest(), "executionId": "execution-one",
                         "entryTrigger": None, "segments": schedule["segments"]})
    plan["windowBounds"]["height"] = 1600
    start = plan["startNS"]
    formal = start + 1_000_000_000
    observation["boundaries"].update(formalEnd=formal + 10_000_000_000, tailEnd=formal + 13_000_000_000)
    observation["inputs"] = [{**event, "plannedNS": formal + round(event["atSeconds"] * 1e9),
                              "postedNS": formal + round(event["atSeconds"] * 1e9)} for event in plan["events"]]
    # Independent control trajectory: down/up repeated, with explicit quiet
    # gaps. It is synthetic optical evidence, not a production rendering model.
    path = ((0, 0), (.4, 0), (1.6, -360), (2.2, -360), (3.4, 0), (4, 0),
            (5.2, -360), (5.8, -360), (7, 0), (7.6, 0), (8.8, -360), (14, -360))
    template = observation["resources"][0]
    resources, frames = [], []
    for index in range(141):
        at = start + index * 100_000_000
        row = copy.deepcopy(template)
        row.update(atNS=at, endNS=at + 1_000_000)
        row["processes"][0]["cpuNS"] = index * 1_000_000
        resources.append(row)
        seconds = max(0, (at - formal) / 1e9)
        left, right = next(((a, b) for a, b in zip(path, path[1:]) if a[0] <= seconds <= b[0]), (path[-2], path[-1]))
        offset = left[1] + (right[1] - left[1]) * (seconds - left[0]) / (right[0] - left[0])
        frames.append({"atNS": at, "requestNS": at - 1_000_000, "image": "frame.png", "width": 1000, "height": 1600,
                       "pointsWidth": 1000, "pointsHeight": 1600, "windowBounds": plan["windowBounds"],
                       "texts": [{"text": anchor, "x": 120, "y": 750 + i * 40 + offset,
                                  "width": 220, "height": 20, "confidence": 1}
                                 for i, anchor in enumerate(corpus.anchors[:3])]})
    observation["resources"] = resources

    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xffffffff)
    image = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 1000, 1600, 8, 0, 0, 0, 0))
             + chunk(b"IDAT", zlib.compress(b"\x00" * (1001 * 1600))) + chunk(b"IEND", b""))
    (root / "frame.png").write_bytes(image)
    return plan, observation, frames


def persist(root, plan, observation, frames):
    observation["frames"] = [{key: value for key, value in frame.items() if key != "texts"} for frame in frames]
    save(root / "plan.json", plan)
    save(root / "observation.json", observation)
    (root / "frames.jsonl").write_text("".join(json.dumps(frame) + "\n" for frame in frames))
    seal(root)


def provider_replay(directory):
    directory.mkdir()
    provider = ReadingProvider(directory, 1, 8)
    provider.model, provider.effort = "fixture-model", "low"
    try:
        def request(prompt):
            peer = http.client.HTTPConnection("127.0.0.1", provider.server.server_port, timeout=20)
            value = {"model": "fixture-model", "stream": True, "input": [{"role": "user",
                     "content": [{"type": "input_text", "text": prompt}]}]}
            peer.request("POST", "/v1/responses", json.dumps(value), {"Authorization": "Bearer fixture-only"})
            response = peer.getresponse()
            if response.status != 200:
                raise AssertionError(response.read().decode())
            events = [json.loads(line[6:]) for line in response.read().decode().splitlines() if line.startswith("data: ")]
            peer.close()
            assert [event["sequence_number"] for event in events] == list(range(len(events)))
            assert events[-1]["type"] == "response.completed"
            return events

        reply = request("BENCH ITEM 01: Review the document.")
        answer = reply[-1]["response"]["output"][-1]["content"][0]["text"]
        assert answer == document(1, 8).markdown
        token = provider.prepare_reading_stream(2)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(request, f"BENCH ITEM 01: BENCH STREAM 01 {token}. Review the document.")
            deadline = time.monotonic() + 3
            while provider.streams[token]["ready"] != {1} and time.monotonic() < deadline:
                time.sleep(.01)
            provider.arm(token, time.monotonic_ns() + 100_000_000)
            events = future.result()
        source = provider.source_evidence(token)
        assert source["complete"] and not source["failures"]
        assert len(source["messages"]) == 9
        assert len(source["events"]) == len(source["workload"]["events"]) + 1
        final = events[-1]["response"]["output"]
        assert final[-1]["phase"] == "final_answer" and "READ 002 COMPLETE" in final[-1]["content"][0]["text"]
        assert all(item["phase"] == "commentary" for item in final[:-1])
        assert all(event["sentNS"] >= event["plannedNS"] for event in source["events"] + source["messages"])
    finally:
        provider.close()


def main():
    count = 0
    with tempfile.TemporaryDirectory(prefix="reading-contract-") as temporary:
        base = Path(temporary)

        def run(name, mutate=None, product=None, invalid=False):
            nonlocal count
            root = base / name
            root.mkdir()
            plan, observation, frames = fixture(root)
            if mutate:
                mutate(plan, observation, frames)
            persist(root, plan, observation, frames)
            result = write_report(root)
            if product:
                assert result["product"] == product, (name, result)
            if invalid:
                assert result["measurement"] == "invalid", (name, result)
            assert result["comparison"] != "passed", (name, result)
            count += 1
            return result

        normal = run("normal", product="passed")
        assert normal["measurement"] == "incomplete"
        assert len(normal["metrics"]["reading"]["scroll"]) == 5

        def freeze(plan, observation, frames):
            for frame in frames:
                for index, item in enumerate(frame["texts"]):
                    item["y"] = 750 + index * 40
        run("frozen", freeze, product="overloaded")

        # Exercise the production-target ambiguity in the actual pixel scorer;
        # the shared fixture otherwise represents an independent control app.
        from reading.analysis import pixels
        root = base / "inert-product-input"
        root.mkdir()
        p, o, f = fixture(root)
        freeze(p, o, f)
        p["targetKind"] = "application"
        result = {"metrics": {}}
        findings = []
        pixels(root, p, o, f, [], result,
               lambda reason, measurement=None, product=None: findings.append((reason, measurement, product)))
        assert result["scenarioEvidence"] is False
        assert any("input acceptance" in reason and measurement == "incomplete" for reason, measurement, _ in findings)
        assert not any(product for _, _, product in findings)

        def reverse(plan, observation, frames):
            for frame in frames:
                for index, item in enumerate(frame["texts"]):
                    item["y"] = 2 * (750 + index * 40) - item["y"]
        run("wrong-direction", reverse, product="wrong-result")

        def partial(plan, observation, frames):
            for frame in frames:
                for index, item in enumerate(frame["texts"]):
                    origin = 750 + index * 40
                    item["y"] = origin + (item["y"] - origin) / 10
        run("partly-consumed-input", partial, product="wrong-result")

        def settling(plan, observation, frames):
            for frame in frames:
                for index, item in enumerate(frame["texts"]):
                    origin = 750 + index * 40
                    item["y"] = origin + (item["y"] - origin) * 391 / 360
        run("native-settling-travel", settling, product="passed")

        def uncertain_gap(plan, observation, frames):
            formal = observation["boundaries"]["formalStart"]
            for frame in frames:
                seconds = (frame["atNS"] - formal) / 1e9
                if .4 <= seconds <= 1.6:
                    offset = -360 * max(0, seconds - .9) / .7
                    for index, item in enumerate(frame["texts"]):
                        item["y"] = 750 + index * 40 + offset
        uncertain = run("capture-uncertainty-crosses-progress-budget", uncertain_gap, product="passed")
        gap = uncertain["metrics"]["reading"]["scroll"][0]["maximumObservedNoProgressSeconds"]
        assert gap["lower"] <= .5 < gap["upper"], gap

        def missing(plan, observation, frames):
            for frame in frames:
                frame["texts"] = []
        run("no-business-body", missing, product="unknown")

        def wrong_document(plan, observation, frames):
            for frame in frames:
                for item in frame["texts"]:
                    item["text"] = item["text"].replace("READ 001", "READ 002")
        run("another-execution", wrong_document, product="unknown")
        run("changed-body-hash", lambda p, o, f: p["reading"]["corpus"].update(sha256="0" * 64), invalid=True)
        run("missing-input", lambda p, o, f: o["inputs"].pop(3), product="unknown")
        run("changed-input-direction", lambda p, o, f: o["inputs"][2].update(deltaY=5), invalid=True)
        run("invalid-scroll-phase", lambda p, o, f: p["events"][2].update(phase=4), invalid=True)
        run("changed-input-volume", lambda p, o, f: p["reading"]["segments"][0].update(inputPixels=-1), invalid=True)

        def entry(plan, observation, frames):
            schedule = interaction("reading.first-open", {"x": 500, "y": 500}, {"x": 300, "y": 300})
            plan.update(scenario="reading.first-open", events=schedule["events"])
            plan["reading"].update(entryTrigger=schedule["entryTrigger"], segments=schedule["segments"])
            formal = observation["boundaries"]["formalStart"]
            observation["inputs"] = [{**event, "plannedNS": formal + round(event["atSeconds"] * 1e9),
                                      "postedNS": formal + round(event["atSeconds"] * 1e9)} for event in plan["events"]]
            for frame in frames:
                seconds = (frame["atNS"] - formal) / 1e9
                if seconds < .6:
                    frame["texts"] = []
                elif seconds <= 4:
                    for index, item in enumerate(frame["texts"]):
                        item["y"] = 750 + index * 40

        presentation = run("entry", entry, product="passed")["metrics"]["reading"]["presentation"]
        assert presentation["firstContentSeconds"]["upper"] < .4
        assert presentation["scheduledUsabilityProbeSeconds"] > 3.7
        partial_entry = run("entry-partial-probe", lambda p, o, f: (entry(p, o, f), partial(p, o, f)), product="wrong-result")
        assert partial_entry["metrics"]["reading"]["presentation"]["scheduledUsabilityProbeSeconds"] is None

        def excerpt_only(plan, observation, frames):
            entry(plan, observation, frames)
            for frame in frames:
                frame["texts"] = [item for item in frame["texts"] if " BLOCK " not in item["text"]]
        run("entry-title-is-not-body", excerpt_only, product="unknown")

        def already_open(plan, observation, frames):
            entry(plan, observation, frames)
            readable = next(frame["texts"] for frame in frames if frame["texts"])
            for frame in frames:
                if not frame["texts"]:
                    frame["texts"] = copy.deepcopy(readable)
        run("entry-already-open", already_open, invalid=True)

        # Public application evidence crosses additional shared boundaries:
        # a card-entry click is not a canvas drag, and a bounded catalog summary
        # must never stand in for the complete scoped reply.
        from reading.public import verify_reply
        root = base / "application-entry"
        root.mkdir()
        p, o, f = fixture(root)
        entry(p, o, f)
        thread = {"id": "reader-thread", "title": "BENCH CARD 01"}
        p.update(targetKind="application", fixture={"count": 1, "threads": [thread],
            "uiThreadIDs": [thread["id"]], "observedNS": p["startNS"] - 100,
            "runtimeInsertionDeletion": False})
        corpus = document(1, 8)
        scope = {"kind": "turn", "key": "turn:execution-one"}
        snapshot = {"atNS": p["startNS"] - 100, "scope": scope, "value": {
            "executionId": "execution-one", "status": "completed",
            "timeline": [{"kind": "assistant", "status": "completed", "content": corpus.markdown}]}}
        prepared = verify_reply(snapshot, "execution-one", corpus)
        save(root / "reading-fixture.json", {"bodyKiB": 8, "reply": prepared})
        snapshot["atNS"] = o["boundaries"]["tailEnd"] + 100
        save(root / "public-content.json", snapshot)
        save(root / "outcome.json", {"status": "passed", "threads": [thread],
             "readingReply": verify_reply(snapshot, "execution-one", corpus), "semanticAfter": {"page": "thread"}})
        save(root / "body-corpus.json", corpus.manifest())
        save(root / "existing-fixture.json", p["fixture"])
        save(root / "artifact.json", {"syntheticProtocolReplay": True})
        save(root / "native-cli.json", {"syntheticProtocolReplay": True})
        save(root / "tail-outcome.json", {"beforeNS": snapshot["atNS"], "afterNS": snapshot["atNS"] + 100,
             "status": "completed", "threads": [thread]})
        persist(root, p, o, f)
        report = write_report(root)
        assert report["measurement"] != "invalid", report
        assert report["metrics"]["reading"]["presentation"]["firstContentSeconds"]
        assert not any("background target" in reason for reason in report["reasons"]), report
        count += 1
        snapshot["value"]["timeline"][0]["content"] = corpus.markdown[:4000]
        save(root / "public-content.json", snapshot)
        seal(root)
        report = write_report(root)
        assert report["measurement"] == "invalid" and any("fixture content" in reason for reason in report["reasons"]), report
        count += 1

        for name, fault in (("output-normal", None), ("output-omission", "omission"),
                            ("output-late", "late"), ("output-invisible", "invisible")):
            root = base / name
            root.mkdir()
            p, o, f = fixture(root)
            p["scenario"] = "reading.output-scroll"
            source_plan = workload(2, 8, "a" * 32)
            p["reading"]["source"] = source_plan
            formal = o["boundaries"]["formalStart"]
            source = {"version": 1, "clock": p["clock"], "startNS": formal, "workload": source_plan,
                      "events": [], "messages": [], "complete": True, "failures": []}
            for key, planned in (("events", [*source_plan["events"], terminal_fragment(source_plan)]),
                                 ("messages", [*source_plan["messages"], source_plan["terminal"]])):
                for event in planned:
                    at = formal + round(event["atSeconds"] * 1e9)
                    source[key].append({**event, "plannedNS": at, "sentNS": at + 1_000_000})
            if fault == "omission":
                source["events"].pop(2)
            if fault == "late":
                source["events"][2]["sentNS"] += 100_000_000
            if fault != "invisible":
                for frame in f:
                    available = [event for event in source["messages"]
                                 if "checkpoint" in event and event["sentNS"] <= frame["requestNS"]]
                    if available:
                        frame["texts"].append({"text": available[-1]["checkpoint"], "x": 700, "y": 300,
                                               "width": 250, "height": 20, "confidence": 1})
            save(root / "source.json", source)
            persist(root, p, o, f)
            report = write_report(root)
            assert report["product"] == ("passed" if fault is None else "unknown"), (name, report)
            if fault == "late":
                assert report["measurement"] == "invalid", report
            count += 1
        provider_replay(base / "provider")
    print(f"Reading conformance passed: {count} full scorer controls and real HTTP provider lifecycle")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
