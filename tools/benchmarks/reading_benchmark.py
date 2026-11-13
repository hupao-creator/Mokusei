#!/usr/bin/env python3
"""External Agent Thread reading benchmark over the shared artifact collectors."""
import argparse
import json
from pathlib import Path
import sys

from reading.corpus import BODY_KIB, DEFAULT_BODY_KIB
from reading.plan import SCENARIOS


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("conformance", help="portable reading protocol and scorer replays")
    build_command = commands.add_parser("build", help="build shared collectors and independent reading control")
    build_command.add_argument("--tools", type=Path, required=True)
    calibrate = commands.add_parser("calibrate", help="native normal/frozen/wrong/delayed/stalled scroll controls")
    calibrate.add_argument("--tools", type=Path, required=True)
    calibrate.add_argument("--output", type=Path, required=True)
    run = commands.add_parser("run", help="signed-production reading measurements")
    for name in ("app", "tools", "output"):
        run.add_argument("--" + name, type=Path, required=True)
    run.add_argument("--capabilities", type=Path)
    run.add_argument("--body-kib", type=int, nargs="+", choices=BODY_KIB, default=list(DEFAULT_BODY_KIB),
                     help="single-reply size in KiB (default: 8 32; 128 is an optional stress workload)")
    run.add_argument("--scenario", nargs="+", choices=SCENARIOS, default=list(SCENARIOS))
    run.add_argument("--mode", choices=("observed", "minimal"), default="observed")
    analyze = commands.add_parser("analyze", help="shared offline evidence analysis")
    analyze.add_argument("directory", type=Path)
    args = parser.parse_args()
    if args.command == "conformance":
        from reading.conformance import main as replay
        return replay()
    if args.command == "analyze":
        from analysis.report import write_report
        print(json.dumps(write_report(args.directory), indent=2))
        return 0
    if args.command == "run":
        if len(set(args.body_kib)) != len(args.body_kib):
            parser.error("repeat body sizes in separate experiment directories")
        if len(set(args.scenario)) != len(args.scenario):
            parser.error("repeat scenarios in separate experiment directories")
        if "reading.output-scroll" in args.scenario and args.scenario[-1] != "reading.output-scroll":
            parser.error("output-scroll must run last because it starts a subsequent execution")
    if sys.platform != "darwin":
        parser.error("live reading collection requires macOS")
    from build import build
    tools = build(args.tools.resolve())
    if args.command == "build":
        from reading.build import build_control
        print(build_control(tools))
        return 0
    if args.command == "calibrate":
        from reading.calibrate import calibrate as collect_controls
        result = collect_controls(tools, args.output.resolve())
        print(json.dumps(result, indent=2))
        return 0 if result["readingScroll"]["passed"] else 2
    from reading.runner import run_suite
    reports = run_suite(tools, args.app.resolve(), args.output.resolve(), args.body_kib,
                        args.scenario, args.mode,
                        args.capabilities.resolve() if args.capabilities else None)
    print(json.dumps([{key: row.get(key) for key in ("path", "measurement", "product", "comparison", "reasons")}
                      for row in reports], indent=2))
    return 0 if reports and all(row["measurement"] == "valid" and row["product"] == "passed" for row in reports) else 2


if __name__ == "__main__":
    raise SystemExit(main())
