"""Run the native Composer against Go transport, with a loopback response-loss proxy."""
from collections import defaultdict
from contextlib import closing
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
from threading import Thread
import time
from urllib.parse import unquote

source = Path(__file__).resolve().parent
repo = source.parents[1]
sys.path.insert(0, str(repo / "tools/verification"))
from native_replay import NativeReplay

replay = NativeReplay(repo, "ComposerReceiptReplay", "com.mokusei.replay.composer-receipt")
writes = defaultdict(list)
queries = []
requests = {}


def call(path, payload, headers):
    with closing(HTTPConnection("127.0.0.1", upstream["port"], timeout=5)) as conn:
        conn.request("POST", path, payload, headers)
        response = conn.getresponse()
        return response.status, json.loads(response.read())


def lookup(receipt, headers, until=None):
    deadline = time.monotonic() + 4
    while True:
        status, result = call("/commands/receipt", json.dumps({"commandId": receipt}), headers)
        if status != 200 or until is None or result["status"] == until:
            return status, result
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{receipt} did not reach {until}: {result}")
        time.sleep(.005)


def input_text(channel, args):
    if channel == "thread:fork":
        return args[0]["request"]["executionId"]
    return args[0]["input"]["parts"][0]["text"]


class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        data = json.loads(raw)
        receipt = data["commandId"]
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in {"content-length", "host", "connection"}}
        mode_file = replay.workspace / "mode"
        mode = mode_file.read_text() if mode_file.exists() else ""
        if self.path == "/commands/receipt":
            queries.append(receipt)
            status, result = call(self.path, raw, headers)
        else:
            channel = unquote(self.path).removeprefix("/invoke/")
            if channel != "harness:detect-installations":
                text = input_text(channel, data["args"])
                writes[channel].append((receipt, text))
                requests[receipt] = (self.path, raw, headers)
                if receipt.endswith("-followup"):
                    _, fork = lookup(receipt.removesuffix("-followup"), headers)
                    assert data["args"][0]["threadId"] == fork["result"]["value"]["threadId"], fork
                lose = (mode == "lose" or mode == "lose-fork" and channel == "thread:fork"
                        or mode == "lose-followup" and channel == "thread:follow-up")
                if lose:
                    with closing(HTTPConnection("127.0.0.1", upstream["port"], timeout=5)) as conn:
                        conn.request("POST", self.path, raw, headers)
                        status, pending = lookup(receipt, headers, "pending")
                        assert status == 200 and pending["status"] == "pending", pending
                    # Drop both sockets after Go durably admitted the command.
                    self.close_connection = True
                    print(channel, receipt, "Go receipt pending; disconnected", flush=True)
                    return
            status, result = call(self.path, raw, headers)
        body = json.dumps(result).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


try:
    def build(name):
        binary = replay.workspace / name
        subprocess.run([str(repo / "scripts/go.sh"), "build", "-o", binary,
                        "./demos/moku-panel-transition/" + name], cwd=repo, check=True)
        return binary

    collector = build("attachment-replay")
    backend = build("receipt-peer")
    files = json.loads(subprocess.check_output([collector, "stage"], cwd=replay.workspace))
    (replay.workspace / "files.json").write_text(json.dumps(files))
    replay.compile([source / "ReceiptReplay.swift"])
    with subprocess.Popen([backend], cwd=replay.workspace, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as peer:
        try:
            upstream = json.loads(peer.stdout.readline())
            auth = {"Authorization": "Bearer " + upstream["token"], "X-Mokusei-Epoch": upstream["epoch"],
                    "X-Mokusei-Protocol": str(upstream["protocolVersion"])}
            status, invalid = call("/invoke/thread%3Afollow-up", json.dumps({
                "commandId": "4C7F366D-557C-4C71-BE02-6CE37909F617", "args": []}), auth)
            calls = replay.workspace / "handler-calls.jsonl"
            assert status == 400 and invalid["error"]["code"] == "INVALID_COMMAND_ID" and not calls.read_bytes()
            print("Go rejected the baseline bare UUID before entering the handler", flush=True)
            with ThreadingHTTPServer(("127.0.0.1", 0), Proxy) as server:
                (replay.workspace / "peer.json").write_text(json.dumps({**upstream, "port": server.server_port}))
                Thread(target=server.serve_forever, daemon=True).start()
                try:
                    subprocess.run([str(replay.executable)], cwd=replay.workspace, check=True, timeout=50)
                finally:
                    server.shutdown()
            for channel in ("moku:submit", "thread:follow-up"):
                receipt = writes[channel][0][0]
                if channel == "moku:submit":
                    original = json.loads(requests[receipt][1])["args"][0]["input"]["parts"]
                    assert original[1:] == [{"kind": "mention", "name": "Previous project",
                                             "path": "/fixture/Previous project", "pathType": "directory"}], original
                status, observed = lookup(receipt, auth)
                assert status == 200 and observed["status"] == "complete" and observed["result"]["ok"]
                assert queries.count(receipt) >= 2, queries
                # A deliberate duplicate probe must return the stored response.
                status, duplicate = call(*requests[receipt])
                assert status == 200 and duplicate == observed["result"]
                print(channel, "recovered", receipt, "client lookups", queries.count(receipt), flush=True)
            actual = defaultdict(list)
            for entry in map(json.loads, calls.read_text().splitlines()):
                actual[entry["channel"]].append(input_text(entry["channel"], entry["args"]))
            for channel in ("moku:submit", "thread:follow-up", "thread:fork"):
                expected = ["A", "D", "BC", "rejected", "boundary", "direct"]
                if channel == "thread:follow-up":
                    expected += ["after-fork", "historical", "after-followup", "historical", "same-checkpoint", "changed", "changed"]
                if channel == "thread:fork":
                    expected = ["historical"] * 4 + ["current"]
                assert [text for _, text in writes[channel]] == actual[channel] == expected, (writes[channel], actual[channel])
                print(channel, "admitted IDs / handler inputs", writes[channel], flush=True)
            initial, final = writes["thread:follow-up"][-2:]
            assert writes["thread:fork"][-1][0] == initial[0] + "-fork"
            assert final[0] == initial[0] + "-fork-followup"
        finally:
            peer.stdin.close()
            assert peer.wait(timeout=5) == 0
    subprocess.run([collector, "collect"], cwd=replay.workspace, check=True)
    assert not Path(files[0]["path"]).exists()
    assert Path(files[1]["path"]).read_bytes() == b"second"
    print("Collector removed the released file and preserved the durable successor bytes after process exit", flush=True)
finally:
    replay.close()
