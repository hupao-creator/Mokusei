"""Semantic macOS UI client (stdlib only)."""
import argparse
import json
import socket
import time


class Client:
    def __init__(self, path, timeout=5):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout)
        try:
            self.socket.connect(str(path))
        except BaseException:
            self.socket.close()
            raise
        self.reader = self.socket.makefile("rb")
        self.sequence = 0
        self.session = None
        self.response_sequence = 0

    def close(self):
        self.reader.close()
        self.socket.close()

    def request(self, action=None):
        self.sequence += 1
        request = {"protocol": 1, "id": str(self.sequence), "op": "perform" if action is not None else "snapshot"}
        if action is not None:
            request["action"] = action
        self.socket.sendall(json.dumps(request, ensure_ascii=False).encode() + b"\n")
        line = self.reader.readline(2 * 1024 * 1024 + 1)
        if not line.endswith(b"\n") or len(line) > 2 * 1024 * 1024:
            raise RuntimeError("Automation connection closed or response exceeded its limit")
        response = json.loads(line)
        if response.get("protocol") != 1 or response.get("id") != request["id"]:
            raise RuntimeError("Automation response identity mismatch")
        if self.session is not None and self.session != response["session"]:
            raise RuntimeError("App session changed during the run")
        if response["sequence"] <= self.response_sequence:
            raise RuntimeError("Automation responses arrived out of order")
        self.session = response["session"]
        self.response_sequence = response["sequence"]
        return response

    def snapshot(self):
        response = self.request()
        if not response["ok"] or response["snapshot"] is None:
            raise RuntimeError(f"Workspace is unavailable: {response}")
        return response["snapshot"]

    def settle(self, predicate=lambda state: True, timeout=8):
        deadline = time.monotonic() + timeout
        stable_since = None
        previous = None
        while time.monotonic() < deadline:
            state = self.snapshot()
            # Require repeated observations across UI updates: an immediate reply
            # may precede SwiftUI installing its animation or page lifecycle.
            key = (state["page"], state["settingsSection"], state["selectedThread"], state["selectedFilterId"])
            if state["mounted"] and not state["transitioning"] and predicate(state):
                if key != previous:
                    stable_since = time.monotonic()
                elif stable_since is not None and time.monotonic() - stable_since >= 0.15:
                    return state
                previous = key
            else:
                stable_since = None
                previous = None
            time.sleep(0.03)
        raise TimeoutError(f"Workspace did not reach the requested stable state: {state}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot")
    perform = sub.add_parser("perform")
    perform.add_argument("action", help='JSON action, e.g. {"name":"settings.open"}')
    args = parser.parse_args()
    client = Client(args.socket)
    try:
        result = client.request(json.loads(args.action) if args.command == "perform" else None)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if not result["ok"]:
            raise SystemExit(1)
    finally:
        client.close()


if __name__ == "__main__":
    main()
