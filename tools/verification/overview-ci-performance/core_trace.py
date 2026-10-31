"""One fixed-product S4 execution trace; never a formal CPU comparison."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import path_control as control

reference = control.reference
OVERLAYS = Path(__file__).resolve().parent / "core_trace_overlays"
RUNTIME_PREFIX = "tools/verification/overview-ci-performance/runtime/"
ALLOWED_TARGETS = {RUNTIME_PREFIX + name for name in (
    "main.go", "source.go", "metrics.go", "core_trace_diagnostic.go", "core_trace_diagnostic_test.go")}


def validate_capture(receipt, captured, row):
    failures = []
    expected_path = row.get("namedLaunchEnvironment", {}).get("MOKUSEI_OVERVIEW_CORE_TRACE_PATH")
    core = row.get("result", {}).get("core", {})
    if (receipt.get("schemaVersion") != 1 or receipt.get("diagnosticKind") != "overview-core-execution-trace"
            or receipt.get("captureComplete") is not True or receipt.get("status") != "complete"):
        failures.append("Final trace receipt does not declare a complete supported capture")
    if receipt.get("tracePath") != expected_path or receipt.get("sidecarPath") != str(expected_path) + ".json":
        failures.append("Trace receipt path does not match this owned launch")
    size = captured.stat().st_size
    if (size <= 0 or receipt.get("traceBytes") != size or receipt.get("traceSHA256") != reference.digest(captured)
            or receipt.get("totalWriterBytes") != size or receipt.get("maximumTraceBytes") != 8 * 1024 * 1024
            or receipt.get("droppedTraceBytes") != 0 or receipt.get("overflow") is not False or receipt.get("writerError") != ""):
        failures.append("Trace content, writer accounting or fixed memory bound differs")
    if (receipt.get("measurementClockVersion") != reference.MEASUREMENT_CLOCK_VERSION
            or receipt.get("measurementClockID") != reference.MEASUREMENT_CLOCK_ID
            or receipt.get("clockOriginUptimeNanoseconds") != core.get("clockOriginUptimeNanoseconds")):
        failures.append("Trace clock does not match the actual Core result")
    start, stop = receipt.get("traceStart", {}), receipt.get("traceStop", {})
    values = [core.get("clockOriginUptimeNanoseconds"), start.get("beforeUptimeNanoseconds"),
              start.get("afterUptimeNanoseconds"), stop.get("beforeUptimeNanoseconds"), stop.get("afterUptimeNanoseconds")]
    if not all(type(value) is int and value > 0 for value in values) or values != sorted(values):
        failures.append("Trace lifecycle raw-clock brackets are missing or inconsistent")
        return failures
    anchors = receipt.get("rawAnchors")
    if (not isinstance(anchors, list) or receipt.get("rawAnchorCount") != len(anchors)
            or receipt.get("maximumRawAnchors") != 8192 or len(anchors) > 8192
            or receipt.get("rawAnchorClockErrors") != 0 or receipt.get("invalidIdentifiers") != 0):
        failures.append("Trace raw-anchor accounting is incomplete")
        return failures
    categories = Counter()
    identifiers = set()
    maximum_width = 0
    for anchor in anchors:
        before, after = anchor.get("rawBeforeNanoseconds"), anchor.get("rawAfterNanoseconds")
        if (type(before) is not int or type(after) is not int or not values[2] <= before <= after <= values[3]
                or anchor.get("clockError")):
            failures.append("Raw annotation bracket lies outside the actual trace lifecycle")
            break
        maximum_width = max(maximum_width, after - before)
        key = (anchor.get("category"), anchor.get("message"))
        if not all(isinstance(part, str) for part in key) or key in identifiers:
            failures.append("Raw annotation identifiers are missing or ambiguous")
            break
        identifiers.add(key); categories[key[0]] += 1
    if dict(categories) != {key: value for key, value in receipt.get("pointCounts", {}).items() if value != 0}:
        failures.append("Point counts do not match retained raw anchors")
    for name in ("overview.trace-start", "overview.trace-stop"):
        if categories[name] != 1:
            failures.append("Missing unique lifecycle trace annotation: " + name)
    spans = receipt.get("spanCounts", {})
    expected_spans = {"overview.source.wait", "overview.source.fifo-lock", "overview.source.fifo-clock",
                      "overview.source.receipt", "overview.worker.store-update", "overview.publisher.observer"}
    if set(spans) != expected_spans or any(type(value.get("started")) is not int or value["started"] < 0
            or value["started"] != value.get("ended") for value in spans.values()):
        failures.append("Trace regions did not close before capture completion")
    # Bracket widths remain evidence, not an excuse to silently shift a trace event.
    row["traceAnchorMaximumBracketNanoseconds"] = maximum_width
    row["traceAnnotationMappingVerified"] = False
    return failures


def apply_overlays(checkout, overlay_root=OVERLAYS):
    """The original thirteen-file harness is verified before these explicit diagnostic edits."""
    manifest = json.loads((overlay_root / "manifest.json").read_text())
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("files"), list):
        raise ValueError("Unsupported trace overlay manifest")
    entries = manifest["files"]
    targets = [entry["target"] for entry in entries]
    if len(targets) != len(set(targets)) or set(targets) != ALLOWED_TARGETS:
        raise ValueError("Diagnostic overlays must match the five reviewed runtime files")
    prepared = []
    for entry in entries:
        target = checkout / entry["target"]
        source = (overlay_root / entry["source"]).resolve(strict=True)
        if not source.is_relative_to(overlay_root.resolve()) or source.suffix != ".txt":
            raise ValueError("Overlay source leaves its reviewed directory")
        current = reference.digest(target) if target.is_file() else None
        if current != entry["beforeSHA256"]:
            raise ValueError("Unexpected original runtime input: " + entry["target"])
        if reference.digest(source) != entry["afterSHA256"]:
            raise ValueError("Diagnostic overlay content differs: " + entry["target"])
        prepared.append((entry, source, target))
    # Validate the entire edit set before changing any copied file.
    for entry, source, target in prepared:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if reference.digest(target) != entry["afterSHA256"]:
            raise ValueError("Copied diagnostic overlay differs: " + entry["target"])
    return {"manifestSHA256": reference.digest(overlay_root / "manifest.json"), "files": entries}


def save_report(output, report):
    reference.write_json(output / "report.json", report)
    row = report.get("run", {})
    trace = report.get("trace", {})
    lines = ["# Foreground Overview Core execution-trace diagnostic", "",
        "This is one instrumented S4 run, not an A/B experiment or a formal CPU baseline.", "",
        f"- Diagnostic status: **{report['status']}**",
        f"- Fixed measured product: `{control.PRODUCT}`",
        f"- Diagnostic checkout: `{report.get('diagnosticRevision', 'unavailable')}`",
        f"- Original source/clock validity: `{row.get('valid', 'not measured')}`",
        f"- Complete trace capture: `{trace.get('captureComplete', False)}`",
        f"- Original formal harness SHA before diagnostic overlays: `{control.HARNESS}`",
        f"- Effective instrumented harness SHA: `{report.get('effectiveHarness', {}).get('sha256', 'not built')}`", "",
        "The original N40/four visible running cards, 5s warmup, 20s S4 supply, 40 events/s,",
        "50ms source gate, clock checks and tail rules are unchanged. All measurement failures",
        "remain in run.json. Trace instrumentation and its memory/writer work can change GC and",
        "scheduling; a missing spike does not rule out an earlier cause. Instrumented CPU is",
        "not compared with any uninstrumented row. No QoS, App Nap or GC policy is changed.", "",
        "## Source / measurement failures", ""]
    lines += ["- " + str(reason) for reason in row.get("invalidReasons", [])] or ["- None recorded; inspect the full original validators in run.json."]
    lines += ["", "## Collection failures", ""]
    lines += ["- " + str(error) for error in report.get("errors", [])] or ["- None recorded."]
    lines += ["", "## Evidence", "", "The artifact retains the original product/harness identities, actual package",
        "and process receipts, source/publication/model events, core.trace, core.trace.json,",
        "decoded trace, scheduler/synchronization/syscall profiles, build/test logs and cleanup.",
        "Go trace captures its own runtime events; absent runtime activity alone does not identify",
        "the operating-system scheduler, effective QoS or App Nap. No automatic retry is used.", ""]
    (output / "report.md").write_text("\n".join(lines))


def decode_trace(path, output, budget):
    records = []
    arguments = ["go", "tool", "trace", "-d=parsed", str(path)]
    reference.command(arguments, output / "trace.parsed.txt", timeout=budget.remaining(90))
    records.append({"command": arguments, "file": "trace.parsed.txt", "sha256": reference.digest(output / "trace.parsed.txt")})
    for kind in ("sched", "sync", "syscall"):
        destination = output / (kind + ".pprof")
        error_path = output / (kind + "-profile.stderr.txt")
        arguments = ["go", "tool", "trace", "-pprof=" + kind, str(path)]
        with destination.open("wb") as stdout, error_path.open("wb") as stderr:
            result = subprocess.run(arguments, stdout=stdout, stderr=stderr, timeout=budget.remaining(60), check=False)
        records.append({"command": arguments, "exitCode": result.returncode, "file": destination.name,
                        "bytes": destination.stat().st_size, "sha256": reference.digest(destination)})
        if result.returncode != 0:
            reference.write_json(output / "decode.json", records)
            raise RuntimeError("Trace profile decode failed: " + kind)
        reference.command(["go", "tool", "pprof", "-top", str(destination)],
                          output / (kind + "-top.txt"), timeout=budget.remaining(60))
    reference.write_json(output / "decode.json", records)
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configure-display", action="store_true")
    parser.add_argument("--time-budget-seconds", type=int, default=1200)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "reportKind": "core-execution-trace", "status": "running",
              "startedAt": reference.utc(), "productRevision": control.PRODUCT,
              "performanceCertification": False, "errors": []}
    budget = reference.Budget(args.time_budget_seconds)
    temporary = tempfile.TemporaryDirectory(prefix="mokusei-core-trace-")
    work = Path(temporary.name).resolve(); checkout = work / "product"
    helper = work / "display-mode"; display_record = output / "display.json"
    replay = None; added_worktree = False
    save_report(output, report)
    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("This diagnostic requires macOS arm64")
        if args.configure_display and os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("Display configuration is restricted to disposable hosted runners")
        report["diagnosticRevision"] = reference.git(reference.ROOT, "rev-parse", "HEAD")
        report["driverSHA256"] = reference.digest(Path(__file__))
        files = [p for p in reference.SOURCE.rglob("*") if p.is_file() and
                 (p.suffix in (".swift", ".go") or p.name == "run.py")]
        files += [reference.ROOT / "tools/verification/native_replay.py", reference.ROOT / "tools/verification/NativeReplayIsolation.swift"]
        report["originalHarnessBeforeOverlay"] = reference.hash_files(reference.ROOT, files)
        if len(files) != 13 or report["originalHarnessBeforeOverlay"]["sha256"] != control.HARNESS:
            raise RuntimeError("The original formal thirteen-file harness changed")
        if reference.git(reference.ROOT, "rev-parse", control.PRODUCT + "^{commit}") != control.PRODUCT:
            raise RuntimeError("Fixed product commit is unavailable")
        report["machine"] = reference.machine_snapshot(full=True)
        source = work / "display-mode.swift"; source.write_text(reference.DISPLAY_SOURCE)
        reference.command(["xcrun", "swiftc", "-parse-as-library", str(source), "-o", str(helper)],
                          output / "display-build.log", timeout=budget.remaining(60))
        reference.command([str(helper), "prepare" if args.configure_display else "inspect", "unused", str(display_record)],
                          output / "display-prepare.log", timeout=budget.remaining(20))
        report["display"] = json.loads(display_record.read_text())
        confirmation = output / "display-after-helper-exit.json"
        reference.command([str(helper), "inspect", "unused", str(confirmation)], output / "display-confirm.log", timeout=budget.remaining(20))
        report["displayAfterHelperExit"] = json.loads(confirmation.read_text())
        build_dir = output / "build"
        reference.command(["git", "worktree", "add", "--detach", str(checkout), control.PRODUCT], build_dir / "checkout.log", timeout=budget.remaining(60))
        added_worktree = True
        for path in files:
            target = checkout / path.relative_to(reference.ROOT); target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        copied_files = [checkout / p.relative_to(reference.ROOT) for p in files]
        if reference.hash_files(checkout, copied_files) != report["originalHarnessBeforeOverlay"]:
            raise RuntimeError("Original copied harness differs")
        product = reference.product_identity(checkout)
        if product["sha256"] != control.PRODUCT_INPUTS:
            raise RuntimeError("Fixed product inputs differ from the declared 69c30 inventory")
        reference.write_json(build_dir / "product-inputs.json", product)
        report["diagnosticOverlays"] = apply_overlays(checkout)
        effective = list({*copied_files, *(checkout / entry["target"] for entry in report["diagnosticOverlays"]["files"])})
        report["effectiveHarness"] = reference.hash_files(checkout, effective)
        report["build"] = {"product": product, "configuration": "release", "swiftFlags": reference.SWIFT_FLAGS,
                           "productionBuildCount": 0, "runtimeBuildCount": 0, "probeCompileCount": 0}
        save_report(output, report)
        reference.command(["go", "test", "./tools/verification/overview-ci-performance/runtime"],
                          build_dir / "instrumented-go-contract-tests.log", cwd=checkout, timeout=budget.remaining(180))
        reference.command(["xcrun", "swift", "build", "--package-path", str(checkout / "app/macos"), "--configuration", "release",
            "--product", "Mokusei", "--force-resolved-versions", "--disable-index-store", "-Xswiftc", "-O", "-Xswiftc", "-enable-testing"],
            build_dir / "swift-build.log", cwd=checkout, timeout=budget.remaining(720))
        report["build"]["productionBuildCount"] = 1
        runtime = work / "runtime"
        reference.command(["go", "build", "-o", str(runtime), "./tools/verification/overview-ci-performance/runtime"],
                          build_dir / "go-build.log", cwd=checkout, timeout=budget.remaining(240))
        report["build"]["runtimeBuildCount"] = 1
        replay = reference.NativeReplay(checkout, control.APP_NAME, control.BUNDLE_ID, configuration="release")
        replay.acquire()
        sources = sorted((checkout / reference.SOURCE.relative_to(reference.ROOT)).glob("*.swift"))
        if not sources: raise RuntimeError("Swift probe sources missing")
        with reference.native_build_log(build_dir / "probe-build.log"), reference.time_limit(budget.remaining(120)):
            replay.compile(sources, extra_args=reference.SWIFT_FLAGS)
        report["build"]["probeCompileCount"] = 1
        shutil.copy2(runtime, replay.workspace / "runtime")
        report["packageBefore"] = control.package_receipt(replay, output / "package-before", budget)
        reference.write_json(build_dir / "build.json", report["build"])
        run_dir = output / "run"; run_dir.mkdir()
        row = {"id": "01-S4-trace", "condition": "S4", "valid": False, "status": "pending", "invalidReasons": ["Not run"]}
        report["run"] = row; save_report(output, report)
        original_launch = replay.run
        trace_path = replay.workspace / "evidence/core.trace"
        def launch_with_trace(arguments, **kwargs):
            named = {**kwargs.get("launch_environment", {}), "MOKUSEI_OVERVIEW_CORE_TRACE_PATH": str(trace_path)}
            kwargs["launch_environment"] = named
            kwargs["env"] = {**kwargs.get("env", os.environ), "MOKUSEI_OVERVIEW_CORE_TRACE_PATH": str(trace_path)}
            row["namedLaunchEnvironment"] = named
            return original_launch(arguments, **kwargs)
        replay.run = launch_with_trace
        control.run_cell(row, replay, report["packageBefore"], run_dir, budget)
        save_report(output, report)
        report["packageAfter"] = control.package_receipt(replay, output / "package-after", budget)
        if not control.same_payload(report["packageBefore"], report["packageAfter"]):
            raise RuntimeError("Staged payload changed during the diagnostic")
        if reference.product_identity(checkout) != product:
            raise RuntimeError("Product inputs changed during the diagnostic")
        if reference.hash_files(checkout, effective) != report["effectiveHarness"]:
            raise RuntimeError("Instrumented harness changed after build")
        captured = run_dir / "core.trace"; sidecar = run_dir / "core.trace.json"
        if not captured.is_file() or not sidecar.is_file():
            raise RuntimeError("Execution trace or final capture receipt is missing")
        report["trace"] = json.loads(sidecar.read_text())
        report["traceFile"] = {"bytes": captured.stat().st_size, "sha256": reference.digest(captured)}
        report["traceValidationFailures"] = validate_capture(report["trace"], captured, row)
        if report["traceValidationFailures"]:
            raise RuntimeError("Trace capture/identity validation failed: " + "; ".join(report["traceValidationFailures"]))
        report["decoders"] = decode_trace(captured, run_dir, budget)
        report["status"] = "trace captured; source valid" if row["valid"] else "trace captured; source invalid"
    except BaseException as error:
        report["status"] = "diagnostic failed"
        report["errors"].append(f"{type(error).__name__}: {error}")
        report["exception"] = traceback.format_exc()
        save_report(output, report)
    finally:
        if replay is not None:
            try: replay.close()
            except BaseException as error:
                report["errors"].append("Owned replay cleanup failed: " + str(error)); report["status"] = "diagnostic failed"
        if display_record.is_file():
            try:
                report["display"] = json.loads(display_record.read_text())
                if report["display"].get("changed") and helper.is_file():
                    reference.command([str(helper), "restore", str(display_record), str(output / "display-restored.json")],
                                      output / "display-restore.log", timeout=20)
            except BaseException as error:
                report["errors"].append("Display restore failed: " + str(error)); report["status"] = "diagnostic failed"
        if added_worktree:
            try: reference.command(["git", "worktree", "remove", "--force", str(checkout)], output / "build/cleanup.log", timeout=30)
            except BaseException as error:
                report["errors"].append("Owned worktree cleanup failed: " + str(error)); report["status"] = "diagnostic failed"
        temporary.cleanup(); report["finishedAt"] = reference.utc(); save_report(output, report)
        print("Overview Core trace:", report["status"], "—", output / "report.md", flush=True)
    # Collection success never changes row.valid and never certifies CPU performance.
    return 0 if report["status"].startswith("trace captured;") else 1


if __name__ == "__main__":
    raise SystemExit(main())
