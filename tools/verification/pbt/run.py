#!/usr/bin/env python3
"""Run the declared properties with explicit budgets and retained evidence."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[3]
INVENTORY = json.loads(Path(__file__).with_name("properties.json").read_text())


def positive(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", choices=["go", "native", "native-state", "system"], default="go")
    parser.add_argument("--property", choices=[p["id"] for p in INVENTORY])
    parser.add_argument("--seed", type=positive, default=os.environ.get("CHIEF_PBT_SEED", "1"))
    parser.add_argument("--cases", type=positive, default=os.environ.get("CHIEF_PBT_CASES"))
    parser.add_argument("--timeout", type=positive, default=600, help="per-property wall seconds, including build")
    parser.add_argument("--shrink-seconds", type=positive, default=30)
    parser.add_argument("--fuzz-seconds", type=positive, default=10)
    parser.add_argument("--go", default=os.environ.get("CHIEF_PBT_GO", "./scripts/go.sh" if sys.platform == "darwin" else "go"))
    parser.add_argument("--race", action="store_true")
    parser.add_argument("--failfile", type=Path, help="Rapid minimized file; requires one Rapid property")
    parser.add_argument("--replay", type=Path, help="Swift minimized JSON; requires one Swift property")
    parser.add_argument("--artifacts", type=Path, help="new evidence directory (must not already exist)")
    parser.add_argument("--swift-scratch", type=Path)
    parser.add_argument("--swift-skip-update", action="store_true", help="use already-cached pinned Swift dependencies")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    selected = [p for p in INVENTORY if p["id"] == args.property] if args.property else [p for p in INVENTORY if p["suite"] == args.suite]
    if args.list:
        print(json.dumps(selected, indent=2))
        return 0
    if args.seed >= 2**64 or args.cases is not None and args.cases > 10000:
        parser.error("seed must fit UInt64; cases must be 1..10000")
    for option, engine in [(args.failfile, "rapid"), (args.replay, "swift")]:
        if option and (len(selected) != 1 or selected[0]["engine"] != engine or not option.is_file()):
            parser.error(f"replay requires one {engine} property and an existing file")
    if args.race and any(p["engine"] != "rapid" for p in selected):
        parser.error("--race requires one Rapid property (select --property)")

    evidence = args.artifacts.resolve() if args.artifacts else Path(tempfile.mkdtemp(prefix="chief-pbt-"))
    if args.artifacts:
        evidence.mkdir(parents=True, exist_ok=False)
    print(f"PBT evidence: {evidence}", flush=True)
    git = lambda *cmd: subprocess.check_output(["git", *cmd], cwd=ROOT, text=True).strip()
    summary = {"startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "head": git("rev-parse", "HEAD"), "status": git("status", "--porcelain"),
               "platform": platform.platform(), "seed": args.seed, "properties": [], "exitCode": None}
    # A dirty revision is identified by its complete patch and untracked source
    # hashes. Evidence cannot be mistaken for certification of HEAD alone.
    (evidence / "tracked.patch").write_bytes(subprocess.check_output(["git", "diff", "HEAD", "--binary"], cwd=ROOT))
    summary["untrackedSHA256"] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
        for p in git("ls-files", "--others", "--exclude-standard").splitlines() if (ROOT / p).is_file() and not (ROOT / p).is_relative_to(evidence)}

    def checkpoint():
        (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    checkpoint()
    exit_code = 0
    for prop in selected:
        item = {**prop, "cases": args.cases or prop.get("cases"), "status": "running"}
        summary["properties"].append(item)
        folder = evidence / prop["id"]
        folder.mkdir()
        env = dict(os.environ)
        # Ambient replay flags must not silently turn a generated gate into a
        # single old case. All budgets/replay selectors belong to this invocation.
        env.pop("CHIEF_PBT_REPLAY", None)
        env.pop("RAPID_FAILFILE", None)
        env.pop("CHIEF_PBT_RAPID_REPLAY", None)
        if args.failfile:
            replay = folder / "explicit.fail"
            replay.write_bytes(args.failfile.read_bytes())
            item["replay"] = {"requestedPath": str(args.failfile.resolve()), "artifact": str(replay.relative_to(evidence)),
                              "sha256": hashlib.sha256(replay.read_bytes()).hexdigest(), "status": "pending"}
            env["CHIEF_PBT_RAPID_REPLAY"] = str(replay)
        engine = prop["engine"]
        capability_error = None
        if engine == "swift" or prop["suite"] == "system":
            if sys.platform != "darwin":
                capability_error = "macOS required"
        if prop["suite"] == "system":
            native = Path(env.get("CHIEF_SYSTEM_CODEX", ""))
            if not native.is_absolute() or not native.is_file() or not os.access(native, os.X_OK):
                capability_error = "CHIEF_SYSTEM_CODEX must name an executable absolute native CLI path"
            env["CHIEF_PBT_EVIDENCE"] = str(folder)
        if engine == "swift":
            env.update(CHIEF_PBT_SEED=str(args.seed), CHIEF_PBT_CASES=str(item["cases"]),
                       CHIEF_PBT_SHRINK_SECONDS=str(args.shrink_seconds), CHIEF_PBT_EVIDENCE=str(folder))
            if args.replay:
                env["CHIEF_PBT_REPLAY"] = str(args.replay.resolve())
            command = ["xcrun", "swift", "test", "--package-path", "app/macos", "--disable-sandbox", "-Xswiftc", "-warnings-as-errors", "--filter", prop["test"]]
            if args.swift_scratch:
                command += ["--scratch-path", str(args.swift_scratch.resolve())]
            if args.swift_skip_update:
                command += ["--skip-update", "--disable-automatic-resolution"]
        else:
            command = shlex.split(args.go) + ["test", "./" + prop["package"], "-count=1", "-json", f"-timeout={args.timeout}s"]
            if engine == "rapid":
                if args.race:
                    command.append("-race")
                command += ["-run", "^" + prop["test"] + "$", "-short=false", f"-rapid.checks={item['cases']}", f"-rapid.seed={args.seed}", "-rapid.steps=30", "-rapid.nofailfile=false", f"-rapid.shrinktime={args.shrink_seconds}s"]
            else:
                command += ["-run=^$", "-fuzz=^" + prop["test"] + "$", f"-fuzztime={args.fuzz_seconds}s", f"-fuzzminimizetime={args.shrink_seconds}s", "-parallel=2"]
                item["cases"] = None
                item["fuzzSeconds"] = args.fuzz_seconds
                item["seedMechanism"] = "Go corpus; fuzz mutation scheduling has no fixed seed control"
        item["command"] = command
        item["timeoutSeconds"] = args.timeout
        checkpoint()
        print(f"RUN {prop['id']}: {shlex.join(command)}", flush=True)
        started = time.monotonic()
        code = 2 if capability_error else 0
        with (folder / "output.log").open("w") as log:
            if capability_error:
                log.write(capability_error + "\n")
                item["error"] = capability_error
            else:
                process = None
                try:
                    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    code = process.wait(timeout=args.timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt) as exc:
                    code = 130 if isinstance(exc, KeyboardInterrupt) else 124
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                except OSError as exc:
                    code = 2
                    item["error"] = str(exc)
                    log.write(str(exc) + "\n")
        output = (folder / "output.log").read_text(errors="replace")
        item["childExitCode"] = None if capability_error else code
        events = []
        if engine != "swift":
            for line in output.splitlines():
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        if args.failfile:
            actions = [e.get("Action") for e in events if e.get("Test") == prop["test"] + "/explicit-replay"]
            replay_status = ("passed" if "pass" in actions else "failed" if "fail" in actions
                             else "invalid" if "skip" in actions else "not-executed")
            item["replay"]["status"] = replay_status
            if replay_status == "invalid":
                code = 2
                item["error"] = "explicit Rapid counterexample did not execute to completion"
            elif replay_status == "not-executed" and code == 0:
                code = 1
                item["error"] = "no explicit Rapid replay execution observed"
        if engine == "rapid" and ("[rapid] ignoring fail file:" in output or "is no longer valid" in output):
            code = 2
            item["error"] = "Rapid corpus input was ignored or is no longer valid"
        if code != 0 and "PBT CAPABILITY: WindowServer/display required" in output:
            item["error"] = "WindowServer/display required"
            code = 2
        if engine != "swift":
            corpus = ROOT / prop["package"] / "testdata"
            if corpus.exists():
                shutil.copytree(corpus, folder / "testdata")
        if code == 0:
            # Empty filters, skipped cases and a build-only result are not passes.
            if engine == "swift":
                witnessed = f"PBT PASS {prop['id']} " in output
            else:
                witnessed = any(e.get("Action") == "pass" and e.get("Test") == prop["test"] for e in events)
                if engine == "rapid":
                    counts = re.findall(r"\[rapid\] OK, passed (\d+) tests", output)
                    item["generatedCases"] = int(counts[-1]) if counts else 0
                    witnessed = witnessed and item["generatedCases"] == item["cases"]
                if engine == "fuzz":
                    witnessed = witnessed and bool(re.search(r"execs: [1-9][0-9]*", output))
            if not witnessed:
                code = 1
                item["error"] = "no completed property execution observed"
        item.update(exitCode=code, elapsedSeconds=round(time.monotonic()-started, 3), status="passed" if code == 0 else "failed")
        if code:
            print(output[-12000:], flush=True)
            exit_code = code if code in (2, 124, 130) else 1
        print(f"{item['status'].upper()} {prop['id']} ({item['elapsedSeconds']}s)", flush=True)
        checkpoint()
        if code:
            break
    summary["exitCode"] = exit_code
    summary["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    checkpoint()
    return exit_code


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"PBT runner configuration/evidence error: {error}", file=sys.stderr)
        sys.exit(2)
