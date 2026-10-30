"""Exercise real CI scope, artifact-selection and deadline commands in isolation."""
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
    for name in ("swift-shards.py", "swift-tests.py", "swift_coverage.py", "swift_reporting.py",
                 "swift_ownership.py", "replays.py", "deadline.py"):
        shutil.copyfile(SCRIPTS / name, scripts / name)
    native, owner = next(iter(NATIVE_METHOD_OWNERS.items()))
    suite, method = native.split("/", 1)
    tests = sorted([native, suite + "/ordinarySibling()", suite + "/" + method.removesuffix("()") + "Extra()",
                    *[f"Fixture.Suite{index}/case{index}(value:)" for index in range(5)]])
    (scripts / "swift-suite-weights.json").write_text(json.dumps({test.split("/")[0]: 100 for test in tests}))
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
    command([sys.executable, str(scripts / "swift-shards.py"), "prepare"], cwd=repo, env=environment)
    manifest = json.loads((build / "ci-manifest.json").read_text())
    if manifest["tests"] != tests or manifest["nativeMethods"] != NATIVE_METHOD_OWNERS:
        raise AssertionError("Discovery must retain the explicit native method and owner")
    for shard in manifest["shards"]:
        old_filter = "^(?:" + "|".join(re.escape(name) for name in shard["suites"]) + ")/"
        # Discovery omits source locations for unique Swift Testing methods;
        # runtime filter IDs append them. These are protocol fixtures, not an
        # execution of Swift Testing's own selection engine.
        probes = tests + [test + "/Fixture.swift:42:7" for test in tests]
        for test in probes:
            if bool(re.search(shard["filter"], test)) != bool(re.search(old_filter, test)):
                raise AssertionError("Ordinary/parameterized suite selection changed")
            if bool(re.search(shard["skip"], test)) != (test == native or test.startswith(native + "/")):
                raise AssertionError("Native exclusion missed a runtime ID or excluded a sibling")
        if [test for test in tests if re.search(shard["filter"], test) and not re.search(shard["skip"], test)] != shard["tests"]:
            raise AssertionError("Selected ordinary identities must match the shard receipt")
    inventory.write_text("\n".join(test for test in tests if test != native))
    command([sys.executable, str(scripts / "swift-shards.py"), "prepare"], cwd=repo, env=environment, success=False)
    inventory.write_text("\n".join(tests))

    def swift_log(identities):
        lines = ["Test Suite 'Selected tests' passed at fixture", "Executed 0 tests, with 0 failures"]
        for identity in identities:
            name = identity.split("/", 1)[1]
            cases = " with 2 test cases" if "(value:)" in name else ""
            lines.append(f"✔ Test {name}{cases} passed after 0.001 seconds.")
        lines.append(f"✔ Test run with {len(identities)} tests passed after 0.001 seconds.")
        return "\n".join(lines) + "\n"

    # Exercise the real shard command and receipt around a controlled executable.
    # The native CI run, not this peer, validates Swift's runtime ID selection.
    shard_index = next(index for index, shard in enumerate(manifest["shards"]) if suite in shard["suites"])
    shard = manifest["shards"][shard_index]
    peer_log = root / "shard-peer.log"
    peer_log.write_text(swift_log(shard["tests"]))
    environment["CI_SWIFT_LOG"] = str(peer_log)
    command([sys.executable, str(scripts / "swift-shards.py"), "run", "--shard", str(shard_index),
             "--evidence", str(root / "shard-cli")], cwd=repo, env=environment)
    arguments = json.loads((root / "swift-arguments.json").read_text())
    actual_receipt = json.loads((root / f"shard-cli/swift-{shard_index}.json").read_text())
    if (arguments[arguments.index("--filter") + 1] != shard["filter"]
            or arguments[arguments.index("--skip") + 1] != native_filter()
            or actual_receipt["skip"] != native_filter()):
        raise AssertionError("The shard command and receipt must include the shared native exclusion")
    changed_manifest = json.loads(json.dumps(manifest))
    changed_manifest["shards"][shard_index]["skip"] = "wrong-exclusion"
    (build / "ci-manifest.json").write_text(json.dumps(changed_manifest))
    command([sys.executable, str(scripts / "swift-shards.py"), "verify", "--evidence", str(root / "invalid-build")],
            cwd=repo, env=environment, success=False)
    (build / "ci-manifest.json").write_text(json.dumps(manifest))

    evidence = root / "swift-evidence"
    evidence.mkdir()
    for slot in ("build", *(f"swift-{index}" for index in range(5))):
        directory = evidence / slot
        directory.mkdir()
        (directory / "build-manifest.json").write_text(json.dumps(manifest))
    for index, shard in enumerate(manifest["shards"]):
        (evidence / f"swift-{index}/swift-{index}.json").write_text(json.dumps({
            "revision": manifest["revision"], "shard": index, "filter": shard["filter"], "skip": shard["skip"],
            "tests": shard["tests"], "status": "passed", "exit_code": 0}))
        (evidence / f"swift-{index}/swift-{index}.log").write_text(swift_log(shard["tests"]))
    native_line = f"✔ Test {method} passed after 0.001 seconds.\n"
    native_log = owner["marker"] + "\n\x1b[32m" + native_line.rstrip() + "\x1b[0m\n"
    owner_path = None
    for group in ("fixtures", "interop-wire", "interop-process", "native-controls", "native-capture", "native-runtime"):
        directory = evidence / ("ci-" + group)
        directory.mkdir()
        name = owner["check"] if group == owner["group"] else "fixture"
        (directory / "check.log").write_text(native_log if group == owner["group"] else "")
        report = {"revision": manifest["revision"], "group": group,
                  "checks": [{"name": name, "status": "passed", "exit_code": 0, "log": "check.log"}]}
        (directory / "report.json").write_text(json.dumps(report))
        if group == owner["group"]:
            owner_path = directory
    environment.update(MOKUSEI_CI_EVIDENCE=str(evidence), RUNNER_TEMP=str(root), GITHUB_SHA=manifest["revision"])
    audit = [sys.executable, str(scripts / "swift-tests.py")]
    command(audit, cwd=repo, env=environment)
    for label, log in (("missing", owner["marker"]), ("duplicate", native_log + native_line),
                       ("failed", native_log.replace("passed after", "failed after")),
                       ("skipped", owner["marker"] + f"\n➜ Test {method} skipped: fixture\n"),
                       ("missing marker", native_line)):
        (owner_path / "check.log").write_text(log)
        command(audit, cwd=repo, env=environment, success=False)
    (owner_path / "check.log").write_text(native_log)
    report_path = owner_path / "report.json"
    report = json.loads(report_path.read_text())
    for changes in ({"selectedChecks": [owner["check"]]}, {"selectedChecks": []},
                    {"checks": [dict(report["checks"][0], name="wrong-owner")]},
                    {"checks": [dict(report["checks"][0], exit_code=7)]}):
        report_path.write_text(json.dumps(report | changes))
        command(audit, cwd=repo, env=environment, success=False)
    report_path.write_text(json.dumps(report))
    ordinary_log = evidence / "swift-0/swift-0.log"
    ordinary_before = ordinary_log.read_text()
    ordinary_log.write_text(ordinary_before + native_line)
    command(audit, cwd=repo, env=environment, success=False)
    ordinary_log.write_text(ordinary_before)
    receipt_path = evidence / "swift-0/swift-0.json"
    receipt = json.loads(receipt_path.read_text())
    for exclusion in (None, "wrong-exclusion"):
        receipt_path.write_text(json.dumps(receipt | {"skip": exclusion}))
        command(audit, cwd=repo, env=environment, success=False)
    receipt_path.write_text(json.dumps(receipt))
    print("PASS Swift ownership CLI: suite filters, declared/runtime ID boundaries, skip argument/receipt, full inventory, exclusive owner, ANSI outcomes, omissions, duplicates, failure/skip, missing marker and partial/misrouted receipts")

    # Keep the real local wrapper and replay producer; only the native executable
    # boundary is a controlled peer, so no macOS rendering is claimed here.
    launcher = repo / "tools/verification/reading-presentation/run.py"
    launcher.parent.mkdir(parents=True)
    launcher.write_text("import os\nfrom pathlib import Path\nprint(Path(os.environ['CI_NATIVE_LOG']).read_text(), end='')\n")
    ordinary = root / "ordinary.log"
    ordinary.write_text(swift_log([test for test in tests if test != native]))
    native_peer = root / "native.log"
    native_peer.write_text(native_log)
    environment.update(CI_SWIFT_LOG=str(ordinary), CI_NATIVE_LOG=str(native_peer))
    local = [sys.executable, str(scripts / "swift-tests.py"), "--run", "--output-dir", str(root / "local-evidence")]
    command(local, cwd=repo, env=environment)
    arguments = json.loads((root / "swift-arguments.json").read_text())
    local_skip = arguments[arguments.index("--skip") + 1]
    if "--filter" in arguments or local_skip != native_filter():
        raise AssertionError("Local execution must use the shared exclusion without a positive ancestor filter")
    if {test for test in tests if not re.search(local_skip, test)} != set(tests) - {native}:
        raise AssertionError("Local ordinary execution must exclude only the native owner")
    for log in (owner["marker"], native_line, native_log + native_line):
        native_peer.write_text(log)
        command(local, cwd=repo, env=environment, success=False)
    native_peer.write_text(native_log)
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
        # A controlled API peer lets the real scope CLI reject stale admission
        # without querying or changing any live PR.
        bin_dir = root / "bin"
        bin_dir.mkdir()
        peer = bin_dir / "gh"
        peer.write_text("#!/usr/bin/env python3\nimport os\nprint(open(os.environ['CI_API_FIXTURE']).read())\n")
        peer.chmod(0o755)
        current = {"state": "open", "base": {"sha": base}, "head": {"sha": git("rev-parse", "HEAD")}}
        api = root / "current-pr.json"
        current_env = dict(environment, GITHUB_EVENT_NAME="pull_request", GITHUB_REPOSITORY="fixture/repo",
                           PATH=str(bin_dir) + os.pathsep + os.environ["PATH"], CI_API_FIXTURE=str(api))
        head = current["head"]["sha"]
        for state, current_head, current_base, expected in (("open", head, base, True), ("open", base, base, False),
                                                           ("open", head, head, False), ("closed", head, base, False)):
            current.update(state=state, head={"sha": current_head}, base={"sha": current_base})
            api.write_text(json.dumps(current))
            command([sys.executable, str(SCRIPTS / "scope.py"), "--current"], cwd=repo, env=current_env, success=expected)
        print("PASS queued admission CLI: current PR accepted; superseded and closed PRs rejected")
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

        history = root / "history"
        history.mkdir()
        for slot in ("preparation", "build", "swift-0", "swift-1", "swift-2", "swift-3", "swift-4"):
            path = history / f"macos-{slot}-evidence-attempt-1"
            path.mkdir()
            (path / "receipt.json").write_text('{"status":"passed"}')
        later = history / "macos-swift-3-evidence-attempt-10"
        later.mkdir()
        (later / "receipt.json").write_text('{"status":"failed"}')
        env = dict(environment, JOB_RESULTS=json.dumps({name: {"result": "success"}
                   for name in ("native-go", "swift-build", "mac")}))
        artifacts = [{"id": i, "name": path.name, "expired": False}
                     for i, path in enumerate(sorted(history.iterdir()), start=1)]
        (root / "artifacts.json").write_text(json.dumps([{"artifacts": artifacts}]))
        plan = command([sys.executable, str(SCRIPTS / "collect-evidence.py"), "--plan", str(root / "artifacts.json")], cwd=root, env=env)
        if json.loads(plan)["selectedAttempts"]["swift-3"] != 10:
            raise AssertionError(plan)
        command([sys.executable, str(SCRIPTS / "collect-evidence.py"), str(history), str(root / "selected")], cwd=root, env=env)
        selected = json.loads((root / "selected/swift-3/receipt.json").read_text())
        if selected["status"] != "failed" or not (history / "macos-swift-3-evidence-attempt-1").exists():
            raise AssertionError("A newer failed receipt must win without deleting older evidence")
        next(entry for entry in artifacts if entry["name"] == later.name)["expired"] = True
        (root / "artifacts.json").write_text(json.dumps([{"artifacts": artifacts}]))
        command([sys.executable, str(SCRIPTS / "collect-evidence.py"), "--plan", str(root / "artifacts.json")], cwd=root, env=env, success=False)
        env["JOB_RESULTS"] = json.dumps({name: {"result": "failure" if name == "mac" else "success"}
                                         for name in ("native-go", "swift-build", "mac")})
        command([sys.executable, str(SCRIPTS / "collect-evidence.py"), str(history), str(root / "rejected")], cwd=root, env=env, success=False)
        print("PASS artifact CLI: download planning, numeric attempt selection, prior producer reuse, failed/expired latest evidence and required job failure")

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
