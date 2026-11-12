"""Loopback Responses peer. All business writes still go through real Moku tools."""
import json
import re
import threading
import time
import uuid
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def title(index):
    return f"BENCH CARD {index:02d}"


def body(index):
    return f"BENCH BODY {index:02d}\nAmber river cedar stone.\nFixed completed task evidence."


def find_tool(declarations, wanted, namespace=""):
    for tool in declarations:
        if tool.get("name", "").split("__")[-1] == wanted:
            return tool["name"], namespace
        found = find_tool(tool.get("tools", []), wanted,
                          tool.get("name", namespace) if tool.get("type") == "namespace" else namespace)
        if found:
            return found
    return None


def declared_tools(request):
    return request.get('tools', []) + [t for item in request.get('input', []) for t in item.get('tools', [])]


class Provider:
    @staticmethod
    def title(index):
        return title(index)

    @staticmethod
    def body(index):
        return body(index)

    def answer(self, index, request):
        return self.body(index)

    def initial_result(self, index, thread):
        execution = thread.get('observation', {}).get('latestExecution') or {}
        return (thread.get('title') == self.title(index) and execution.get('status') == 'completed'
                and execution.get('summary') == self.body(index))

    def __init__(self, directory, count):
        self.directory, self.count = directory, count
        self.model, self.effort = None, None
        self.receipts, self.failures, self.cancellations = {}, [], []
        self.request_count = 0
        self.streams = {}
        self.stopping = threading.Event()
        self.lock = threading.Lock()
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(15)

            def log_message(self, *args):
                pass

            def do_POST(self):
                control=False;request_number=None;headers_sent=False
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if (self.path != "/v1/responses" or not 0 < length <= 8 * 1024 * 1024
                            or self.headers.get("Authorization") != "Bearer fixture-only"):
                        raise ValueError("unexpected provider request")
                    request = json.loads(self.rfile.read(length))
                    control=find_tool(declared_tools(request),'create_thread') is not None
                    with owner.lock:
                        events = owner.respond(request)
                        request_number=owner.request_count
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    headers_sent=True
                    for sequence, event in enumerate(events):
                        evidence = event.pop("_source", None)
                        if evidence:
                            deadline = evidence["plannedNS"]
                            while time.monotonic_ns() < deadline:
                                if owner.stopping.wait(min(.01, (deadline-time.monotonic_ns())/1e9)):
                                    raise RuntimeError("provider stopped during body stream")
                        event["sequence_number"] = sequence
                        self.wfile.write(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n".encode())
                        self.wfile.flush()
                        if evidence:
                            evidence["sentNS"] = time.monotonic_ns()
                            with owner.lock:
                                owner.streams[evidence.pop("token")][evidence.pop("ledger", "events")].append(evidence)
                except (BrokenPipeError,ConnectionResetError) as error:
                    with owner.lock:
                        if control:
                            # Moku may preempt a telemetry response when another
                            # lifecycle notification arrives. Card delivery still
                            # has its own complete source and execution oracles.
                            owner.cancellations.append({'atNS':time.monotonic_ns(),'request':request_number,
                                'role':'moku','error':str(error)})
                            (owner.directory/'provider-cancellations.json').write_text(json.dumps(owner.cancellations,indent=2))
                        else:owner.failure(error)
                except Exception as error:
                    with owner.lock:owner.failure(error)
                    if not headers_sent:
                        try:self.send_error(400,str(error))
                        except (BrokenPipeError,ConnectionResetError):pass

            def do_CONNECT(self):
                self.send_error(403, "external model traffic denied")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        # close() must join request writers before evidence is sealed. A daemon
        # request could otherwise append a late cancellation/error after return.
        self.server.daemon_threads = False
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def failure(self,error):
        self.failures.append(str(error))
        (self.directory/'provider-errors.json').write_text(json.dumps(self.failures,indent=2))

    def close(self):
        self.stopping.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=10)
        (self.directory / "provider-outcome.json").write_text(json.dumps({
            "receipts": self.receipts, "failures": self.failures, "cancellations":self.cancellations}, indent=2))

    def respond(self, request):
        if request.get("model") != self.model or request.get("stream") is not True:
            raise ValueError("unexpected model or non-streaming request")
        with (self.directory / "provider-requests.jsonl").open("a") as stream:
            stream.write(json.dumps(request) + "\n")
        self.request_count += 1
        inputs = request.get("input", [])
        declarations = declared_tools(request)
        create = find_tool(declarations, "create_thread")
        properties = request.get("text", {}).get("format", {}).get("schema", {}).get("properties", {})
        payload = json.dumps(inputs)
        indices = re.findall(r"BENCH ITEM (\d{2})", payload)
        index = int(indices[-1]) if indices else None
        answer = "Fixture complete."
        call = None
        if "title" in properties and "emoji" in properties:
            if index is None:
                raise ValueError("metadata request lacks independent fixture identity")
            answer = json.dumps({"title": self.title(index), "emoji": "📄"})
        elif create:
            for item in inputs:
                if item.get("type") == "function_call_output" and item.get("call_id", "").startswith("bench_create_"):
                    output = item["output"]
                    if isinstance(output, str):
                        if output.startswith("Wall time:") and "\nOutput:\n" in output:
                            output = output.split("\nOutput:\n", 1)[1]
                        output = json.loads(output)
                    # Native MCP transport can wrap the command's JSON as content.
                    if "content" in output:
                        output = json.loads(next(c["text"] for c in output["content"] if c["type"] == "text"))
                    if output.get("ok") is not True or not output.get("threadId"):
                        raise ValueError(f"create_thread failed: {output}")
                    self.receipts[item["call_id"]] = output
            if "BENCHMARK CREATE" in payload:
                for n in range(1, self.count + 1):
                    call_id = f"bench_create_{n:02d}"
                    if call_id not in self.receipts:
                        arguments = {"prompt": f"BENCH ITEM {n:02d}: return the fixed completed task evidence.",
                                     "worktree": False, "target": {"codex": {
                                         "model": self.model, "thinking": {"mode": "effort", "effort": self.effort},
                                         "serviceTier": "default"}}}
                        call = {"type": "function_call", "call_id": call_id, "name": create[0],
                                "namespace": create[1], "arguments": json.dumps(arguments)}
                        break
        elif index is not None:
            stream = re.findall(r"BENCH STREAM (\d{2}) ([a-f0-9]{32})", payload)
            if stream:
                card, token = stream[-1]
                return self.stream(int(card), token, self.request_count)
            answer = self.answer(index, request)
        else:
            raise ValueError("unrecognized model request role")
        sequence = self.request_count
        rid, iid = f"resp_bench_{sequence}", f"item_bench_{sequence}"
        initial = {"id": rid, "object": "response", "status": "in_progress", "model": self.model, "output": []}
        item = {"id": iid, "type": "message", "role": "assistant", "phase": "final_answer",
                "status": "completed", "content": [{"type": "output_text", "text": answer, "annotations": []}]}
        events = [{"type": "response.created", "response": initial}]
        if call:
            item = {"id": iid, "status": "completed", **call}
            events += [{"type": "response.output_item.added", "output_index": 0,
                        "item": {**item, "arguments": "", "status": "in_progress"}},
                       {"type": "response.function_call_arguments.delta", "item_id": iid, "output_index": 0, "delta": call["arguments"]},
                       {"type": "response.function_call_arguments.done", "item_id": iid, "output_index": 0, "arguments": call["arguments"]}]
        else:
            events += [{"type": "response.output_item.added", "output_index": 0,
                        "item": {**item, "content": [], "status": "in_progress"}},
                       {"type": "response.content_part.added", "item_id": iid, "output_index": 0, "content_index": 0,
                        "part": {"type": "output_text", "text": "", "annotations": []}},
                       {"type": "response.output_text.delta", "item_id": iid, "output_index": 0, "content_index": 0, "delta": answer},
                       {"type": "response.output_text.done", "item_id": iid, "output_index": 0, "content_index": 0, "text": answer}]
        final = {**initial, "status": "completed", "output": [item], "usage": {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}}
        return events + [{"type": "response.output_item.done", "output_index": 0, "item": item},
                         {"type": "response.completed", "response": final}]

    def prepare_stream(self, workload, waiting=False):
        token = uuid.uuid4().hex
        workload["terminal"] = []
        for card in range(1,self.count+1):
            text=f"BENCH BODY {card:02d} complete. Reviewed launch settings, response handling and verification notes. RUN {token}."
            workload["terminal"].append({"card":card,"message":0,"kind":"terminal","atSeconds":workload["durationSeconds"],
                "text":text,"bytes":len(text.encode()),"sha256":hashlib.sha256(text.encode()).hexdigest()})
        self.streams[token] = {"workload": workload, "waiting": waiting, "gate": threading.Event(),
                               "ready": set(), "done": set(), "events": [], "messages": [], "startNS": None}
        return token

    def arm(self, token, start_ns):
        stream = self.streams[token]
        if stream["ready"] != set(range(1, self.count + 1)):
            raise ValueError("not all native streams have reached the source gate")
        stream["startNS"] = start_ns
        stream["gate"].set()

    def source_evidence(self, token):
        stream = self.streams[token]
        return {"version": 1, "clock": "macos.mach_absolute_time.nanoseconds", "token": token,
                "workload": stream["workload"], "startNS": stream["startNS"], "waiting": stream["waiting"],
                "ready": sorted(stream["ready"]), "done": sorted(stream["done"]),
                "messages": sorted(stream["messages"],key=lambda e:(e["plannedNS"],e["card"])),
                "complete": stream["done"] == set(range(1, self.count + 1)),
                "events": sorted(stream["events"], key=lambda e:(e["plannedNS"], e["card"]))}

    def stream(self, card, token, request_id):
        source = self.streams[token]
        if card not in range(1, self.count + 1) or card in source["ready"]:
            raise ValueError("unexpected or duplicate native body stream")
        source["ready"].add(card)
        rid = f"resp_stream_{request_id}"
        response = {"id": rid, "object": "response", "status": "in_progress", "model": self.model, "output": []}
        yield {"type": "response.created", "response": response}
        deadline = time.monotonic() + 120
        while not source["gate"].wait(.05):
            if self.stopping.is_set() or time.monotonic() > deadline:
                raise RuntimeError("source gate cancelled or timed out")
        output = []
        if not source["waiting"]:
            events = [e for e in source["workload"]["events"] if e["card"] == card]
            messages = sorted({e["message"] for e in events})
            for message in messages:
                iid = f"reasoning_{request_id}_{message}"
                oi = len(output)
                item = {"id": iid, "type": "reasoning", "summary": []}
                yield {"type": "response.output_item.added", "output_index": oi, "item": item}
                yield {"type": "response.reasoning_summary_part.added", "item_id": iid, "output_index": oi,
                       "summary_index": 0, "part": {"type": "summary_text", "text": ""}}
                cumulative = ""
                for event in (e for e in events if e["message"] == message):
                    cumulative += event["text"]
                    evidence = {**event, "token": token, "plannedNS": source["startNS"] + round(event["atSeconds"] * 1e9)}
                    yield {"type": "response.reasoning_summary_text.delta", "item_id": iid, "output_index": oi,
                           "summary_index": 0, "delta": event["text"], "_source": evidence}
                part = {"type": "summary_text", "text": cumulative}
                yield {"type": "response.reasoning_summary_text.done", "item_id": iid, "output_index": oi,
                       "summary_index": 0, "text": cumulative}
                yield {"type": "response.reasoning_summary_part.done", "item_id": iid, "output_index": oi,
                       "summary_index": 0, "part": part}
                item = {**item, "summary": [part]}
                output.append(item)
                yield {"type": "response.output_item.done", "output_index": oi, "item": item}
                # A completed progress note is a natural message boundary. Native
                # Harnesses may concatenate reasoning summaries within one turn;
                # this ordinary assistant item makes the new review step eligible
                # as the latest card body without rewriting metadata or history.
                note_id = f"progress_{request_id}_{message}"
                oi = len(output)
                note_event = next(e for e in source["workload"]["notes"] if e["card"]==card and e["message"]==message)
                note_text = note_event["text"]
                note = {"id": note_id, "type": "message", "role": "assistant", "phase": "commentary",
                        "status": "completed", "content": [{"type": "output_text", "text": note_text, "annotations": []}]}
                yield {"type": "response.output_item.added", "output_index": oi, "item": {**note, "status": "in_progress", "content": []}}
                yield {"type": "response.content_part.added", "item_id": note_id, "output_index": oi, "content_index": 0,
                       "part": {"type": "output_text", "text": "", "annotations": []}}
                yield {"type": "response.output_text.delta", "item_id": note_id, "output_index": oi, "content_index": 0, "delta": note_text,
                       "_source": {**note_event, "token": token, "ledger": "messages", "plannedNS":source["startNS"]+round(note_event["atSeconds"]*1e9)}}
                yield {"type": "response.output_text.done", "item_id": note_id, "output_index": oi, "content_index": 0, "text": note_text}
                yield {"type": "response.output_item.done", "output_index": oi, "item": note}
                output.append(note)
        end = source["startNS"] + round(source["workload"]["durationSeconds"] * 1e9)
        while time.monotonic_ns() < end:
            if self.stopping.wait(.01): raise RuntimeError("source cancelled")
        terminal = next(e for e in source["workload"]["terminal"] if e["card"]==card)
        answer = terminal["text"]
        iid = f"final_{request_id}"
        item = {"id": iid, "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed",
                "content": [{"type": "output_text", "text": answer, "annotations": []}]}
        oi = len(output)
        yield {"type": "response.output_item.added", "output_index": oi, "item": {**item, "content": [], "status": "in_progress"}}
        yield {"type": "response.content_part.added", "item_id": iid, "output_index": oi, "content_index": 0,
               "part": {"type": "output_text", "text": "", "annotations": []}}
        yield {"type": "response.output_text.delta", "item_id": iid, "output_index": oi, "content_index": 0, "delta": answer,
               "_source": {**terminal,"token":token,"ledger":"messages","plannedNS":end}}
        yield {"type": "response.output_text.done", "item_id": iid, "output_index": oi, "content_index": 0, "text": answer}
        yield {"type": "response.output_item.done", "output_index": oi, "item": item}
        output.append(item)
        yield {"type": "response.completed", "response": {**response, "status": "completed", "output": output,
               "usage": {"input_tokens": 10, "output_tokens": sum(len(e.get("text", "")) for e in source["workload"]["events"] if e["card"] == card)//4 + 30,
                         "total_tokens": sum(len(e.get("text", "")) for e in source["workload"]["events"] if e["card"] == card)//4 + 40}}}
        source["done"].add(card)
