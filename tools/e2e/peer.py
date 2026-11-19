"""Deterministic external Responses input; the native Codex engine stays real.

Reuse the benchmark's existing loopback protocol peer, read-only. This adapter
owns e2e payloads, never Runtime or UI state.
"""
import hashlib
import json
import threading

from provider import Provider, declared_tools, find_tool


class Peer(Provider):
    def __init__(self, directory, nonce):
        self.nonce = nonce
        self.holds, self.input_cancellations = [], []
        self.collection_projects = []
        self.request_context = threading.local()
        super().__init__(directory, 1)

    def prepare_collection(self):
        self.collection_projects = [self.directory / name for name in ("Library", "Studio")]
        self.count = len(self.collection_projects)
        for project in self.collection_projects:
            project.mkdir()

    def creation_arguments(self, index):
        args = super().creation_arguments(index)
        if self.collection_projects:
            args["cwd"] = str(self.collection_projects[index - 1])
        return args

    def respond(self, request):
        if self.collection_projects and (create := find_tool(declared_tools(request), "create_report")):
            if request.get("model") != self.model or request.get("stream") is not True:
                raise ValueError("unexpected collection peer request")
            self.request_count += 1
            # Each directory's real Report Agent receives its own completion batch.
            # Native tool results drive the next call and the public catalog
            # independently establishes the eight document identities.
            done = {item.get("call_id") for item in request.get("input", [])
                    if item.get("type") == "function_call_output"}
            for index in range(1, 5):
                call_id = f"collection_report_{index}"
                if call_id not in done:
                    title = f"Collection report {index}"
                    args = {"title": title, "emoji": "📚", "shortDescription": "Collection budget fixture",
                            "html": f"<p>{title}</p>", "coverHTML": f"<div>{title}</div>", "relatedExecutions": []}
                    return self.response_events("", {"type": "function_call", "call_id": call_id, "name": create[0],
                        "namespace": create[1], "arguments": json.dumps(args)})
            return self.response_events("Reports complete.", None)
        events = super().respond(request)
        # A real model-service stream remains active until the UI cancels it.
        # No Runtime operation or internal state is used to hold execution.
        hold = ("E2E STOP " + self.nonce in json.dumps(request.get("input", []))
                and any(e.get("type") == "response.output_text.delta" and
                        e.get("delta") == self.followup_body() for e in events))
        self.request_context.hold = hold
        if not hold:
            return events
        self.holds.append({"request": self.request_count, "purpose": "await actual composer Stop"})

        def stream():
            for event in events[:3]:
                yield event
            yield {**events[3], "delta": "Working on this follow-up. Waiting for the user's Stop action."}
            while not self.stopping.wait(.2):
                yield {"type": "response.in_progress", "response": events[0]["response"]}
        return stream()

    def failure(self, error):
        if getattr(self.request_context, "hold", False) and isinstance(error, (BrokenPipeError, ConnectionResetError)):
            self.input_cancellations.append({"reason": type(error).__name__, "purpose": "held external stream closed"})
        else:
            super().failure(error)

    def title(self, index):
        return "E2E review " + self.nonce

    def body(self, index):
        return f"# Review {self.nonce}\n\nFirst result: amber river cedar stone.\n\nCompleted initial task."

    def followup_body(self):
        return f"# Follow-up {self.nonce}\n\nSecond result: violet lake maple cloud.\n\nCompleted follow-up task."

    def answer(self, index, request):
        if "E2E FOLLOWUP " + self.nonce in json.dumps(request.get("input", [])):
            return self.followup_body()
        return self.body(index)

    def evidence(self):
        return {"kind": "deterministic-responses-peer-real-codex", "nonce": self.nonce,
                "requests": self.request_count, "receipts": self.receipts,
                "failures": self.failures, "controlCancellations": self.cancellations,
                "heldInputs": self.holds, "inputCancellations": self.input_cancellations,
                "payloads": {"initial": self.body(1), "followup": self.followup_body()}}


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()
