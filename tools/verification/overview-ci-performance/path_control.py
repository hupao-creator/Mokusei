"""Diagnostic only: fixed product/payload, repeated or alternating staged paths."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import sys
import tempfile
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run as reference

PRODUCT = "69c30b9a3356ca3a5c9a4de9ce78f1b683960125"
PRODUCT_INPUTS = "cb0f8221d4f679a4e5e2bb9df84e24a21a504e6832de32cf29fe7b3f3dc0c2b9"
HARNESS = "7da390645f45624de3f8e77da8472387bb292e9c92c5544de8c59812917e7254"
APP_NAME = "OverviewPerformanceProbe"
BUNDLE_ID = "com.mokusei.overview-performance"
GROUPS = (("D_AB", (("A", "P"), ("B", "Q"))),
          ("S_AB", (("A", "P"), ("B", "P"))),
          ("S_BA", (("B", "Q"), ("A", "Q"))),
          ("D_BA", (("B", "Q"), ("A", "P"))))


def planned_runs():
    rows = []
    for group, cells in GROUPS:
        for label, package in cells:
            rows.append({"id": f"{len(rows)+1:02d}-{group}-{label}-{package}",
                         "group": group, "logicalLabel": label, "package": package,
                         "condition": "S4"})
    return rows


def app_manifest(application):
    """Content and permission inventory; symbolic links stay symbolic links."""
    application = application.resolve(strict=True)
    entries = {".": {"kind": "directory", "mode": stat.S_IMODE(application.stat().st_mode)}}
    for directory, subdirectories, files in os.walk(application, followlinks=False):
        for name in sorted(subdirectories + files):
            path = Path(directory) / name
            details = path.lstat()
            record = {"mode": stat.S_IMODE(details.st_mode)}
            if path.is_symlink():
                target = path.resolve(strict=True)
                if not target.is_relative_to(application):
                    raise ValueError("Application symlink leaves the staged bundle: " + str(path))
                record.update(kind="symlink", target=os.readlink(path))
            elif stat.S_ISREG(details.st_mode):
                record.update(kind="file", bytes=details.st_size, sha256=reference.digest(path))
            elif stat.S_ISDIR(details.st_mode):
                record.update(kind="directory")
            else:
                raise ValueError("Unexpected staged application node: " + str(path))
            entries[str(path.relative_to(application))] = record
    canonical = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": hashlib.sha256(canonical).hexdigest(), "entries": entries,
            "algorithm": "sha256 of sorted compact JSON relative-path/node-kind/permission/content manifest"}


def verify_replay_locations(replay):
    root = replay.root.resolve(strict=True)
    expected_app = root / (APP_NAME + ".app")
    expected_workspace = root / "workspace"
    expected_executable = expected_app / "Contents/MacOS" / APP_NAME
    if (replay.application != expected_app or replay.workspace != expected_workspace or
            replay.executable != expected_executable or
            replay.manifest.get("root") != str(root) or
            replay.manifest.get("workspace") != str(expected_workspace)):
        raise ValueError("NativeReplay locations do not describe this physical package")
    resources = expected_app / "Contents/Resources"
    actual = sorted(str(path) for path in resources.glob("*.bundle"))
    declared = replay.manifest.get("resourceBundles")
    if (not actual or not isinstance(declared, list) or sorted(declared) != actual or
            any(not Path(path).resolve(strict=True).is_relative_to(expected_app) for path in actual)):
        raise ValueError("Resource bundle manifest does not describe this package's actual resources")
    with (expected_app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleExecutable") != APP_NAME:
        raise ValueError("The fixed app bundle identity changed")
    return {"root": str(root), "application": str(expected_app), "workspace": str(expected_workspace),
            "executable": str(expected_executable), "bundleIdentifier": info["CFBundleIdentifier"],
            "resourceBundles": actual,
            "uiFile": reference.file_identity(expected_executable),
            "coreFile": reference.file_identity(expected_workspace / "runtime")}


def clone_payload(source, destination):
    """Q's constructor stages its own locations, then receives P's signed bytes."""
    if source.root == destination.root:
        raise ValueError("P and Q must have independent staging directories")
    shutil.rmtree(destination.application)
    shutil.copytree(source.application, destination.application, symlinks=True, copy_function=shutil.copy2)
    shutil.copy2(source.workspace / "runtime", destination.workspace / "runtime")
    # Never copy P's manifest or call destination.compile/codesign --sign.
    for replay in (source, destination):
        verify_replay_locations(replay)
    if (reference.same_existing_file(source.executable, destination.executable) or
            reference.same_existing_file(source.workspace / "runtime", destination.workspace / "runtime")):
        raise ValueError("P and Q payloads must be separate physical files, not hard links")
    count = 0
    for path in source.application.rglob("*"):
        if path.is_file() and not path.is_symlink():
            other = destination.application / path.relative_to(source.application)
            if reference.same_existing_file(path, other):
                raise ValueError("P/Q application resource is a hard link: " + str(path.relative_to(source.application)))
            count += 1
    return {"appRegularFilePairsCompared": count, "allSeparatePhysicalFiles": True,
            "coreSeparatePhysicalFile": True, "copyMethod": "copytree(symlinks=True, copy2) plus copy2(Core); no recompile or re-sign"}


def core_signature(executable, output, budget):
    """Observe the original Go output; never add or replace its code signature."""
    log = output / "core-codesign-display.log"
    try:
        reference.command(["/usr/bin/codesign", "--display", "--verbose=4", str(executable)],
                          log, timeout=budget.remaining(15))
    except RuntimeError as error:
        # The original builder does not explicitly codesign its Go executable.
        # Preserve an unsigned original as unsigned instead of modifying bytes.
        if getattr(error, "overview_exit_code", None) == 1 and log.is_file() and "code object is not signed at all" in log.read_text():
            return {"status": "unsigned", "displayExitCode": 1}
        raise
    display = log.read_text()
    cdhash = re.search(r"^CDHash=([0-9a-f]+)$", display, re.MULTILINE)
    identifier = re.search(r"^Identifier=(.+)$", display, re.MULTILINE)
    if not cdhash or not identifier:
        raise ValueError("Core signature metadata is neither verified nor explicitly unsigned")
    reference.command(["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(executable)],
                      output / "core-codesign-verify.log", timeout=budget.remaining(15))
    return {"status": "verified", "displayExitCode": 0, "cdHash": cdhash.group(1), "identifier": identifier.group(1)}


def package_receipt(replay, output, budget):
    """Run only before the matrix or after every measured process has stopped."""
    locations = verify_replay_locations(replay)
    output.mkdir(parents=True, exist_ok=True)
    reference.command(["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", str(replay.application)],
                      output / "codesign-verify.log", timeout=budget.remaining(30))
    reference.command(["/usr/bin/codesign", "--display", "--verbose=4", str(replay.application)],
                      output / "codesign-display.log", timeout=budget.remaining(15))
    display = (output / "codesign-display.log").read_text()
    cdhash = re.search(r"^CDHash=([0-9a-f]+)$", display, re.MULTILINE)
    identifier = re.search(r"^Identifier=(.+)$", display, re.MULTILINE)
    if not cdhash or not identifier or identifier.group(1) != BUNDLE_ID:
        raise ValueError("Signed application identity is missing or differs from the fixed bundle ID")
    receipt = {**locations, "uiSHA256": reference.digest(replay.executable),
               "coreSHA256": reference.digest(replay.workspace / "runtime"),
               "appManifest": app_manifest(replay.application),
               "signature": {"verifiedDeepStrict": True, "cdHash": cdhash.group(1),
                             "identifier": identifier.group(1)},
               "coreSignature": core_signature(replay.workspace / "runtime", output, budget),
               "observedAt": reference.utc(),
               "measurementTiming": "outside all warmup/formal/tail CPU intervals"}
    reference.write_json(output / "identity.json", receipt)
    return receipt


def same_payload(left, right):
    keys = ("uiSHA256", "coreSHA256", "appManifest", "signature", "coreSignature")
    if not isinstance(left, dict) or not isinstance(right, dict):
        return False
    for value in (left, right):
        if any(not isinstance(value.get(key), str) or not re.fullmatch(r"[0-9a-f]{64}", value[key])
               for key in ("uiSHA256", "coreSHA256")):
            return False
        if (not isinstance(value.get("appManifest"), dict) or not value["appManifest"].get("entries") or
                not isinstance(value["appManifest"].get("sha256"), str) or
                not re.fullmatch(r"[0-9a-f]{64}", value["appManifest"]["sha256"]) or
                not isinstance(value.get("signature"), dict) or value["signature"].get("verifiedDeepStrict") is not True or
                value["signature"].get("identifier") != BUNDLE_ID or not value["signature"].get("cdHash") or
                not isinstance(value.get("coreSignature"), dict) or
                value["coreSignature"].get("status") not in ("verified", "unsigned")):
            return False
        core = value["coreSignature"]
        if core["status"] == "verified" and (core.get("displayExitCode") != 0 or not core.get("cdHash") or not core.get("identifier")):
            return False
        if core["status"] == "unsigned" and core.get("displayExitCode") != 1:
            return False
    return all(left[key] == right[key] for key in keys)


def group_results(rows):
    groups = []
    for name, cells in GROUPS:
        found = [row for row in rows if row.get("group") == name]
        selected = {row.get("logicalLabel"): row for row in found}
        group = {"id": name, "mapping": [{"logicalLabel": label, "package": package} for label, package in cells],
                 "valid": False, "invalidReasons": [], "differenceMeaning": "logical B minus logical A; same product, never a product speedup"}
        expected = {label: package for label, package in cells}
        if len(found) != 2 or set(selected) != {"A", "B"}:
            group["invalidReasons"].append("A prescribed diagnostic cell is missing")
        else:
            left, right = selected["A"], selected["B"]
            group.update(logicalARun=left["id"], logicalBRun=right["id"])
            if (any(selected[label].get("package") != package for label, package in expected.items()) or
                    [(row.get("logicalLabel"), row.get("package")) for row in found] != list(cells)):
                group["invalidReasons"].append("Actual package mapping differs from the prespecified plan")
            if not all(row.get("valid") is True for row in found):
                group["invalidReasons"].append("A prescribed diagnostic cell is invalid")
            if left.get("powerBefore") != right.get("powerBefore"):
                group["invalidReasons"].append("Power sources differ")
            li, ri = reference.object_value(left.get("result")), reference.object_value(right.get("result"))
            if not li.get("comparisonIdentity") or li.get("comparisonIdentity") != ri.get("comparisonIdentity"):
                group["invalidReasons"].append("Actual fixture/window/camera/display identities differ")
            av, bv = reference.cpu_values(left), reference.cpu_values(right)
            if not all(reference.numeric(value) for value in (*av, *bv)):
                group["invalidReasons"].append("A diagnostic cell has incomplete formal CPU")
            for key, a, b in zip(("uiDeltaPP", "coreDeltaPP", "totalDeltaPP"), av, bv):
                if reference.numeric(a) and reference.numeric(b):
                    group[key] = b - a
            af = reference.object_value(reference.object_value(li.get("uiWindows")).get("sourceThroughTailObservation")).get("cpuSeconds")
            bf = reference.object_value(reference.object_value(ri.get("uiWindows")).get("sourceThroughTailObservation")).get("cpuSeconds")
            if reference.numeric(af) and reference.numeric(bf) and af > 0:
                group.update(fullUICPUSecondsDelta=bf-af, fullUICPUPercentChange=100*(bf-af)/af)
            else:
                group["invalidReasons"].append("A diagnostic cell has incomplete full-work UI CPU")
            group["valid"] = not group["invalidReasons"]
        groups.append(group)
    return groups


def report_markdown(report):
    lines = ["# Overview staged-path diagnostic control", "", f"Status: **{report['status']}**.", "",
             "This is a fixed-product control, not a candidate performance certification. One build is copied into P and Q. "
             "The copies keep the same bundle ID; every run uses a new UI/Core process and profile. "
             "Both registered copies remain present in same-path cells. A/B are logical cell labels only.", "",
             f"- Product: `{PRODUCT}`; expected product-input SHA256: `{PRODUCT_INPUTS}`.",
             f"- Expected common 13-file harness SHA256: `{HARNESS}`.",
             f"- Diagnostic checkout: `{report.get('controlRevision', 'unavailable')}`.",
             "- S4 only, N40/K4, 5s load-bearing warmup + 20s formal supply; unchanged raw-clock/source/FIFO/50ms gates.",
             "- No QoS, App Nap, bundle ID, activation order, source timing, retry or tail-budget changes.", "",
             "## Actual package identities", "", "| Package | Application | UI SHA256 | Core SHA256 | CDHash |",
             "| --- | --- | --- | --- | --- |"]
    for name, data in report.get("packages", {}).items():
        identity = data.get("before", {})
        lines.append(f"| {name} | `{identity.get('application', '—')}` | `{identity.get('uiSHA256', '—')}` | "
                     f"`{identity.get('coreSHA256', '—')}` | `{identity.get('signature', {}).get('cdHash', '—')}` |")
    lines += ["", "## All raw process results", "", "CPU percentages use each process's actual raw-clock interval. "
              "Full UI includes warmup and the existing model-stability tail; do not sum it with Core formal seconds.", "",
              "| Run | Label / actual package | Valid | UI CPU s / wall s | UI % | Core CPU s / wall s | Core % | Full UI CPU s | Tail UI CPU s |",
              "| --- | --- | --- | --- | ---: | --- | ---: | ---: | ---: |"]
    num = reference.number
    for row in report["runs"]:
        result = reference.object_value(row.get("result")); core = reference.object_value(result.get("core"))
        ui = reference.object_value(result.get("ui")); cpu = reference.object_value(core.get("cpu"))
        windows = reference.object_value(result.get("uiWindows"))
        lines.append(f"| {row['id']} | {row['logicalLabel']} / {row['package']} | {row.get('valid', False)} | "
                     f"{num(ui.get('cpuSeconds'),6)} / {num(ui.get('wallSeconds'),6)} | {num(ui.get('cpuPercent'),6)} | "
                     f"{num(cpu.get('cpuSeconds'),6)} / {num(cpu.get('wallSeconds'),6)} | {num(cpu.get('cpuPercent'),6)} | "
                     f"{num(reference.object_value(windows.get('sourceThroughTailObservation')).get('cpuSeconds'),6)} | "
                     f"{num(reference.object_value(windows.get('tailObservation')).get('cpuSeconds'),6)} |")
    lines += ["", "## Prespecified groups", "", "Invalid group differences remain descriptive only.", "",
              "| Group | Actual path sequence | Valid | UI B−A pp | Core B−A pp | Full UI B−A s | Full UI B−A % |",
              "| --- | --- | --- | ---: | ---: | ---: | ---: |"]
    for group in report["groups"]:
        sequence = " → ".join(x["package"] for x in group["mapping"])
        lines.append(f"| {group['id']} | {sequence} | {group['valid']} | {num(group.get('uiDeltaPP'),6)} | "
                     f"{num(group.get('coreDeltaPP'),6)} | {num(group.get('fullUICPUSecondsDelta'),6)} | "
                     f"{num(group.get('fullUICPUPercentChange'),6)} |")
    lines += ["", "## Source, model work and sampled memory", "",
              "| Run | planned/enqueued/dequeued/sent/accepted | enqueue max ms / late indices | legacy sent max ms / late indices | formal pubs / D | model seq at formal end / tail installs | footprint start/end/max bytes | mount ms |",
              "| --- | --- | --- | --- | --- | --- | --- | ---: |"]
    for row in report["runs"]:
        result = reference.object_value(row.get("result")); core = reference.object_value(result.get("core"))
        source = reference.object_value(core.get("source")); enq = reference.object_value(source.get("enqueueDeadline"))
        sent = reference.object_value(source.get("legacySentDeadline")); formal = reference.object_value(reference.object_value(core.get("windows")).get("formal"))
        ui = reference.object_value(result.get("ui")); flow = report["modelFlow"][row["id"]]
        counts = "/".join(str(source.get(key, "—")) for key in ("planned", "enqueued", "dequeued", "sent", "accepted"))
        memory = "/".join(str(ui.get(key, "—")) for key in ("footprintStartBytes", "footprintEndBytes", "footprintMaxSampledBytes"))
        lines.append(f"| {row['id']} | {counts} | {num(enq.get('maxLatenessMilliseconds'),6)} / {enq.get('exceededIndices', '—')} | "
                     f"{num(sent.get('maxLatenessMilliseconds'),6)} / {sent.get('exceededIndices', '—')} | "
                     f"{formal.get('publishes','—')} / {num(formal.get('dirtyCardMean'),6)} | "
                     f"{flow.get('formalEndSequences','—')} / {flow.get('postFormalInstallCount','—')} | {memory} | "
                     f"{num(result.get('mountAndSettleMilliseconds'),6)} |")
    lines += ["", "## Failures and limitations", ""]
    if report.get("failure"):
        lines.append("Execution failure: " + json.dumps(report["failure"], ensure_ascii=False))
    for row in report["runs"]:
        for reason in row.get("invalidReasons", []):
            lines.append(f"- `{row['id']}`: {reason}")
    for error in report.get("errors", []):
        lines.append("- " + error)
    lines += ["- No automatic rerun or threshold relaxation. Missing or invalid rows are not replaced.",
              "- A green same-path cell does not prove a fix. If the same-runner dual-path reference does not reproduce the phenomenon, attribution remains unresolved.",
              "- Fixed source seed does not fix the production cloud's random seed/phase. No formal present count, GPU time or WindowServer pixels are collected.",
              "- Existing lightweight receipts/visibility observation remain part of process CPU. Full hashes and signature checks happen outside every measured process.",
              "- These data neither calibrate previous runner CPU values nor retroactively validate historical failures.",
              "- Exact/coalesced source and model-flow records, original per-run JSON, complete logs and identity receipts remain in this artifact.", ""]
    return "\n".join(lines)


def save_report(output, report):
    report["groups"] = group_results(report["runs"])
    report["modelFlow"] = {row["id"]: reference.model_flow(row.get("result", {})) for row in report["runs"]}
    report["sourceFlow"] = {row["id"]: reference.source_flow(row.get("result", {})) for row in report["runs"]}
    reference.write_json(output / "report.json", report)
    (output / "report.md").write_text(report_markdown(report))


def run_cell(row, replay, identity, output, budget):
    """All original validators and owned-process cleanup use the actual package."""
    row.update(status="running", valid=False, invalidReasons=[], startedAt=reference.utc(),
               expectedPackage={key: identity[key] for key in ("root", "application", "workspace", "executable",
                   "bundleIdentifier", "resourceBundles", "uiFile", "coreFile", "uiSHA256", "coreSHA256", "signature", "coreSignature")})
    abort = None
    try:
        # A failed previous-process stop must abort before its receipt is erased.
        try:
            replay.stop()
        except BaseException as error:
            abort = error
            raise
        for name in ("launch.json", "runtime-isolation.json", "result.json", "stdout.log", "stderr.log", "cleanup.json"):
            (replay.root / name).unlink(missing_ok=True)
        replay.stopped_pids.clear(); replay.process = None
        evidence = replay.workspace / "evidence"
        if evidence.exists(): shutil.rmtree(evidence)
        evidence.mkdir()
        result_path = evidence / "ui-result.json"
        before = reference.machine_snapshot()
        reference.write_json(output / "machine-before.json", before)
        row["powerBefore"] = reference.power_source(before)
        row["packageLocations"] = verify_replay_locations(replay)
        for key in ("uiFile", "coreFile"):
            if row["packageLocations"][key] != identity[key]:
                raise ValueError("Staged physical payload changed before this launch: " + key)
        arguments = ["--condition", "S4", "--n", "40", "--warmup", "5", "--seconds", "20",
                     "--runtime", str(replay.workspace / "runtime"), "--output", str(result_path)]
        row["command"] = arguments
        row["exitCode"] = replay.run(arguments, timeout=budget.remaining(90), launch_services=True,
            env={**os.environ, "NSUnbufferedIO": "YES"}, launch_environment={"NSUnbufferedIO": "YES"})
        startup_path = replay.root / "runtime-isolation.json"
        if startup_path.is_file():
            row["startupIdentity"] = json.loads(startup_path.read_text())
            row["invalidReasons"].extend(reference.validate_startup(row["startupIdentity"], replay, arguments))
        else:
            row["invalidReasons"].append("Missing fresh native startup identity receipt")
        if result_path.is_file():
            decoded = json.loads(result_path.read_text())
            if not isinstance(decoded, dict):
                row["malformedResult"] = decoded
                raise ValueError("UI result is not a JSON object; original file retained")
            row["result"] = decoded
            row["invalidReasons"].extend(reference.validate_result(decoded, "S4", 20))
            process = reference.object_value(decoded.get("runtimeProcess"))
            actual, failures = reference.validate_runtime_identity(process, row.get("startupIdentity", {}), replay.workspace / "runtime")
            row["runtimeIdentity"] = actual; row["invalidReasons"].extend(failures)
        else:
            row["invalidReasons"].append("Missing UI result; exit code alone cannot certify a diagnostic cell")
        if row["exitCode"] != 0:
            row["invalidReasons"].append("Probe process returned " + str(row["exitCode"]))
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        row["invalidReasons"].append(str(error))
        row["exception"] = {"type": type(error).__name__, "message": str(error), "traceback": traceback.format_exc()}
    except BaseException as error:
        abort = error
        row["invalidReasons"].append(f"Unexpected {type(error).__name__}: {error}")
        row["exception"] = {"type": type(error).__name__, "message": str(error), "traceback": traceback.format_exc()}
    finally:
        for description, cleanup in (("Owned app cleanup", replay.stop),
                ("Owned runtime cleanup", lambda: reference.cleanup_runtime(replay, output)),
                ("Native evidence export", lambda: replay.export(output))):
            try:
                cleanup()
            except BaseException as error:
                abort = abort or error
                row["invalidReasons"].append(description + " failed: " + str(error))
        try:
            after = reference.machine_snapshot()
            reference.write_json(output / "machine-after.json", after)
            row["powerAfter"] = reference.power_source(after)
        except BaseException as error:
            abort = abort or error
            row["invalidReasons"].append("Post-process observation failed: " + str(error))
        if row.get("powerBefore") is None or row.get("powerBefore") != row.get("powerAfter"):
            row["invalidReasons"].append("Power source unknown or changed during this process")
        row["valid"] = not row["invalidReasons"]
        row["status"] = "valid" if row["valid"] else "invalid"
        row["finishedAt"] = reference.utc()
        reference.write_json(output / "run.json", row)
    if abort is not None:
        raise abort
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configure-display", action="store_true")
    parser.add_argument("--time-budget-seconds", type=int, default=1500)
    args = parser.parse_args()
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=False)
    report = {"schemaVersion": 1, "reportKind": "staged-path-control", "status": "running",
              "startedAt": reference.utc(), "productRevision": PRODUCT, "plan": planned_runs(),
              "sourceProtocolVersion": reference.SOURCE_PROTOCOL_VERSION,
              "sourceQueueCapacity": reference.SOURCE_QUEUE_CAPACITY,
              "measurementClockVersion": reference.MEASUREMENT_CLOCK_VERSION,
              "measurementClockID": reference.MEASUREMENT_CLOCK_ID,
              "runs": [], "packages": {}, "errors": []}
    budget = reference.Budget(args.time_budget_seconds)
    temporary = tempfile.TemporaryDirectory(prefix="mokusei-path-control-")
    work = Path(temporary.name).resolve(); checkout = work / "product"
    helper = work / "display-mode"; display_record = output / "display.json"
    packages = {}; added_worktree = False
    save_report(output, report)
    try:
        if platform.system() != "Darwin" or platform.machine() != "arm64":
            raise RuntimeError("This diagnostic requires real macOS arm64; no emulated baseline")
        if args.configure_display and os.environ.get("GITHUB_ACTIONS") != "true":
            raise RuntimeError("Display configuration is restricted to disposable GitHub Actions runners")
        report["controlRevision"] = reference.git(reference.ROOT, "rev-parse", "HEAD")
        report["controlSourceSHA256"] = reference.digest(Path(__file__))
        files = [p for p in reference.SOURCE.rglob("*") if p.is_file() and
                 (p.suffix in (".swift", ".go") or p.name == "run.py")]
        files += [reference.ROOT / "tools/verification/native_replay.py", reference.ROOT / "tools/verification/NativeReplayIsolation.swift"]
        report["harness"] = reference.hash_files(reference.ROOT, files)
        if report["harness"]["sha256"] != HARNESS or len(files) != 13:
            raise RuntimeError("The original 13-file measurement harness changed")
        if reference.git(reference.ROOT, "rev-parse", PRODUCT + "^{commit}") != PRODUCT:
            raise RuntimeError("Fixed control product is unavailable")
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
        reference.command(["git", "worktree", "add", "--detach", str(checkout), PRODUCT], build_dir / "checkout.log", timeout=budget.remaining(60))
        added_worktree = True
        for path in files:
            target = checkout / path.relative_to(reference.ROOT); target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)
        copied = reference.hash_files(checkout, [checkout / p.relative_to(reference.ROOT) for p in files])
        if copied != report["harness"]: raise RuntimeError("Copied common measurement harness differs")
        product = reference.product_identity(checkout)
        if product["sha256"] != PRODUCT_INPUTS: raise RuntimeError("Fixed product inputs differ from the declared 69c30 inventory")
        report["build"] = {"product": product, "harnessSHA256": HARNESS, "configuration": "release", "swiftFlags": reference.SWIFT_FLAGS,
                           "productionBuildCount": 0, "runtimeBuildCount": 0, "probeCompileCount": 0,
                           "countMeaning": "successful builds only; attempted commands and failures have separate receipts"}
        reference.write_json(build_dir / "product-inputs.json", product); save_report(output, report)
        reference.command(["xcrun", "swift", "build", "--package-path", str(checkout / "app/macos"), "--configuration", "release",
            "--product", "Mokusei", "--force-resolved-versions", "--disable-index-store", "-Xswiftc", "-O", "-Xswiftc", "-enable-testing"],
            build_dir / "swift-build.log", cwd=checkout, timeout=budget.remaining(720))
        report["build"]["productionBuildCount"] = 1
        runtime = work / "runtime"
        reference.command(["go", "build", "-o", str(runtime), "./tools/verification/overview-ci-performance/runtime"],
                          build_dir / "go-build.log", cwd=checkout, timeout=budget.remaining(240))
        report["build"]["runtimeBuildCount"] = 1
        p = reference.NativeReplay(checkout, APP_NAME, BUNDLE_ID, configuration="release"); packages["P"] = p; p.acquire()
        sources = sorted((checkout / reference.SOURCE.relative_to(reference.ROOT)).glob("*.swift"))
        if not sources: raise RuntimeError("Swift measurement sources missing")
        probe_build = {"sources": list(map(str, sources)), "swiftFlags": reference.SWIFT_FLAGS,
                       "configuration": "release", "startedAt": reference.utc(), "succeeded": False}
        try:
            with reference.native_build_log(build_dir / "probe-build.log"), reference.time_limit(budget.remaining(120)):
                p.compile(sources, extra_args=reference.SWIFT_FLAGS)
            probe_build["succeeded"] = True
            report["build"]["probeCompileCount"] = 1
        except BaseException as error:
            error.overview_log = build_dir / "probe-build.log"
            probe_build["command"] = getattr(error, "cmd", None)
            probe_build["exitCode"] = getattr(error, "returncode", None)
            raise
        finally:
            probe_build["finishedAt"] = reference.utc()
            reference.write_json(build_dir / "probe-build.json", probe_build)
        shutil.copy2(runtime, p.workspace / "runtime")
        q = reference.NativeReplay(checkout, APP_NAME, BUNDLE_ID, configuration="release"); packages["Q"] = q
        report["copyIdentity"] = clone_payload(p, q)
        for name, replay in packages.items():
            report["packages"][name] = {"before": package_receipt(replay, output / "packages" / name / "before", budget)}
        if not same_payload(report["packages"]["P"]["before"], report["packages"]["Q"]["before"]):
            raise RuntimeError("P/Q binaries, full resources or signed identities differ")
        report["payloadsEqualBefore"] = True
        reference.write_json(build_dir / "build.json", report["build"]); save_report(output, report)
        for plan in report["plan"]:
            print("PATH_CONTROL", plan["id"], flush=True)
            run_dir = output / "runs" / plan["id"]; run_dir.mkdir(parents=True)
            row = {**plan, "valid": False, "status": "pending", "invalidReasons": ["Diagnostic cell has not completed"]}
            # Attach before launch so an exception or cleanup failure cannot erase this cell.
            report["runs"].append(row); save_report(output, report)
            run_cell(row, packages[plan["package"]], report["packages"][plan["package"]]["before"], run_dir, budget)
            save_report(output, report)
        for name, replay in packages.items():
            after = package_receipt(replay, output / "packages" / name / "after", budget)
            report["packages"][name]["after"] = after
            if not same_payload(report["packages"][name]["before"], after):
                raise RuntimeError("Staged payload changed during the matrix: " + name)
        if reference.product_identity(checkout) != product: raise RuntimeError("Product inputs changed during the diagnostic")
        report["payloadsEqualAfter"] = same_payload(report["packages"]["P"]["after"], report["packages"]["Q"]["after"])
        if report["payloadsEqualAfter"] is not True: raise RuntimeError("P/Q payloads differ after the matrix")
        report["status"] = "completed" if all(group["valid"] for group in group_results(report["runs"])) else "invalid measurements"
        if report["status"] != "completed": report["errors"].append("A prescribed diagnostic cell/group is invalid; original evidence retained without retry")
    except BaseException as error:
        report["status"] = "failed"; reference.record_failure(output, report, error)
    finally:
        if display_record.is_file():
            try:
                report["display"] = json.loads(display_record.read_text())
            except (OSError, ValueError) as error:
                report["errors"].append("Display receipt could not be decoded: " + str(error)); report["status"] = "failed"
        for name in ("Q", "P"):
            if name in packages:
                try: packages[name].close()
                except BaseException as error:
                    report["errors"].append(f"{name} owned replay cleanup failed: {error}"); report["status"] = "failed"
        if report.get("display", {}).get("changed") and helper.is_file():
            try:
                reference.command([str(helper), "restore", str(display_record), str(output / "display-restored.json")],
                                  output / "display-restore.log", timeout=20)
            except BaseException as error:
                report["errors"].append("Display restore failed: " + str(error)); report["status"] = "failed"
        if added_worktree:
            try: reference.command(["git", "worktree", "remove", "--force", str(checkout)], output / "build/cleanup.log", timeout=30)
            except BaseException as error: report["errors"].append("Owned worktree cleanup failed: " + str(error)); report["status"] = "failed"
        temporary.cleanup(); report["finishedAt"] = reference.utc(); save_report(output, report)
        print("Overview staged-path control:", report["status"], "—", output / "report.md", flush=True)
    return 0 if report["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
