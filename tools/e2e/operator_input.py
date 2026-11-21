"""Operator-assisted OS input with independent public result oracles.

This module never injects input or synthesizes a successful operator receipt.
The desktop operator records actual AX observations; missing input stays blocked.
"""
import json
import plistlib
import shutil

from lifecycle import Blocked
from report import input_evidence_template, operator_input_evidence, save, sha256


def bundle(app, session):
    target = session.root / "ChiefE2E.app"
    contents = target / "Contents"
    mac = contents / "MacOS"
    resources = contents / "Resources"
    mac.mkdir(parents=True)
    resources.mkdir()
    executable = mac / "ChiefE2E"
    shutil.copy2(app, executable)
    for source in app.parent.glob("*.bundle"):
        shutil.copytree(source, resources / source.name)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "ChiefE2E", "CFBundleIdentifier": "com.chief.e2e." + session.nonce,
        "CFBundleName": "Chief E2E Isolated", "CFBundlePackageType": "APPL",
        "ChiefDataDirectoryName": "ChiefE2E-" + session.nonce, "NSHighResolutionCapable": True}))
    save(session.output / "operator-bundle.json", {"path": str(target), "executableSHA256": sha256(executable),
        "files": {str(p.relative_to(target)): sha256(p) for p in sorted(target.rglob("*")) if p.is_file()}})
    return executable


def composer(session, desktop, thread, helpers, evidence):
    state, completed, read_turn, content, wait_for = helpers
    out = session.output
    before = state(session, thread)["observation"]["latestExecution"]["executionId"]
    current = desktop.stable()
    if current["page"] != "overview":
        desktop.request({"name": "settings.close"} if current["page"] == "settings" else {"name": "overview.show"})
    overview = desktop.stable(lambda s: s["page"] == "overview")
    target = next(t for t in overview["threads"] if t["threadId"] == thread)
    desktop.request({"name": "thread.open", "threadId": thread, "typeId": target["typeId"]})
    desktop.stable(lambda s: desktop.has_turn(s, before))
    text = "BENCH ITEM 01: E2E FOLLOWUP " + session.nonce
    stop_input = "BENCH ITEM 01: E2E STOP " + session.nonce
    identity = {"nonce": session.nonce, "pid": session.app.pid, "threadId": thread,
                "app": str(session.app.args[0].rsplit("/Contents/", 1)[0])}

    def request(stage, **values):
        if stage in ("send", "stop"):
            values["inputEvidenceTemplate"] = input_evidence_template()
        save(out / "operator-request.json", {**identity, "stage": stage, **values})
        session.event("operator-input-required", stage=stage, pid=session.app.pid)

    def receipt(stage, required):
        path = out / ("operator-" + stage + ".json")
        wait_for(path.exists, bool, 300)
        value = json.loads(path.read_text())
        if any(value.get(k) != v for k, v in identity.items()) or value.get("stage") != stage:
            raise Blocked("operator receipt does not match this app/thread/visit")
        if value.get("driver") != "system-accessibility" or any(value.get(k) is not True for k in required):
            raise Blocked("operator has not confirmed the required real system-input observations")
        if not isinstance(value.get("observations"), str) or not value["observations"].strip():
            raise Blocked("operator AX observation transcript is absent")
        evidence[stage] = {**operator_input_evidence(value.get("inputEvidence"), out), "receipt": path.name}
        return value

    def successor(previous):
        return wait_for(lambda: state(session, thread), lambda r:
            r["observation"]["latestExecution"]["executionId"] != previous, 300)["observation"]["latestExecution"]["executionId"]

    def prompt(snapshot, execution, expected):
        turns = snapshot["value"]["state"]["turns"]
        turn = next(t for t in turns if t["executionId"] == execution)
        assert any(m.get("role") == "user" and m.get("content") == expected for m in turn["messages"]), "persisted input differs from the typed draft"

    request("send", text=text, receipt="operator-send.json", confirmations=["typedDraft", "clickedSend", "draftCleared", "visibleReply"])
    sent = successor(before)
    completed(session, thread, sent)
    save(out / "composer-send-oracle.json", read_turn(session, thread, sent, session.peer.followup_body(), "composer-send-content.json"))
    prompt(json.loads((out / "composer-send-content.json").read_text()), sent, text)
    desktop.reconnect()
    save(out / "composer-send-ui.json", desktop.stable(lambda s: desktop.has_turn(s, sent)))
    receipt("send", ["typedDraft", "clickedSend", "draftCleared", "visibleReply"])

    request("stop", text=stop_input, receipt="operator-stop.json", confirmations=["typedDraft", "clickedSend", "draftCleared", "stopVisible", "clickedStop", "stopAbsent", "editorEnabled"])
    active = successor(sent)
    wait_for(lambda: session.peer.holds, lambda rows: bool(rows), 30)
    running = state(session, thread)
    save(out / "composer-running.json", running)
    assert running["observation"]["latestExecution"]["executionId"] == active and running["observation"]["latestExecution"]["status"] == "running", "held execution did not remain running before Stop"
    stopped = wait_for(lambda: state(session, thread), lambda r:
        r["observation"]["latestExecution"]["executionId"] == active and
        r["observation"]["latestExecution"]["status"] == "interrupted", 300)
    save(out / "composer-stopped.json", stopped)
    snapshot = content(session.runtime, thread, {"kind": "turn", "key": "turn:" + active})
    save(out / "composer-stop-content.json", snapshot)
    prompt(snapshot, active, stop_input)
    desktop.reconnect()
    save(out / "composer-stop-ui.json", desktop.stable())
    receipt("stop", ["typedDraft", "clickedSend", "draftCleared", "stopVisible", "clickedStop", "stopAbsent", "editorEnabled"])
    request("complete")
