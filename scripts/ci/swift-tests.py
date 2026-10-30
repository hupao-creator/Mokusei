"""Capture a full local run or audit the complete distributed CI run."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from swift_reporting import capture, summarize, terminal_methods
from swift_ownership import NATIVE_METHOD_OWNERS


def capture_native_owners(output_dir):
    """Use the existing producers, retaining each actual receipt and method outcome."""
    repo = Path(__file__).resolve().parents[2]
    destination = Path(tempfile.mkdtemp(prefix="native-", dir=output_dir))
    records, errors = [], []
    for group in sorted({owner["group"] for owner in NATIVE_METHOD_OWNERS.values()}):
        owners = {name: owner for name, owner in NATIVE_METHOD_OWNERS.items() if owner["group"] == group}
        checks = sorted({owner["check"] for owner in owners.values()})
        evidence = destination / ("ci-" + group)
        command = [sys.executable, str(repo / "scripts/ci/replays.py"), group, "--output", str(evidence)]
        for check in checks:
            command.extend(["--check", check])
        record = {"command": command, "exit_code": None, "report": str(evidence / "report.json")}
        records.append(record)
        try:
            record["exit_code"] = subprocess.run(command, cwd=repo).returncode
            report = json.loads((evidence / "report.json").read_text())
            record["checks"] = report["checks"]
            if (record["exit_code"] != 0 or report.get("errors") or report.get("group") != group
                    or report.get("selectedChecks") != checks
                    or sorted(check["name"] for check in report["checks"]) != checks):
                errors.append(f"{group}: native owner producer did not complete the requested checks.")
            observed = {name: [] for name in owners}
            for check in report["checks"]:
                log = (evidence / check["log"]).read_text(errors="replace")
                outcomes = terminal_methods(log, NATIVE_METHOD_OWNERS, errors, allow_other=True)
                for name, status in outcomes:
                    if name in observed:
                        observed[name].append((check["name"], status))
                    else:
                        errors.append(f"{group}: native method executed outside its declared group: {name}")
                if check["status"] != "passed" or check.get("exit_code") != 0:
                    errors.append(f"{group}/{check['name']}: missing successful native process receipt.")
                for name, owner in owners.items():
                    if check["name"] == owner["check"] and owner["marker"] not in log:
                        errors.append(f"{name}: missing required native execution marker {owner['marker']}.")
            record["outcomes"] = observed
            for name, owner in owners.items():
                if observed[name] != [(owner["check"], "passed")]:
                    errors.append(f"{name}: expected exactly one passing outcome from {owner['check']}; got {observed[name]}.")
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append(f"{group}: incomplete native owner evidence: {error}")
    return records, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run", action="store_true", help="Run ordinary Swift tests and their mandatory native owners")
    mode.add_argument("--full-log", type=Path, help="Validate an existing Swift log (does not certify native owner execution)")
    parser.add_argument("--exit-code", type=int, help="Actual process status for --full-log")
    parser.add_argument("--output-dir", type=Path, help="Local evidence directory (default: .build/check-swift)")
    args = parser.parse_args()
    if args.full_log is not None and args.exit_code is None:
        parser.error("--full-log requires its actual --exit-code")
    if args.full_log is None and args.exit_code is not None:
        parser.error("--exit-code requires --full-log")
    if not args.run and args.full_log is None:
        if args.output_dir is not None:
            parser.error("--output-dir requires --run or --full-log")
        from swift_coverage import main as audit_ci
        return audit_ci()

    output_dir = (args.output_dir or Path(".build/check-swift")).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    if args.run:
        path, record = capture(output_dir)
    else:
        path = args.full_log.resolve()
        record = {"command": None, "exit_code": args.exit_code, "log": str(path)}
    results, errors, rows = summarize([("Ordinary Swift suite" if args.run else "Captured Swift log", path)])
    if record["exit_code"] != 0:
        errors.append(f"Swift test exit code {record['exit_code']} (null means interrupted).")
    native = []
    if args.run:
        if path.is_file() and terminal_methods(path.read_text(errors="replace"), NATIVE_METHOD_OWNERS, errors, allow_other=True):
            errors.append("Ordinary Swift run executed a method assigned exclusively to its native owner.")
        native, native_errors = capture_native_owners(output_dir)
        errors.extend(native_errors)
        rows.append(f"Mandatory native owners: {len(NATIVE_METHOD_OWNERS)} methods; actual receipts, passing outcomes and execution markers required.")
    else:
        rows.append("Log-only validation does not certify mandatory native owners; use --run for the complete local check.")
    (output_dir / "swift-summary.json").write_text(json.dumps({"runs": results, "errors": errors, "capture": record,
                                                              "native": native}, indent=2) + "\n")
    print("\n".join(rows))
    for error in errors:
        print("ERROR:", error)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
