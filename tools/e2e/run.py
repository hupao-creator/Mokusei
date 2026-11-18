#!/usr/bin/env python3
"""Run bounded real-boundary journeys and retain an auditable receipt."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import traceback
import uuid

ROOT = Path(__file__).resolve().parents[2]
# Read-only reuse of the already established external protocol adapters. Record
# their exact source hashes; do not reuse benchmark measurement or pass/fail code.
sys.path.insert(0, str(ROOT / "tools/benchmarks"))
sys.path.insert(0, str(ROOT / "tools/native-interaction"))
from adapter import wait_for
from reading.public import content, verify_reply

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lifecycle import Session, Blocked
from desktop import Desktop
from build import validate
from peer import digest
from lease import DesktopLease
import operator_input
from report import save, sha256, finish, verify


class RunInterrupted(BaseException):
    """Bypass per-scenario recovery when the whole run has been revoked."""


class Payload:
    def __init__(self, text):
        self.text = text

    def manifest(self):
        return {"bytes": len(self.text.encode()), "sha256": digest(self.text)}


def source_identity():
    def git(*args):
        return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True, timeout=15).strip()
    paths = list((ROOT / "tools/e2e").glob("*.py")) + [ROOT / path for path in (
        "tools/e2e/scenarios.json", "tools/benchmarks/adapter.py", "tools/benchmarks/provider.py",
        "tools/benchmarks/reading/public.py", "tools/native-interaction/client.py",
        "tools/e2e/README.md", ".github/workflows/e2e.yml",
        "app/macos/Sources/Host/Interaction/README.md", "app/macos/Sources/Host/Settings/README.md",
        "app/macos/Sources/Host/Overview/README.md",
        "internal/services/moku/README.md", "internal/core/runtime/README.md",
        "app/macos/Sources/Host/MokuScene/README.md")]
    return {"commit": git("rev-parse", "HEAD"), "dirty": bool(git("status", "--porcelain")),
            "diffSHA256": digest(git("diff", "HEAD")),
            "files": {str(p.relative_to(ROOT)): sha256(p) for p in paths},
            "ci": {k: os.environ[k] for k in ("GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_REF") if k in os.environ}}


def read_turn(session, thread, execution, expected, filename):
    snapshot = content(session.runtime, thread, {"kind": "turn", "key": "turn:" + execution})
    save(session.output / filename, snapshot)
    try:
        return verify_reply(snapshot, execution, Payload(expected))
    except ValueError as error:
        raise AssertionError(str(error)) from error


def thread_state(session, thread):
    return next(t for t in session.runtime.state()["threads"] if t["id"] == thread)


def completed(session, thread, execution=None):
    def predicate(row):
        if session.peer.failures:
            raise RuntimeError(f"external input failed: {session.peer.failures}")
        latest = row.get("observation", {}).get("latestExecution") or {}
        if latest.get("status") in ("failed", "interrupted"):
            raise AssertionError(f"execution unexpectedly {latest['status']}")
        return latest.get("status") == "completed" and (execution is None or latest.get("executionId") == execution)
    return wait_for(lambda: thread_state(session, thread), predicate, 60)


def send(session, thread, previous, text):
    return session.runtime.invoke("thread:follow-up", [{"threadId": thread, "expectedExecutionId": previous,
        "input": {"parts": [{"kind": "text", "text": text}]}}])
def run(args):
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    specs = json.loads((Path(__file__).parent / "scenarios.json").read_text())["scenarios"]
    specs = [s for s in specs if args.suite == "all" or
             (s["id"] == "E2E-COMPOSER-001") == (args.suite == "composer")]
    save(output / "scenario-contract.json", specs)
    source = source_identity()
    save(output / "source.json", source)
    rows = [{"id": s["id"], "status": "not-run", "functionality": "unknown", "reason": "not reached"} for s in specs]
    report = {"version": 1, "source": source, "validity": "incomplete", "scenarios": rows,
              "startedAt": time.time(), "suite": args.suite, "deadlineSeconds": args.timeout,
              "inputEvidence": {"mode": "operator-assisted-system-input" if args.operator_composer else "mounted-semantic-controls",
                                "operatorStages": {}}}
    session = None
    desktop = None
    lease = None
    start = time.monotonic()

    def event(phase, **values):
        with (output / "events.jsonl").open("a") as stream:
            stream.write(json.dumps({"elapsedSeconds": time.monotonic() - start, "phase": phase, **values}) + "\n")

    def alarm(signum, frame):
        raise RunInterrupted(f"run interrupted by signal {signum} or total deadline")

    def execute(identifier, action):
        row = next(r for r in rows if r["id"] == identifier)
        spec = next(s for s in specs if s["id"] == identifier)
        event("scenario-start", id=identifier)
        try:
            action()
            missing = [p for p in spec["evidence"] if not (output / p).is_file()]
            if missing:
                raise RuntimeError(f"missing required evidence: {missing}")
            row.update(status="passed", functionality="passed", reason="all declared assertions and evidence present")
        except Blocked as error:
            row.update(status="blocked", reason=str(error))
        except Exception as error:
            row.update(status="failed", reason=f"{type(error).__name__}: {error}")
            row["functionality"] = "failed" if isinstance(error, AssertionError) else "unknown"
            save(output / (identifier + "-failure.json"), {"error": str(error), "traceback": traceback.format_exc()})
            if not isinstance(error, AssertionError):
                report["validity"] = "invalid"
        event("scenario-end", **row)

    for sig in (signal.SIGALRM, signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, alarm)
    signal.setitimer(signal.ITIMER_REAL, args.timeout)
    try:
        event("prepare")
        try:
            artifact = validate(args.runtime.resolve())
        except (OSError, ValueError) as error:
            raise Blocked(str(error)) from error
        save(output / "artifact.json", artifact)
        session = Session(args.runtime.resolve(), output, uuid.uuid4().hex, event)
        session.prepare()
        session.start()
        session.configure()
        report["validity"] = "valid"
        event("prepare-thread")
        receipt = session.runtime.invoke("moku:submit", [{"input": {"parts": [{"kind": "text", "text":
            "BENCHMARK CREATE 1 completed tasks. E2E " + session.peer.nonce}]}}])
        wait_for(lambda: session.peer.receipts, lambda v: len(v) == 1, 60)
        thread = session.peer.receipts["bench_create_01"]["threadId"]
        row = completed(session, thread)
        initial = row["observation"]["latestExecution"]["executionId"]
        save(output / "creation.json", {"receipt": receipt, "thread": row})
        save(output / "initial-oracle.json", read_turn(session, thread, initial, session.peer.body(1), "initial-content.json"))
        event("prepared", thread=thread, execution=initial)
        report["preparation"] = "ready"
        if args.prepare_only:
            raise Blocked("preparation ready; no desktop interactions requested or covered")
        if not args.app or not args.desktop_lease or not args.desktop_owner:
            raise Blocked("requires --app, coordinator-agreed --desktop-lease directory and --desktop-owner; no GUI launched")
        app = args.app.resolve()
        if sys.platform != "darwin" or not app.is_file():
            raise Blocked("requires a built macOS UI executable and GUI session")
        lease = DesktopLease(args.desktop_lease, args.desktop_owner)
        save(output / "desktop-lease.json", lease.acquire())
        try:
            ui_artifact = validate(app)
        except (OSError, ValueError) as error:
            raise Blocked(str(error)) from error
        save(output / "ui-artifact.json", ui_artifact)
        if args.operator_composer:
            app = operator_input.bundle(app, session)
        session.app = session.spawn([app, "--runtime", session.binary, "--data-dir", session.profile,
            "--automation-socket", session.root / "ui.sock", "--benchmark-scenario", "overview"], "app")
        wait_for(lambda: (session.root / "ui.sock").exists(), bool, 40)
        desktop = Desktop(session)
        if args.operator_composer:
            save(output / "operator-request.json", {"stage": "activate", "pid": session.app.pid,
                "app": str(app).rsplit("/Contents/", 1)[0], "nonce": session.nonce})
            # LaunchServices/AX activation belongs to the external operator.
            # A new unique bundle can have a socket before its window mounts.
            wait_for(desktop.request, lambda s: s["mounted"] and s["runtimeAvailable"], 300)

        def followup():
            receipt = send(session, thread, initial, "BENCH ITEM 01: E2E FOLLOWUP " + session.peer.nonce)
            latest = receipt["executionId"]
            save(output / "followup.json", receipt)
            completed(session, thread, latest)
            save(output / "followup-oracle.json", read_turn(session, thread, latest, session.peer.followup_body(), "followup-content.json"))
            return latest

        if args.suite != "composer":
            execute("E2E-OVERVIEW-001", lambda: desktop.overview_camera(thread))
            execute("E2E-READ-001", lambda: desktop.read(thread, initial, followup))
            execute("E2E-SETTINGS-001", desktop.settings)
        if args.suite in ("all", "composer"):
            def composer():
                if not args.operator_composer:
                    raise Blocked("requires --operator-composer and actual external system-input receipts; no unattended input driver")
                operator_input.composer(session, desktop, thread, (thread_state, completed, read_turn, content, wait_for),
                                        report["inputEvidence"]["operatorStages"])
            execute("E2E-COMPOSER-001", composer)

    except BaseException as error:
        report["validity"] = "blocked" if isinstance(error, Blocked) else "invalid"
        report["error"] = f"{type(error).__name__}: {error}"
        save(output / "run-failure.json", {"error": str(error), "traceback": traceback.format_exc()})
        for row in rows:
            if row["status"] == "not-run":
                row.update(status="blocked", reason=report["error"])
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        # Cleanup has its own bounded waits. Repeated interrupts must not revoke
        # ownership before all independently acquired resources are visited.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        event("cleanup")
        close_error = None
        if desktop:
            try:
                desktop.close()
            except Exception as error:
                close_error = str(error)
        try:
            cleanup = session.close() if session else {"ok": True, "errors": [], "note": "no session acquired"}
        except Exception as error:
            cleanup = {"ok": False, "errors": [str(error)]}
        if close_error:
            cleanup["ok"] = False
            cleanup["errors"].append(close_error)
        if lease:
            try:
                cleanup["desktopLease"] = lease.close()
            except Exception as error:
                cleanup["ok"] = False
                cleanup["errors"].append(f"desktop lease cleanup: {error}")
        save(output / "cleanup.json", cleanup)
        if not cleanup["ok"]:
            report["validity"] = "invalid"
        report["elapsedSeconds"] = time.monotonic() - start
        event("report", validity=report["validity"])
        finish(output, report)
    print(json.dumps({"report": str(output / "report.md"), "exitCode": report["exitCode"]}))
    return verify(output)


def main():
    if not __debug__:
        raise ValueError("run without Python optimization; assertions must remain enabled")
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("list")
    check = sub.add_parser("verify")
    check.add_argument("directory", type=Path)
    execute = sub.add_parser("run")
    execute.add_argument("--runtime", type=Path, required=True)
    execute.add_argument("--output", type=Path, required=True, help="new evidence directory; never overwrite")
    execute.add_argument("--suite", choices=("supported", "all", "composer"), default="supported")
    execute.add_argument("--timeout", type=int, default=240)
    execute.add_argument("--prepare-only", action="store_true", help="do not launch GUI; exits 2 because interactions remain uncovered")
    execute.add_argument("--app", type=Path)
    execute.add_argument("--desktop-lease", type=Path, help="shared atomic lock directory")
    execute.add_argument("--desktop-owner", help="coordinator thread ID or CI run identity")
    execute.add_argument("--operator-composer", action="store_true", help="wait for actual external AX input and operator receipts")
    args = parser.parse_args()
    if args.command == "list":
        print((Path(__file__).parent / "scenarios.json").read_text())
        return 0
    if args.command == "verify":
        return verify(args.directory)
    if not 1 <= args.timeout <= 900:
        parser.error("timeout must be 1..900 seconds")
    return run(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"e2e invalid: {type(error).__name__}: {error}", file=sys.stderr)
        sys.exit(2)
