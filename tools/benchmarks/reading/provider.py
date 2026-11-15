"""Reader corpus and settled-message traffic over the common Responses peer."""
import hashlib
import threading
import time
import uuid

from provider import Provider
from reading.corpus import document, active_reply
from reading.contract import terminal_fragment


def payload(text):
    encoded = text.encode("utf-8")
    return {"text": text, "bytes": len(encoded), "sha256": hashlib.sha256(encoded).hexdigest()}


def chunks(text, size=256):
    current = ""
    count = 0
    for character in text:
        width = len(character.encode("utf-8"))
        if count + width > size:
            yield current
            current, count = "", 0
        current += character
        count += width
    if current:
        yield current


def workload(execution, kib, token):
    messages, events = [], []
    tasks = ("reading position", "navigation ownership", "completed results", "cancellation behavior",
             "history selection", "rendered paragraphs", "verification evidence", "final review")
    for index, task in enumerate(tasks, 1):
        text = (f"### Review stage {index}: {task}\n\n"
                f"I checked the {task} while keeping the selected document available. "
                "The completed result is recorded here so that the next stage can refer to it.\n\n"
                "- Kept the original execution identity.\n"
                "- Checked the observed behavior and preserved the result.\n"
                "- Recorded remaining questions for the final review.\n\n"
                f"UPDATE {execution:03d} CHECK {index:04d}\n")
        pieces = list(chunks(text))
        for part, piece in enumerate(pieces):
            events.append({"card": 1, "sequence": len(events) + 1, "message": index, "part": part,
                           "atSeconds": index - .8 + part * .6 / len(pieces), **payload(piece)})
        messages.append({"card": 1, "message": index, "kind": "settled",
                         "atSeconds": float(index), "checkpoint": f"UPDATE {execution:03d} CHECK {index:04d}",
                         **payload(text)})
    final = {"card": 1, "message": len(messages) + 1, "kind": "terminal", "atSeconds": 10.0,
             **payload(document(execution, kib).markdown)}
    return {"token": token, "durationSeconds": 10.0, "events": events, "messages": messages,
            "terminal": final, "delivery": "assistant fragments followed by complete meaningful replies"}


