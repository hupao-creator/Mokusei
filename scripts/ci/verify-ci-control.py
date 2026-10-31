"""Exercise real CI scope, native evidence and deadline commands in isolation."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SCRIPTS = Path(__file__).resolve().parent


def command(arguments, *, cwd, env=None, success=True):
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True, capture_output=True)
    if (result.returncode == 0) != success:
        raise AssertionError(f"Unexpected status {result.returncode}: {arguments}\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


def verify_swift_ownership(root, repo, environment):
    from swift_ownership import NATIVE_METHOD_OWNERS, native_filter
    scripts = repo / "scripts/ci"
    scripts.mkdir(parents=True)
    for name in ("swift-native.py", "swift-tests.py", "swift_coverage.py", "swift_reporting.py",
                 "swift_ownership.py", "replays.py", "deadline.py"):
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
    peer.write_text("#!/usr/bin/env python3\nimport json, os, sys\nfrom pathlib import Path\n"
                    "if sys.argv[1:4] == ['swift', 'test', 'list']:\n"
                    "    print(Path(os.environ['CI_SWIFT_INVENTORY']).read_text())\n"
                    "elif sys.argv[1:3] == ['swift', 'test']:\n"
                    "    Path(os.environ['CI_SWIFT_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))\n"
                    "    print(Path(os.environ['CI_SWIFT_LOG']).read_text(), end='')\n"
                    "else:\n    print('Fixture toolchain')\n")
    peer.chmod(0o755)
    shutil.copyfile(peer, bin_dir / "xcodebuild")
    (bin_dir / "xcodebuild").chmod(0o755)
    environment = dict(environment, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                       CI_SWIFT_INVENTORY=str(inventory), CI_SWIFT_ARGUMENTS=str(root / "swift-arguments.json"))
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
            cases = " with 2 test cases" if "(value:)" in name else ""
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
    changed_manifest = json.loads(json.dumps(manifest))
    changed_manifest["ordinary"]["skip"] = "wrong-exclusion"
    (build / "ci-manifest.json").write_text(json.dumps(changed_manifest))
    command([sys.executable, str(scripts / "swift-native.py"), "verify", "--evidence", str(root / "invalid-build")],
            cwd=repo, env=environment, success=False)
    (build / "ci-manifest.json").write_text(json.dumps(manifest))

    native_lines = {name: f"✔ Test {name.split('/', 1)[1]} passed after 0.001 seconds.\n"
                    for name in NATIVE_METHOD_OWNERS}
    native_logs = {name: owner["marker"] + "\n\x1b[32m" + native_lines[name].rstrip() + "\x1b[0m\n"
                   for name, owner in NATIVE_METHOD_OWNERS.items()}
    check_logs = {}
    for name, owner in NATIVE_METHOD_OWNERS.items():
        key = (owner["group"], owner["check"])
        check_logs[key] = check_logs.get(key, "") + native_logs[name]
    group_paths = {}
    for group in ("fixtures", "interop", "native"):
        directory = evidence / ("ci-" + group)
        directory.mkdir()
        group_paths[group] = directory
        logs = {check: log for (owner_group, check), log in check_logs.items() if owner_group == group} or {"fixture": ""}
        checks = []
        for name, log in logs.items():
            filename = name + ".log"
            (directory / filename).write_text(log)
            checks.append({"name": name, "status": "passed", "exit_code": 0, "log": filename})
        report = {"revision": manifest["revision"], "group": group, "checks": checks}
        (directory / "report.json").write_text(json.dumps(report))
    environment.update(MOKUSEI_CI_EVIDENCE=str(evidence), RUNNER_TEMP=str(root), GITHUB_SHA=manifest["revision"])
    audit = [sys.executable, str(scripts / "swift-tests.py")]
    command(audit, cwd=repo, env=environment)
    ordinary_log = evidence / "swift.log"
    ordinary_before = ordinary_log.read_text()
    for native, owner in NATIVE_METHOD_OWNERS.items():
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
        f"✔ Test {method} with 2 test cases passed after 0.001 seconds.",
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
                        "selected = [argument for argument in sys.argv[1:] if argument in logs]\n"
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


if __name__ == "__main__":
    main()
