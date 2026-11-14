"""Preparation/outcome reads through authenticated public content subscriptions."""
import hashlib
import json
import time
import urllib.request
import uuid


def content(runtime, thread_id, scope):
    connection = json.loads((runtime.profile / "runtime/connection.json").read_text())
    port = connection["port"]
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("invalid Runtime discovery port")
    base = f"http://127.0.0.1:{port}"
    headers = {"Content-Type": "application/json", "Authorization": "Bearer " + connection["token"],
               "X-Mokusei-Protocol": str(connection["protocolVersion"]), "X-Mokusei-Epoch": connection["epoch"]}
    client_id = None
    subscription = str(uuid.uuid4())

    def update(target):
        body = {"clientId": client_id, "subscriptionId": subscription, "target": target}
        request = urllib.request.Request(base + "/thread-content/subscription", json.dumps(body).encode(), headers)
        with runtime.http.open(request, timeout=30) as response:
            receipt = json.load(response)
        if receipt.get("ok") is not True:
            raise ValueError(f"public content subscription rejected: {receipt.get('error')}")

    request = urllib.request.Request(base + "/events", headers=headers)
    with runtime.http.open(request, timeout=30) as stream:
        deadline = time.monotonic() + 30
        try:
            while time.monotonic() < deadline:
                line = stream.readline(32 * 1024 * 1024 + 1)
                if not line or len(line) > 32 * 1024 * 1024:
                    raise ValueError("public content stream ended or exceeded its message bound")
                if not line.strip():
                    continue
                value = json.loads(line)
                if value.get("epoch") != connection["epoch"]:
                    raise ValueError("Runtime content epoch changed")
                if client_id is None:
                    if value.get("type") != "hello" or value.get("protocolVersion") != connection["protocolVersion"]:
                        raise ValueError("invalid public content handshake")
                    client_id = value["clientId"]
                    update({"threadId": thread_id, "scope": scope})
                elif value.get("type") == "thread-content":
                    event = value["event"]
                    if event.get("subscriptionId") != subscription:
                        raise ValueError("content delivered to another subscription")
                    if event.get("type") != "snapshot" or type(event.get("value")) is not dict:
                        raise ValueError(f"expected initial content snapshot: {event.get('type')}")
                    return {"atNS": time.monotonic_ns(), "protocolVersion": connection["protocolVersion"],
                            "scope": scope, "revision": event["revision"], "value": event["value"]}
            raise TimeoutError("public content snapshot timed out")
        finally:
            if client_id is not None:
                update(None)


def verify_reply(snapshot, execution_id, corpus, status="completed"):
    # This is a native-Harness wire adapter, not a reader implementation. It
    # admits the selected completed reply from the public scoped projection.
    if snapshot.get("scope") != {"kind": "turn", "key": "turn:" + execution_id}:
        raise ValueError("public reply observation targets another content scope")
    candidates = []
    pending = [snapshot["value"]]
    while pending:
        value = pending.pop()
        if isinstance(value, dict):
            if value.get("executionId") == execution_id and isinstance(value.get("timeline"), list):
                candidates.append(value)
            pending.extend(value.values())
        elif isinstance(value, list):
            pending.extend(value)
    if len(candidates) != 1 or candidates[0].get("status") != status:
        raise ValueError(f"selected {status} execution missing from public content")
    replies = [item for item in candidates[0]["timeline"]
               if item.get("kind") == "assistant" and item.get("status") not in ("streaming", "failed")
               and isinstance(item.get("content"), str) and item["content"].strip()]
    if not replies:
        raise ValueError("completed execution has no settled assistant reply")
    actual = replies[-1]["content"].encode("utf-8")
    expected = corpus.manifest()
    if len(actual) != expected["bytes"] or hashlib.sha256(actual).hexdigest() != expected["sha256"]:
        raise ValueError("public final reply omitted or changed fixture content")
    return {"executionId": execution_id, "bytes": len(actual), "sha256": expected["sha256"],
            "observedNS": snapshot["atNS"], "scope": snapshot["scope"], "status": status}