class ReadingProvider(Provider):
    def __init__(self, directory, count, kib):
        if count != 1:
            raise ValueError("reader provider owns one Agent Thread")
        self.kib = kib
        super().__init__(directory, count)

    def body(self, index):
        return document(1, self.kib).markdown

    def initial_result(self, index, thread):
        execution = thread.get("observation", {}).get("latestExecution") or {}
        # The public catalog summary is bounded. Full content equality belongs
        # to a scoped public content read after preparation, not this readiness
        # poll, which would otherwise reject legitimate large documents.
        return (thread.get("title") == self.title(index) and execution.get("status") == "completed"
                and (execution.get("summary") or "").startswith("# Reading review 001"))

    def prepare_reading_stream(self, execution):
        token = uuid.uuid4().hex
        self.streams[token] = {"workload": workload(execution, self.kib, token),
                               "gate": threading.Event(), "ready": set(), "done": set(),
                               "events": [], "messages": [], "startNS": None}
        return token

    def prepare_active_open(self):
        token = uuid.uuid4().hex
        self.streams[token] = {"opening": active_reply().manifest(), "gate": threading.Event(),
                               "ready": set(), "done": set(), "messages": [], "releasedNS": None}
        return token

    def release_active_open(self, token):
        source = self.streams[token]
        source["releasedNS"] = time.monotonic_ns()
        source["gate"].set()

    def active_open_evidence(self, token):
        source = self.streams[token]
        return {"version": 1, "clock": "macos.mach_absolute_time.nanoseconds",
                "corpus": source["opening"], "messages": list(source["messages"]),
                "releasedNS": source["releasedNS"], "complete": source["done"] == {1},
                "failures": list(self.failures)}

    def source_evidence(self, token):
        source = self.streams[token]
        return {"version": 1, "clock": "macos.mach_absolute_time.nanoseconds",
                "startNS": source["startNS"], "workload": source["workload"],
                "events": list(source["events"]), "messages": list(source["messages"]),
                "complete": source["done"] == {1}, "failures": list(self.failures)}

    def stream(self, card, token, request_id):
        source = self.streams.get(token)
        if source is None or card != 1 or source["ready"]:
            raise ValueError("unexpected or duplicate reader output request")
        source["ready"].add(card)
        if "opening" in source:
            yield from self.active_open_stream(source, token, request_id)
            return
        response = {"id": f"reading_response_{request_id}", "object": "response",
                    "status": "in_progress", "model": self.model, "output": []}
        yield {"type": "response.created", "response": response}
        deadline = time.monotonic() + 120
        while not source["gate"].wait(.05):
            if self.stopping.is_set() or time.monotonic() > deadline:
                raise RuntimeError("reader source gate cancelled or timed out")
        output = []
        schedule = source["workload"]
        for message in [*schedule["messages"], schedule["terminal"]]:
            index = len(output)
            item_id = f"reading_message_{request_id}_{index}"
            item = {"id": item_id, "type": "message", "role": "assistant", "status": "completed",
                    "phase": "final_answer" if message["kind"] == "terminal" else "commentary",
                    "content": [{"type": "output_text", "text": message["text"], "annotations": []}]}
            identity = {"item_id": item_id, "output_index": index}
            yield {"type": "response.output_item.added", "output_index": index,
                   "item": {**item, "status": "in_progress", "content": []}}
            yield {"type": "response.content_part.added", **identity, "content_index": 0,
                   "part": {"type": "output_text", "text": "", "annotations": []}}
            pieces = [event for event in schedule["events"] if event["message"] == message["message"]]
            if not pieces:
                pieces = [terminal_fragment(schedule)]
            for piece in pieces:
                yield {"type": "response.output_text.delta", **identity, "content_index": 0, "delta": piece["text"],
                       "_source": {**piece, "token": token,
                                   "plannedNS": source["startNS"] + round(piece["atSeconds"] * 1e9)}}
            yield {"type": "response.output_text.done", **identity, "content_index": 0, "text": message["text"]}
            yield {"type": "response.output_item.done", "output_index": index, "item": item,
                   "_source": {**message, "token": token, "ledger": "messages",
                               "plannedNS": source["startNS"] + round(message["atSeconds"] * 1e9)}}
            output.append(item)
        yield {"type": "response.completed", "response": {**response, "status": "completed", "output": output,
               "usage": {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}}}
        source["done"].add(card)

    def active_open_stream(self, source, token, request_id):
        text = active_reply().markdown
        response = {"id": f"opening_response_{request_id}", "object": "response",
                    "status": "in_progress", "model": self.model, "output": []}
        item = {"id": f"opening_message_{request_id}", "type": "message", "role": "assistant",
                "status": "completed", "phase": "commentary",
                "content": [{"type": "output_text", "text": text, "annotations": []}]}
        identity = {"item_id": item["id"], "output_index": 0}
        yield {"type": "response.created", "response": response}
        yield {"type": "response.output_item.added", "output_index": 0,
               "item": {**item, "status": "in_progress", "content": []}}
        yield {"type": "response.content_part.added", **identity, "content_index": 0,
               "part": {"type": "output_text", "text": "", "annotations": []}}
        yield {"type": "response.output_text.delta", **identity, "content_index": 0, "delta": text}
        yield {"type": "response.output_text.done", **identity, "content_index": 0, "text": text}
        yield {"type": "response.output_item.done", "output_index": 0, "item": item,
               "_source": {"token": token, "ledger": "messages", "plannedNS": time.monotonic_ns(), **payload(text)}}
        # The message settles before preparation. No content or completion is
        # emitted while the real execution remains running through the capture.
        deadline = time.monotonic() + 180
        while not source["gate"].wait(.05):
            if self.stopping.is_set() or time.monotonic() > deadline:
                raise RuntimeError("active opening source gate cancelled or timed out")
        yield {"type": "response.completed", "response": {**response, "status": "completed", "output": [item],
               "usage": {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}}}
        source["done"].add(1)
