"""Exercise real CI scope, native evidence and deadline commands in isolation."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import time
import subprocess
import sys
import tempfile
import importlib.util

SCRIPTS = Path(__file__).resolve().parent


def command(arguments, *, cwd, env=None, success=True):
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True, capture_output=True)
    if (result.returncode == 0) != success:
        raise AssertionError(f"Unexpected status {result.returncode}: {arguments}\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def verify_replay_inventory(audit, repo, environment, group_paths):
    # Literal non-owner boundaries keep shared-plan fixture generation from
    # silently accepting the disappearance of these mandatory replays.
    for group, required in (("fixtures", "initial-response"), ("interop", "swift-deltas"),
                            ("native", "scrollbars"), ("native", "workspace-lifecycle")):
        directory = group_paths[group]
        report_path = directory / "report.json"
        report = json.loads(report_path.read_text())
        checks = report["checks"]
        matches = [check for check in checks if check["name"] == required]
        if len(matches) != 1:
            raise AssertionError(f"Required {group}/{required} must remain in the replay plan exactly once")
        required_check = matches[0]
        unknown = required_check | {"name": "unknown-replay", "log": "unknown-replay.log"}
        (directory / unknown["log"]).write_text("")
        inventory_error = f"{group}: replay checks do not match the complete plan exactly once"
        cases = [
            ("missing", [check for check in checks if check["name"] != required], inventory_error),
            ("duplicate", checks + [required_check], inventory_error),
            ("unknown", [unknown if check["name"] == required else check for check in checks], inventory_error),
        ]
        for mutation in ({"status": "failed"}, {"status": "running"}, {"exit_code": 7},
                         {"exit_code": None}, {"exit_code": False}):
            cases.append((str(mutation), [check | mutation if check["name"] == required else check for check in checks],
                          f"{group}/{required}: missing successful replay process receipt."))
        cases.append(("wrong log", [check | {"log": unknown["log"]} if check["name"] == required else check for check in checks],
                      f"{group}/{required}: expected its own replay log {required}.log."))
        for label, changed_checks, diagnostic in cases:
            report_path.write_text(json.dumps(report | {"checks": changed_checks}))
            output = command(audit, cwd=repo, env=environment, success=False)
            if diagnostic not in output:
                raise AssertionError(f"{group}/{required} {label}: expected {diagnostic}\n{output}")
        report_path.write_text(json.dumps(report))
        (directory / unknown["log"]).unlink()
        log = directory / required_check["log"]
        original_log = log.read_text()
        log.unlink()
        output = command(audit, cwd=repo, env=environment, success=False)
        if f"{group}: missing actual replay log {required}.log." not in output:
            raise AssertionError(output)
        log.write_text(original_log)
    command(audit, cwd=repo, env=environment)
    print("PASS complete replay inventory: fixtures/interop/native non-owner omissions, duplicate/unknown names, failed/incomplete receipts and missing/misrouted logs")


def verify_interleaved_swift_outcomes(audit, repo, environment, ordinary_log, ordinary_before):
    outcome = "✔ Test case1(value:) with 2 test cases passed after 0.001 seconds.\n"
    if ordinary_before.count(outcome) != 1:
        raise AssertionError("Expected exactly one controlled parameterized outcome")
    # Retain the observed split inside `enabled`; a quoted lookalike on the
    # same physical line must neither count nor swallow the genuine record.
    quoted = json.dumps({"diagnostic": outcome.rstrip("\n")}, ensure_ascii=False)
    prefix = quoted + ' MOKU_EXECUTION_LINK_RECEIPTS {"scroll":{"e'
    suffix = 'nabled":true}}\n'
    for label, record, success in (
            ("interleaved", outcome, True),
            ("quoted only", "", False),
            ("truncated", outcome.replace(" seconds.\n", " seconds\n"), False),
            ("duplicate", outcome + outcome, False),
            ("substituted", outcome.replace("case1(value:)", "unknown(value:)"), False)):
        ordinary_log.write_text(ordinary_before.replace(outcome, prefix + record + suffix, 1))
        output = command(audit, cwd=repo, env=environment, success=success)
        if not success:
            if "observed method identities omit, repeat or substitute assigned tests." not in output:
                raise AssertionError(f"{label}: missing inventory rejection\n{output}")
            if label != "substituted" and "incomplete Swift Testing counts" not in output:
                raise AssertionError(f"{label}: missing terminal count rejection\n{output}")
    ordinary_log.write_text(ordinary_before)
    command(audit, cwd=repo, env=environment)
    print("PASS actual Swift audit: interleaved complete outcome, quoted lookalike, missing/truncated/duplicate/substituted records")


def verify_swift_build(root, repo, environment):
    invocation = root / "swift-build-invocation.json"
    launcher = [sys.executable, str(repo / "scripts/ci/swift-native.py"), "build"]
    complete_build = ["swift", "build", "--package-path", "app/macos", "--build-tests",
                      "--force-resolved-versions", "--disable-index-store", "-Xswiftc", "-warnings-as-errors"]
    flag = "-enable-incremental-file-hashing"
    supported_help = f"  {flag}  Enable input and dependency content hashes\n"
    unavailable_help = ("  -disable-incremental-file-hashing  Disable content hashes\n"
                        f"  {flag}-extra  A distinct option\n"
                        f"  -other-flag  Description mentions {flag}\n")
    for supported, exit_code in ((True, 0), (False, 0), (True, 7)):
        invocation.unlink(missing_ok=True)
        result = subprocess.run(launcher, cwd=root, text=True, capture_output=True, timeout=10,
                                env=dict(environment, CI_SWIFT_BUILD_INVOCATION=str(invocation),
                                         CI_SWIFT_BUILD_HELP=supported_help if supported else unavailable_help,
                                         CI_SWIFT_BUILD_EXIT=str(exit_code)))
        output = result.stdout + result.stderr
        if result.returncode != exit_code:
            raise AssertionError(f"Swift build must preserve exit {exit_code}, got {result.returncode}\n{output}")
        expected = {"arguments": complete_build + (["-Xswiftc", flag] if supported else []), "cwd": str(repo.resolve())}
        if not invocation.exists() or json.loads(invocation.read_text()) != expected:
            raise AssertionError(f"Swift build must retain all build parameters and use the current repository\n{output}")
        capability = "enabled" if supported else "unavailable"
        if f"build incremental-file-hashing={capability}" not in output:
            raise AssertionError(f"Swift build must report the actual hashing capability\n{output}")
    print("PASS actual Swift build CLI: exact capability detection, complete current-source build arguments, repository directory and nonzero propagation")


def verify_native_test_objects(root, repo):
    root, repo = root.resolve(), repo.resolve()
    spec = importlib.util.spec_from_file_location("native_replay_control",
                                                SCRIPTS.parents[1] / "tools/verification/native_replay.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    package = repo / "app/macos"
    production = package / f".build/{platform.machine()}-apple-macosx/debug"
    evidence = root / "object-evidence"
    evidence.mkdir()
    fixtures = [
        ("MokuseiTestSupport", "Support", "NativeTestEnvironment.swift", b"support"),
        ("MokuseiSettingsIntegrationTests", "Integration/Host", "SwiftUIReplaySupport.swift", b"host helper"),
        ("MokuseiSettingsIntegrationTests", "Integration/Host", "Selected.swift", b"host test"),
        ("MokuseiGitIntegrationTests", "Integration/Threads", "Selected.swift", b"thread test"),
    ]
    selections, maps, objects = {}, {}, {}
    for index, (target, directory, name, content) in enumerate(fixtures):
        source = package / "Tests" / directory / name
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("// " + content.decode() + "\n")
        build = production / (target + ".build")
        build.mkdir(parents=True, exist_ok=True)
        obj = build / f"compiled-{index}.o"  # The map, not a basename guess, locates the object.
        selections.setdefault(target, []).append(source)
        maps.setdefault(target, {"": {"swift-dependencies": "primary.swiftdeps"}})[str(source)] = {"object": str(obj)}
        objects[obj] = content
    host = "MokuseiSettingsIntegrationTests"
    source = selections[host][-1]
    unrelated = source.with_name("Unselected.swift")
    unrelated.write_text("// Must not be linked\n")
    extra = production / (host + ".build/Unselected.o")
    maps[host][str(unrelated)] = {"object": str(extra)}
    objects[extra] = b"unselected"
    outside = root / "outside.o"
    outside.write_bytes(b"outside target")
    original = root / "production.o"
    original.write_bytes(b"production")
    current_manifest = package / ".build/ci-manifest.json"
    manifest = {"revision": command(["git", "rev-parse", "HEAD"], cwd=repo).strip(),
                "workspace": str(repo.resolve()), "architecture": platform.machine(), "configuration": "debug",
                "run": "object-fixture-run", "attempt": "1", "toolchain": "fixture-toolchain"}

    def reset():
        data = json.dumps(manifest)
        current_manifest.write_text(data)
        (evidence / "build-manifest.json").write_text(data)
        for target, mapping in maps.items():
            (production / (target + ".build/output-file-map.json")).write_text(json.dumps(mapping))
        for path, content in objects.items():
            path.write_bytes(content)

    def replay():
        # Only skip macOS bundle construction; selection, Git identity, copying
        # and persisted evidence all use the real implementation and files.
        item = module.NativeReplay.__new__(module.NativeReplay)
        item.root = Path(tempfile.mkdtemp(prefix="object-replay-", dir=root))
        item.build = item.root / "build"
        item.build.mkdir()
        item.production, item.configuration = production, "debug"
        item.objects, item.manifest = [str(original)], {}
        return item

    def reject(selection, diagnostic):
        item = replay()
        try:
            item.reuse_test_objects(repo, selection)
        except RuntimeError as error:
            if diagnostic not in str(error):
                raise AssertionError(f"Expected {diagnostic!r}, got {error}") from error
        else:
            raise AssertionError("Accepted invalid native object selection: " + diagnostic)
        if item.objects != [str(original)]:
            raise AssertionError("A failed partial selection appended objects to the linker inputs")

    overrides = {"MOKUSEI_CI_EVIDENCE": str(evidence), "GITHUB_RUN_ID": manifest["run"], "GITHUB_RUN_ATTEMPT": "1"}
    previous = {key: os.environ.get(key) for key in overrides}
    os.environ.update(overrides)
    try:
        reset()
        item = replay()
        item.reuse_test_objects(repo, selections)
        receipt = json.loads((item.root / "launch.json").read_text())["swiftPMTestObjects"]
        if (item.objects[0] != str(original) or len(item.objects) != 5 or len(receipt["objects"]) != 4
                or {Path(path).read_bytes() for path in item.objects[1:]} != {b"support", b"host helper", b"host test", b"thread test"}
                or {entry["source"] for entry in receipt["objects"]} != {
                    str(path.relative_to(repo)) for paths in selections.values() for path in paths}):
            raise AssertionError("Native replay must stage exactly the four selected source objects")
        for entry in receipt["objects"]:
            if (entry["objectSHA256"] != hashlib.sha256(Path(entry["stagedObject"]).read_bytes()).hexdigest()
                    or entry["sourceSHA256"] != hashlib.sha256((repo / entry["source"]).read_bytes()).hexdigest()):
                raise AssertionError("Native object receipt must identify the actual staged object and current source")
        reject({"MokuseiNativePackageTests": selections[host]}, "Unknown or empty Swift replay object selection")
        reject({host: []}, "Unknown or empty Swift replay object selection")
        for label, entry in (("missing entry", None), ("duplicate object", maps[host][str(selections[host][0])]),
                             ("outside target", {"object": str(outside)}), ("whole module", {"object": str(extra)})):
            reset()
            mapping = dict(maps[host])
            if entry is None:
                del mapping[str(source)]
            else:
                mapping["" if label == "whole module" else str(source)] = entry
            (production / (host + ".build/output-file-map.json")).write_text(json.dumps(mapping))
            reject(selections, "requires per-source objects" if label == "whole module" else
                   "No compiled Swift replay object" if entry is None else "Missing, duplicate or unexpected Swift replay object")
        reset()
        Path(maps[host][str(source)]["object"]).unlink()
        reject(selections, "Missing, duplicate or unexpected Swift replay object")
        for mutation in ({"revision": "stale"}, {"run": "old-run"}, {"attempt": "2"}):
            reset()
            data = json.dumps(manifest | mutation)
            current_manifest.write_text(data)
            (evidence / "build-manifest.json").write_text(data)
            reject(selections, "require the current checkout and CI attempt's build")
        reset()
        (evidence / "build-manifest.json").write_text(json.dumps(manifest | {"toolchain": "stale-evidence"}))
        reject(selections, "differs from the verified CI evidence")
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    print("PASS real native object selection: exact staged sources/hashes, unknown/empty targets, missing/duplicate/escaped/WMO objects, atomic linker inputs and stale revision/run/attempt/evidence rejection")


def verify_swift_ownership(root, repo, environment):
    from swift_ownership import NATIVE_METHOD_OWNERS, STANDALONE_METHOD_OWNERS, native_filter
    from replay_plan import replay_groups
    scripts = repo / "scripts/ci"
    scripts.mkdir(parents=True)
    for name in ("swift-native.py", "swift-tests.py", "swift_coverage.py", "swift_reporting.py",
                 "swift_ownership.py", "swift_execution.py", "replays.py", "replay_plan.py", "deadline.py"):
        shutil.copyfile(SCRIPTS / name, scripts / name)
    native_names = set(NATIVE_METHOD_OWNERS)
    tests = sorted(native_names
                   | {name.removesuffix("()") + "OrdinarySibling()" for name in native_names}
                   | {name.removesuffix("()") + "Extra()" for name in native_names}
                   | {f"Fixture.Suite{index}/case{index}(value:)" for index in range(5)})
    build = repo / "app/macos/.build"
    build.mkdir(parents=True)
    inventory = root / "swift-inventory"
    inventory.write_text("\n".join(tests))
    bin_dir = root / "swift-bin"
    bin_dir.mkdir()
    peer = bin_dir / "xcrun"
    peer.write_text("#!/usr/bin/env python3\nimport json, os, sys, time\nfrom pathlib import Path\n"
                    "if sys.argv[1:] == ['swiftc', '-help-hidden']:\n"
                    "    print(os.environ['CI_SWIFT_BUILD_HELP'])\n"
                    "elif sys.argv[1:3] == ['swift', 'build']:\n"
                    "    Path(os.environ['CI_SWIFT_BUILD_INVOCATION']).write_text(json.dumps(\n"
                    "        {'arguments': sys.argv[1:], 'cwd': str(Path.cwd())}))\n"
                    "    raise SystemExit(int(os.environ['CI_SWIFT_BUILD_EXIT']))\n"
                    "elif sys.argv[1:4] == ['swift', 'test', 'list']:\n"
                    "    print(Path(os.environ['CI_SWIFT_INVENTORY']).read_text())\n"
                    "elif sys.argv[1:3] == ['swift', 'test']:\n"
                    "    if os.environ.get('CI_SWIFT_BLOCK'):\n"
                    "        Path(os.environ['CI_SWIFT_BLOCK']).write_text(str(os.getpid()))\n"
                    "        time.sleep(60)\n"
                    "    Path(os.environ['CI_SWIFT_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))\n"
                    "    print(Path(os.environ['CI_SWIFT_LOG']).read_text(), end='')\n"
                    "else:\n    print('Fixture toolchain')\n")
    peer.chmod(0o755)
    shutil.copyfile(peer, bin_dir / "xcodebuild")
    (bin_dir / "xcodebuild").chmod(0o755)
    environment = dict(environment, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       CI_SWIFT_INVENTORY=str(inventory), CI_SWIFT_ARGUMENTS=str(root / "swift-arguments.json"))
    verify_swift_build(root, repo, environment)
    command([sys.executable, str(scripts / "swift-native.py"), "prepare"], cwd=repo, env=environment)
    manifest = json.loads((build / "ci-manifest.json").read_text())
    if manifest["tests"] != tests or manifest["nativeMethods"] != NATIVE_METHOD_OWNERS:
        raise AssertionError("Discovery must retain every explicit native method and owner")
    ordinary_tests = sorted(set(tests) - native_names)
    if manifest["ordinary"]["tests"] != ordinary_tests:
        raise AssertionError("Ordinary inventory must include every method without a native owner")
    # Discovery omits source locations for unique Swift Testing methods;
    # runtime filter IDs append them. These are protocol fixtures, not an
    # execution of Swift Testing's own selection engine.
    probes = tests + [test + "/Fixture.swift:42:7" for test in tests]
    for test in probes:
        if bool(re.search(manifest["ordinary"]["skip"], test)) != any(
                test == native or test.startswith(native + "/") for native in native_names):
            raise AssertionError("Native exclusion missed a runtime ID or excluded a sibling")
    for native in native_names:
        inventory.write_text("\n".join(test for test in tests if test != native))
        command([sys.executable, str(scripts / "swift-native.py"), "prepare"], cwd=repo, env=environment, success=False)
    inventory.write_text("\n".join(tests))

    def swift_log(identities):
        lines = ["Test Suite 'Selected tests' passed at fixture", "Executed 0 tests, with 0 failures"]
        for identity in identities:
            name = identity.split("/", 1)[1]
            cases = " with 1 test case" if name == "case0(value:)" else " with 2 test cases" if "(value:)" in name else ""
            lines.append(f"✔ Test {name}{cases} passed after 0.001 seconds.")
        lines.append(f"✔ Test run with {len(identities)} tests passed after 0.001 seconds.")
        return "\n".join(lines) + "\n"

    # Exercise the real full-suite command and receipt around a controlled executable.
    # The native CI run, not this peer, validates Swift's runtime ID selection.
    peer_log = root / "swift-peer.log"
    peer_log.write_text(swift_log(ordinary_tests))
    environment["CI_SWIFT_LOG"] = str(peer_log)
    evidence = root / "swift-evidence"
    command([sys.executable, str(scripts / "swift-native.py"), "run",
             "--evidence", str(evidence)], cwd=repo, env=environment)
    arguments = json.loads((root / "swift-arguments.json").read_text())
    actual_receipt = json.loads((evidence / "swift.json").read_text())
    if ("--filter" in arguments or "--no-parallel" not in arguments
            or arguments[arguments.index("--skip") + 1] != native_filter()
            or actual_receipt["skip"] != native_filter() or actual_receipt["tests"] != ordinary_tests):
        raise AssertionError("Full ordinary execution must be serial and exclude exactly the native owners")
    child_pid = root / "swift-child-pid"
    cancelled = root / "cancelled-swift"
    launcher = subprocess.Popen([sys.executable, str(scripts / "swift-native.py"), "run", "--evidence", str(cancelled)],
                                cwd=repo, env=dict(environment, CI_SWIFT_BLOCK=str(child_pid)),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        expires = time.monotonic() + 10
        while not child_pid.exists() and time.monotonic() < expires:
            time.sleep(0.02)
        if not child_pid.exists():
            raise AssertionError("Controlled Swift child did not start")
        pid = int(child_pid.read_text())
        launcher.send_signal(signal.SIGTERM)
        launcher.communicate(timeout=10)
        if launcher.returncode == 0 or json.loads((cancelled / "swift.json").read_text())["status"] != "failed":
            raise AssertionError("Cancelled Swift launcher must retain a failing receipt")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("Cancelled Swift launcher orphaned its separate test process group")
    finally:
        if launcher.poll() is None:
            launcher.kill()
            launcher.communicate()
        if child_pid.exists():
            try:
                os.killpg(int(child_pid.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
    print("PASS actual Swift launcher cancellation: separate child process group terminated and failure receipt retained")
    changed_manifest = json.loads(json.dumps(manifest))
    changed_manifest["ordinary"]["skip"] = "wrong-exclusion"
    (build / "ci-manifest.json").write_text(json.dumps(changed_manifest))
    command([sys.executable, str(scripts / "swift-native.py"), "verify", "--evidence", str(root / "invalid-build")],
            cwd=repo, env=environment, success=False)
    (build / "ci-manifest.json").write_text(json.dumps(manifest))

    replay_owners = NATIVE_METHOD_OWNERS | STANDALONE_METHOD_OWNERS
    native_lines = {name: f"✔ Test {name.split('/', 1)[1]}{' with 1 test case' if name.endswith(':)') else ''} passed after 0.001 seconds.\n"
                    for name in replay_owners}
    native_logs = {name: owner["marker"] + "\n\x1b[32m" + native_lines[name].rstrip() + "\x1b[0m\n"
                   for name, owner in replay_owners.items()}
    check_logs = {}
    for name, owner in replay_owners.items():
        key = (owner["group"], owner["check"])
        check_logs[key] = check_logs.get(key, "") + native_logs[name]
    group_paths = {}
    groups = replay_groups("go", evidence)
    for group in ("fixtures", "interop", "native"):
        directory = evidence / ("ci-" + group)
        directory.mkdir()
        group_paths[group] = directory
        checks = []
        for name, _ in groups[group]:
            filename = name + ".log"
            (directory / filename).write_text(check_logs.get((group, name), ""))
            checks.append({"name": name, "status": "passed", "exit_code": 0, "log": filename})
        report = {"revision": manifest["revision"], "group": group, "checks": checks}
        (directory / "report.json").write_text(json.dumps(report))
    environment.update(MOKUSEI_CI_EVIDENCE=str(evidence), RUNNER_TEMP=str(root), GITHUB_SHA=manifest["revision"])
    audit = [sys.executable, str(scripts / "swift-tests.py")]
    command(audit, cwd=repo, env=environment)
    verify_replay_inventory(audit, repo, environment, group_paths)
    ordinary_log = evidence / "swift.log"
    ordinary_before = ordinary_log.read_text()
    verify_interleaved_swift_outcomes(audit, repo, environment, ordinary_log, ordinary_before)
    for native, owner in replay_owners.items():
        method = native.split("/", 1)[1]
        native_log, native_line = native_logs[native], native_lines[native]
        original = check_logs[owner["group"], owner["check"]]
        owner_path = group_paths[owner["group"]]
        log_path = owner_path / (owner["check"] + ".log")
        for label, log in (("missing", owner["marker"]), ("duplicate", native_log + native_line),
                           ("failed", native_log.replace("passed after", "failed after")),
                           ("skipped", owner["marker"] + f"\n➜ Test {method} skipped: fixture\n"),
                           ("missing marker", native_line)):
            log_path.write_text(original.replace(native_log, log, 1))
            command(audit, cwd=repo, env=environment, success=False)
        log_path.write_text(original)
        report_path = owner_path / "report.json"
        report = json.loads(report_path.read_text())
        for changes in ({"selectedChecks": [owner["check"]]}, {"selectedChecks": []},
                        *[{"checks": [check | mutation if check["name"] == owner["check"] else check
                                      for check in report["checks"]]}
                          for mutation in ({"name": "wrong-owner"}, {"exit_code": 7})]):
            report_path.write_text(json.dumps(report | changes))
            command(audit, cwd=repo, env=environment, success=False)
        report_path.write_text(json.dumps(report))
        ordinary_log.write_text(ordinary_before + native_line)
        command(audit, cwd=repo, env=environment, success=False)
        ordinary_log.write_text(ordinary_before)
    receipt_path = evidence / "swift.json"
    receipt = json.loads(receipt_path.read_text())
    for mutation in ({"skip": None}, {"skip": "wrong-exclusion"}, {"revision": "wrong-revision"},
                     {"tests": ordinary_tests[:-1]}, {"status": "running"}, {"exit_code": 7}):
        receipt_path.write_text(json.dumps(receipt | mutation))
        command(audit, cwd=repo, env=environment, success=False)
    receipt_path.write_text(json.dumps(receipt))
    receipt_path.unlink()
    command(audit, cwd=repo, env=environment, success=False)
    receipt_path.write_text(json.dumps(receipt))
    for identities in (ordinary_tests[:-1], ordinary_tests[:-1] + ["Fixture.Unknown/substitute()"],
                       ordinary_tests[:-1] + [ordinary_tests[0]]):
        ordinary_log.write_text(swift_log(identities))
        command(audit, cwd=repo, env=environment, success=False)
    method = ordinary_tests[0].split("/", 1)[1]
    ordinary_log.write_text(ordinary_before.replace(
        f"✔ Test {method} with 1 test case passed after 0.001 seconds.",
        f"➜ Test {method} skipped: unexpected fixture skip"))
    command(audit, cwd=repo, env=environment, success=False)
    ordinary_log.write_text(ordinary_before.split("✔ Test run with", 1)[0])
    command(audit, cwd=repo, env=environment, success=False)
    ordinary_log.unlink()
    command(audit, cwd=repo, env=environment, success=False)
    ordinary_log.write_text(ordinary_before)
    manifest_path = evidence / "build-manifest.json"
    manifest_path.write_text(json.dumps(manifest | {"revision": "wrong-revision"}))
    command(audit, cwd=repo, env=environment, success=False)
    manifest_path.write_text(json.dumps(manifest))
    for group, directory in group_paths.items():
        report_path = directory / "report.json"
        report = json.loads(report_path.read_text())
        report_path.write_text(json.dumps(report | {"revision": "wrong-revision"}))
        command(audit, cwd=repo, env=environment, success=False)
        report_path.unlink()
        command(audit, cwd=repo, env=environment, success=False)
        report_path.write_text(json.dumps(report))
    command(audit, cwd=repo, env=environment)
    print("PASS Swift ownership CLI: complete serial suite, declared/runtime ID boundaries, skip argument/receipt, inventory omissions/substitutions/duplicates, interrupted logs, wrong revisions, every exclusive owner, ANSI outcomes, failure/skip, missing marker and partial/misrouted receipts")

    # Keep the real local wrapper and replay producer; only the native executable
    # boundary is a controlled peer, so no macOS rendering is claimed here.
    launcher = repo / "tools/verification/reading-presentation/run.py"
    launcher.parent.mkdir(parents=True)
    launcher.write_text("import json, os, sys\nfrom pathlib import Path\n"
                        "logs = json.loads(os.environ['CI_NATIVE_LOGS'])\n"
                        "arguments = [\"--thread-send-feedback\" if argument == \"--thread-send-feedback-native\" else argument for argument in sys.argv[1:]]\n"
                        "selected = [argument for argument in arguments if argument in logs]\n"
                        "assert len(selected) == 1, 'Expected exactly one native check'\n"
                        "print(Path(logs[selected[0]]).read_text(), end='')\n")
    ordinary = root / "ordinary.log"
    ordinary.write_text(swift_log([test for test in tests if test not in native_names]))
    native_peers = {}
    for (group, check), log in check_logs.items():
        path = root / (group + "-" + check + ".log")
        path.write_text(log)
        native_peers["--" + check] = str(path)
    environment.update(CI_SWIFT_LOG=str(ordinary), CI_NATIVE_LOGS=json.dumps(native_peers))
    local = [sys.executable, str(scripts / "swift-tests.py"), "--run", "--output-dir", str(root / "local-evidence")]
    command(local, cwd=repo, env=environment)
    arguments = json.loads((root / "swift-arguments.json").read_text())
    local_skip = arguments[arguments.index("--skip") + 1]
    if "--filter" in arguments or local_skip != native_filter():
        raise AssertionError("Local execution must use the shared exclusion without a positive ancestor filter")
    if {test for test in tests if not re.search(local_skip, test)} != set(tests) - native_names:
        raise AssertionError("Local ordinary execution must exclude exactly the native owners")
    for native, owner in NATIVE_METHOD_OWNERS.items():
        native_log, native_line = native_logs[native], native_lines[native]
        original = check_logs[owner["group"], owner["check"]]
        native_peer = Path(native_peers["--" + owner["check"]])
        for log in (owner["marker"], native_line, native_log + native_line):
            native_peer.write_text(original.replace(native_log, log, 1))
            command(local, cwd=repo, env=environment, success=False)
        native_peer.write_text(original)
    ordinary.write_text(swift_log(tests))
    command(local, cwd=repo, env=environment, success=False)
    print("PASS local Swift CLI: ordinary exclusion plus real replay producer, required outcome/marker, duplicate and wrong-host rejection")

    spec = importlib.util.spec_from_file_location("headless_control", SCRIPTS / "swift-native.py")
    launcher_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher_module)
    headless_tests = sorted(suite + "/" + suite.split(".")[-1] + "Contract()" for suite in launcher_module.HEADLESS_SUITES)
    headless_manifest = json.loads(json.dumps(manifest))
    headless_manifest["tests"] = sorted(tests + headless_tests)
    headless_manifest["ordinary"]["tests"] = sorted(ordinary_tests + headless_tests)
    (build / "ci-manifest.json").write_text(json.dumps(headless_manifest))
    peer_log.write_text(swift_log(headless_tests))
    headless = [sys.executable, str(scripts / "swift-native.py"), "headless",
                "--evidence", str(root / "headless-evidence")]
    headless_environment = dict(environment, CI_SWIFT_LOG=str(peer_log))
    command(headless, cwd=repo, env=headless_environment)
    receipt = json.loads((root / "headless-evidence/headless-swift.json").read_text())
    if receipt["tests"] != headless_tests or receipt["status"] != "passed":
        raise AssertionError("Headless receipt did not account for the complete selection")
    good_log = peer_log.read_text()
    line = f"✔ Test {headless_tests[0].split('/', 1)[1]} passed after 0.001 seconds.\n"
    for bad_log in (good_log.replace(line, "", 1), good_log + line,
                    good_log.replace(line, f"➜ Test {headless_tests[0].split('/', 1)[1]} skipped: missing capability\n", 1)):
        peer_log.write_text(bad_log)
        command(headless, cwd=repo, env=headless_environment, success=False)
    print("PASS actual headless Swift CLI: exact selection, terminal summaries, missing/duplicate outcomes and zero allowed skips")


def main():
    with tempfile.TemporaryDirectory(prefix="mokusei-ci-control-") as directory:
        root = Path(directory)
        repo = root / "repo"
        repo.mkdir()
        def git(*arguments):
            return command(["git", *arguments], cwd=repo).strip()
        git("init", "-q")
        git("config", "user.name", "CI fixture")
        git("config", "user.email", "ci-fixture@example.invalid")
        (repo / "README.md").write_text("Initial documentation\n")
        (repo / "source.go").write_text("package fixture\n")
        git("add", ".")
        git("commit", "-qm", "Initial fixture")
        base = git("rev-parse", "HEAD")
        environment = dict(os.environ, GITHUB_EVENT_PATH=str(root / "event.json"),
                           GITHUB_OUTPUT=str(root / "output"), GITHUB_STEP_SUMMARY=str(root / "summary"))

        def scope(expected, kind="pull_request"):
            head = git("rev-parse", "HEAD")
            event = {"number": 1, "before": base, "pull_request": {"base": {"sha": base}, "head": {"sha": head}}}
            (root / "event.json").write_text(json.dumps(event))
            env = dict(environment, GITHUB_EVENT_NAME=kind, GITHUB_SHA=head)
            value = command([sys.executable, str(SCRIPTS / "scope.py")], cwd=repo, env=env)
            if json.loads(value)["documentation_only"] != expected:
                raise AssertionError(value)

        scope(False)  # Empty changes never prove a documentation-only run.
        (repo / "README.md").write_text("Changed documentation\n")
        git("commit", "-qam", "Update documentation")
        scope(True)
        scope(True, "push")
        scope(False, "workflow_dispatch")
        (repo / "source.go").write_text("package changed\n")
        git("commit", "-qam", "Change source")
        scope(False)
        git("mv", "source.go", "another-README.md")
        git("commit", "-qm", "Rename source")
        scope(False)
        git("reset", "--hard", base)
        (repo / "README.md").unlink()
        (repo / "README.md").symlink_to("source.go")
        git("add", ".")
        git("commit", "-qm", "Replace documentation with symlink")
        scope(False)
        git("reset", "--hard", base)
        bundled = repo / "app/macos/Sources/Shared/PluginUI/Resources/README.md"
        bundled.parent.mkdir(parents=True)
        bundled.write_text("A runtime resource\n")
        git("add", ".")
        git("commit", "-qm", "Add a bundled README")
        scope(False)
        print("PASS real Git scope: docs, push, mixed changes, renamed source, symlink, bundled README, empty diff and dispatch")

        for code, timeout, success in (("pass", 5, True), ("raise SystemExit(7)", 5, False),
                                       ("import time; time.sleep(60)", 0.05, False)):
            script = (f"import sys; sys.path.insert(0, {str(SCRIPTS)!r}); import deadline; "
                      f"raise SystemExit(deadline.run([sys.executable, '-c', {code!r}], timeout={timeout}))")
            result = command([sys.executable, "-c", script], cwd=root, success=success)
            if timeout < 1 and "incomplete execution, not a test assertion failure" not in result:
                raise AssertionError(result)
        command([sys.executable, str(SCRIPTS / "deadline.py"), sys.executable, "-c", "pass"], cwd=root,
                env=dict(os.environ, MOKUSEI_CI_STARTED_AT="0"))
        print("PASS real subprocess completion, nonzero status and deadline termination")
        verify_swift_ownership(root, repo, environment)
        verify_native_test_objects(root, repo)
        outer_env = root / "parent-github-env"
        outer_env.write_text("untouched\n")
        print(command([sys.executable, str(SCRIPTS / "verify-headless-parallel.py")], cwd=root,
                      env=dict(os.environ, GITHUB_ENV=str(outer_env))).strip())
        if outer_env.read_text() != "untouched\n":
            raise AssertionError("Controlled producer contaminated the parent workflow environment")
        print("PASS parallel control cannot export temporary fixture paths to the parent GitHub environment")


if __name__ == "__main__":
    main()
