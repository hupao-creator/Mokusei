"""Exercise real CI scope, artifact-selection and deadline commands in isolation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPTS = Path(__file__).resolve().parent


def command(arguments, *, cwd, env=None, success=True):
    result = subprocess.run(arguments, cwd=cwd, env=env, text=True, capture_output=True)
    if (result.returncode == 0) != success:
        raise AssertionError(f"Unexpected status {result.returncode}: {arguments}\n{result.stdout}\n{result.stderr}")
    return result.stdout + result.stderr


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


if __name__ == "__main__":
    main()
