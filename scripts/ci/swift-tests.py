"""Capture a full local run or audit the complete distributed CI run."""
import argparse
import json
from pathlib import Path
from swift_reporting import capture, summarize


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--run", action="store_true", help="Run and stream the complete local Swift suite")
    mode.add_argument("--full-log", type=Path, help="Validate an existing full-suite capture")
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
    results, errors, rows = summarize([("Full suite", path)])
    if record["exit_code"] != 0:
        errors.append(f"Full suite: swift test exit code {record['exit_code']} (null means interrupted).")
    (output_dir / "swift-summary.json").write_text(json.dumps({"runs": results, "errors": errors, "capture": record}, indent=2) + "\n")
    print("\n".join(rows))
    for error in errors:
        print("ERROR:", error)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
