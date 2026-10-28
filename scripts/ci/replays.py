"""Run existing production-boundary replays with retained, fail-closed evidence."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

import deadline


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("group", choices=["runtime", "adapters", "fixtures", "interop", "native",
                                         "interop-wire", "interop-process", "native-controls", "native-capture", "native-runtime"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--go", default=os.environ.get("MOKUSEI_GO", "go"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ, MOKUSEI_GO=args.go)
    go = [args.go, "run", "-race"]
    fixtures = {
        "MOKUSEI_INITIAL_RESPONSE_FIXTURES": str(output / "initial-response.json"),
        "MOKU_STATUS_NATIVE_FIXTURE": str(output / "moku-status.json"),
        "MOKUSEI_VOICE_EVENT_EXPORT": str(output / "voice-events.json"),
        "MOKUSEI_CONVERSATION_CONTRACT_EXPORT": str(output / "conversation.json"),
        "MOKUSEI_HARNESS_FORM_FIXTURE": str(output / "harness-forms.json"),
    }
    groups = {
        "runtime": [(name, go + ["./tools/verification/" + name]) for name in [
            "transport", "runtime-concurrency", "storage-workspaces", "command-boundaries",
            "applicationhost", "settings-shell", "thread-metadata", "thread-search", "git",
        ]],
        "adapters": [(name.replace("/", "-"), go + ["./tools/verification/" + name]) for name in [
            "claude", "codex", "opencode", "console-oauth", "artificialanalysis",
            "artificialanalysis/lifecycle", "maintenance",
        ]],
        "fixtures": [
            ("initial-response", go + ["./tools/verification/initial-response", "-output", fixtures["MOKUSEI_INITIAL_RESPONSE_FIXTURES"]]),
            ("moku", go + ["./tools/verification/moku"]),
            ("voice", go + ["./tools/verification/codex", "-voice-only"]),
            ("conversation", [args.go, "test", "-count=1", "./internal/hosts/applicationhost",
                              "-run", "^TestConversationProjectionCarriesCurrentSemanticDecoration$"]),
            ("harness-forms", go + ["./tools/verification/opencode/cases/renderer", "-forms-output", fixtures["MOKUSEI_HARNESS_FORM_FIXTURE"]]),
        ],
        "interop": [
            ("swift-deltas", go + ["./tools/verification/transport", "-swift-deltas"]),
            ("swift-files", go + ["./tools/verification/transport", "-swift-files"]),
            ("swift-settings", go + ["./tools/verification/transport", "-swift-settings-capacity"]),
            ("runtime-voice", go + ["./tools/verification/runtime", "-swift-voice"]),
            ("runtime-shutdown", go + ["./tools/verification/runtime-helpers", "--swift-shutdown"]),
            ("pi-usage", go + ["./tools/verification/pi", "-swift-usage", "-timeout", "10m"]),
            ("devtools", go + ["./tools/verification/devtools"]),
            ("swift-offline-client", go + ["./tools/verification/devtools", "-swift-offline-client"]),
            ("swift-concurrent-client", go + ["./tools/verification/devtools", "-swift-concurrent-client"]),
            ("headless-lifecycle", go + ["./tools/verification/release-health", "-only", "headless",
                                       "-output", str(output / "health")]),
        ],
        "native": [
            ("runtime-build", [args.go, "build", "-o", str(output / "mokusei-runtime"), "./cmd/mokusei-runtime"]),
            ("settings", go + ["./tools/verification/settings", "-runtime", str(output / "mokusei-runtime"),
                               "-artifacts", str(output / "settings")]),
            ("note-exposure", go + ["./tools/verification/moku", "-swift-note-exposure"]),
            *[(name, [sys.executable, "tools/verification/reading-presentation/run.py", "--" + name])
              for name in ["browser-dialogs", "application-navigation", "tag-glass-captures"]],
        ],
    }
    # Keep GUI work serial in each process/session, but spread independent
    # boundary replays across all five runners instead of two long tails.
    groups["interop-wire"] = groups["interop"][:6]
    groups["interop-process"] = groups["interop"][6:]
    groups["native-runtime"] = groups["native"][:3]
    groups["native-capture"] = [groups["native"][3], groups["native"][5]]
    groups["native-controls"] = [groups["native"][4],
        ("isolated-input", [sys.executable, "tools/verification/reading-presentation/run.py", "--isolated-input"]),
        ("scrollbars", [sys.executable, "tools/verification/scrollbars/run.py"]),
        ("model-selector", [sys.executable, "tools/verification/reading-presentation/run.py", "--model-selector"])]
    groups["native"].extend(groups["native-controls"][1:])
    if args.group == "fixtures":
        environment.update(fixtures)
    records = [{"name": name, "command": command, "status": "not_run", "log": name + ".log"}
               for name, command in groups[args.group]]
    report = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
              "dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=root)),
              "group": args.group, "checks": records}

    def save():
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")

    # A killed workflow must leave pending/running evidence, never a false pass.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("Replay runner terminated"))
    save()
    for record in records:
        record["status"] = "running"
        save()
        print("RUN", record["name"], flush=True)
        start = time.monotonic()
        try:
            with (output / record["log"]).open("w") as log:
                record["exit_code"] = deadline.run(record["command"], cwd=root, env=environment,
                                                   stdout=log, stderr=subprocess.STDOUT)
            record["status"] = "passed" if record["exit_code"] == 0 else "failed"
            text = (output / record["log"]).read_text(errors="replace")
            if re.search(r"Test Case '[^\n]+' skipped|[➜↷✘] Test [^\n]* skipped(?:[.:]| because)", text):
                record.update(status="failed", error="Replay skipped a required native test")
        except (OSError, TimeoutError, subprocess.TimeoutExpired) as error:
            record.update(status="failed", error=str(error))
        finally:
            record["seconds"] = round(time.monotonic() - start, 3)
            save()
        print(record["status"].upper(), record["name"], flush=True)
        if record["status"] != "passed":
            path = output / record["log"]
            # The log can exist but be empty when its execution limit kills a
            # newly started command. Always expose the runner's failure separately.
            message = f"{record['name']}: exit={record.get('exit_code')}, seconds={record['seconds']}, error={record.get('error', 'command failed')}"
            print(message, flush=True)
            print(path.read_text(errors="replace")[-12000:] if path.exists() else "No command log")
            if "GITHUB_STEP_SUMMARY" in os.environ:
                with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                    summary.write(f"\n### Replay failure: {record['name']}\n\n{message}\n\nLog: `{path}`\n")

    if any(record["status"] != "passed" for record in records):
        raise SystemExit(1)
    if args.group == "fixtures":
        for name, path in fixtures.items():
            if not Path(path).is_file() or not Path(path).stat().st_size:
                report.setdefault("errors", []).append("Fixture producer did not export " + name)
                save()
                raise SystemExit("Fixture producer did not export " + name)
        if "GITHUB_ENV" in os.environ:
            with open(os.environ["GITHUB_ENV"], "a") as stream:
                stream.writelines(f"{name}={path}\n" for name, path in fixtures.items())


if __name__ == "__main__":
    main()
