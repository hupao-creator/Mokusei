"""Run real macOS CI locally, then publish its exact-commit gh-signoff status."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

import deadline
from macos_signoff import SIGNOFF_REVISION, commit_sha, context_for, gh_json

ROOT = Path(__file__).resolve().parents[2]
PYTHON = sys.executable


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def unchanged(sha):
    if git("rev-parse", "HEAD") != sha or git("status", "--porcelain", "--untracked-files=all"):
        raise RuntimeError("HEAD or working tree changed; no success may be published")


class Run:
    def __init__(self, output, sha, mode, *, lock_fd=None):
        self.output = output
        self.lock_fd = lock_fd
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("GH_TOKEN", "GITHUB_TOKEN", "MOKUSEI_SWIFT_SKIP_BUILD", "GITHUB_ENV",
                                   "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_ACTIONS", "MOKUSEI_TEST_HEADLESS", "GOROOT",
                                   "ARGS", "MAKEFLAGS", "MFLAGS", "GNUMAKEFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "MAKEFILES")}
        temporary = output / "tmp"
        temporary.mkdir()
        self.env.update(CGO_ENABLED="1", GOTOOLCHAIN="local", GOFLAGS="-mod=readonly",
                        GITHUB_SHA=sha, RUNNER_TEMP=str(temporary), GITHUB_STEP_SUMMARY=str(output / "summary.md"),
                        MOKUSEI_CI_EVIDENCE=str(output / "native"), MOKUSEI_OVERVIEW_SEARCH_NATIVE_REPLAY="1")
        self.receipt = {"revision": sha, "mode": mode, "startedAt": time.time(), "status": "running", "steps": []}
        self.save()

    def save(self):
        (self.output / "local-ci.json").write_text(json.dumps(self.receipt, indent=2) + "\n")

    def stage(self, name, command, *, timeout=1800, required=True):
        record = {"name": name, "command": command, "status": "running", "startedAt": time.time()}
        self.receipt["steps"].append(record)
        self.save()
        print("RUN", name, flush=True)
        log = self.output / (name + ".log")
        try:
            with log.open("w") as stream:
                # Inner replay launchers own separate process groups and need
                # time to unwind their own bounded teardown before escalation.
                # Keep the account lock alive in the stage owner even if this
                # parent is killed; otherwise a recovery can overlap its replay.
                code = deadline.run(command, cwd=ROOT, env=self.env, timeout=timeout, termination_grace=30,
                                    stdout=stream, stderr=subprocess.STDOUT,
                                    pass_fds=() if self.lock_fd is None else (self.lock_fd,))
            record.update(exit_code=code, status="passed" if code == 0 else "failed")
        except (OSError, TimeoutError) as error:
            record.update(status="failed", error=str(error))
        finally:
            record["finishedAt"] = time.time()
            self.save()
        print(record["status"].upper(), name, "log:", log, flush=True)
        if record["status"] != "passed":
            print(log.read_text(errors="replace")[-4000:] if log.exists() else "No command log", flush=True)
            if required:
                raise RuntimeError("Required stage failed: " + name)
        return record["status"] == "passed"

    def retain_captures(self):
        if getattr(self, "captures_retained", False):
            return
        if self.receipt["mode"] == "native" and any(step["name"] == "swift-build" for step in self.receipt["steps"]):
            for name in ("reading-presentation", "moku-note-production"):
                source = ROOT / ".scratch" / name
                if source.is_dir():
                    shutil.copytree(source, self.output / "native-captures" / name)
        self.captures_retained = True

    def prerequisites(self):
        self.stage("platform", [PYTHON, "scripts/ci/macos-preflight.py"])
        if self.receipt["mode"] != "extended":
            self.stage("xcode", ["xcodebuild", "-version"])
            self.stage("metal", ["xcrun", "--sdk", "macosx", "metal", "--version"])
            # Never alter personal motion/transparency settings or display modes.
            if self.receipt["mode"] != "headless":
                self.stage("display", ["xcrun", "swift", "scripts/ci/native-environment.swift"])
        goroot = subprocess.check_output([str(ROOT / "scripts/go.sh"), "env", "GOROOT"],
                                         cwd=ROOT, env=self.env, text=True).strip()
        self.env.update(PATH=str(Path(goroot) / "bin") + os.pathsep + self.env["PATH"],
                        MOKUSEI_GO=str(Path(goroot) / "bin/go"))

    def headless(self):
        evidence = Path(self.env["MOKUSEI_CI_EVIDENCE"])
        evidence.mkdir()
        self.stage("swift-build", ["xcrun", "swift", "build", "--package-path", "app/macos", "--build-tests",
                                   "--force-resolved-versions", "--disable-index-store", "-j", "2"])
        self.stage("swift-discovery", [PYTHON, "scripts/ci/swift-native.py", "prepare"])
        self.stage("headless-swift", [PYTHON, "scripts/ci/swift-native.py", "headless", "--evidence", str(evidence)])

    def native(self):
        # Retain earlier captures separately; never present them as this run's evidence.
        for name in ("reading-presentation", "moku-note-production"):
            source = ROOT / ".scratch" / name
            if source.is_dir():
                previous = self.output / "previous-native-captures"
                previous.mkdir(exist_ok=True)
                source.rename(previous / name)
        evidence = Path(self.env["MOKUSEI_CI_EVIDENCE"])
        evidence.mkdir()
        self.stage("swift-build", ["xcrun", "swift", "build", "--package-path", "app/macos", "--build-tests",
                                   "--force-resolved-versions", "--disable-index-store", "-j", "2"])
        self.stage("swift-discovery", [PYTHON, "scripts/ci/swift-native.py", "prepare"])
        self.stage("swift-identity", [PYTHON, "scripts/ci/swift-native.py", "verify", "--evidence", str(evidence)])
        self.env["MOKUSEI_SWIFT_SKIP_BUILD"] = "1"
        tests = []
        for name, flags in [("moku", ["-race", "./internal/services/moku"]),
                            ("devtool", ["./internal/tooling/devtool"])]:
            prefix = str(evidence / "ci-native-go" / name)
            tests.append(prefix)
            self.stage("go-" + name, [PYTHON, "scripts/ci/go-tests.py", "run", prefix, "--", "go", "test",
                                      "-json", "-count=1", *flags], required=False)
        self.stage("go-audit", [PYTHON, "scripts/ci/go-tests.py", "report", "--output",
                                str(evidence / "ci-native-go/summary.json"), *tests], required=False)
        fixture_env = self.output / "fixture-env"
        self.env["GITHUB_ENV"] = str(fixture_env)
        self.stage("fixtures", [PYTHON, "scripts/ci/replays.py", "fixtures", "--output", str(evidence / "ci-fixtures")])
        for line in fixture_env.read_text().splitlines():
            key, value = line.split("=", 1)
            self.env[key] = value
        self.env.pop("GITHUB_ENV")
        self.stage("swift-suite", [PYTHON, "scripts/ci/swift-native.py", "run", "--evidence", str(evidence)], required=False)
        for group in ("interop", "native"):
            self.stage(group, [PYTHON, "scripts/ci/replays.py", group, "--output", str(evidence / ("ci-" + group))],
                       timeout=3600, required=False)
        self.stage("coverage-audit", [PYTHON, "scripts/ci/swift-tests.py"], required=False)

    def extended(self):
        self.stage("node", ["node", "--version"])
        major = subprocess.check_output(["node", "--version"], env=self.env, text=True).strip().split(".")[0]
        if major != "v22":
            raise RuntimeError("Extended checks require Node 22")
        packages = {"codex": "@openai/codex@0.163.0", "pi": "@earendil-works/pi-coding-agent@1.0.0",
                    "opencode": "@opencode/cli@2.0.25", "system": "@openai/codex@0.163.0"}
        for kind, package in packages.items():
            prefix = self.output / ("cli-" + kind)
            if not self.stage("install-" + kind, ["npm", "install", "--prefix", str(prefix), "--no-audit", "--no-fund",
                                                 "--fetch-timeout=60000", "--fetch-retries=1", package],
                              timeout=180, required=False):
                continue
            previous_path = self.env["PATH"]
            self.env["PATH"] = str(prefix / "node_modules/.bin") + os.pathsep + previous_path
            if kind in ("codex", "system"):
                binaries = [p for p in (prefix / "node_modules").rglob("codex")
                            if p.is_file() and not p.is_symlink() and os.access(p, os.X_OK)
                            and p.open("rb").read(4) in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe')]
                if len(binaries) != 1:
                    self.receipt["steps"].append({"name": "locate-" + kind, "status": "failed",
                                                   "error": "Expected exactly one pinned native Codex executable"})
                    self.save()
                    self.env["PATH"] = previous_path
                    continue
                self.env["MOKUSEI_SYSTEM_CODEX"] = str(binaries[0])
            commands = {
                "codex": ["go", "run", "-race", "./tools/verification/codex", "-real-only", "-real-codex", self.env.get("MOKUSEI_SYSTEM_CODEX", "")],
                "pi": ["go", "run", "-race", "./tools/verification/pi", "-mode", "native", "-timeout", "7m"],
                "opencode": ["go", "run", "-race", "./tools/verification/opencode", "-native-cli", str(prefix / "node_modules/.bin/opencode")],
                "system": ["make", "check-system", "GO=go", "ARGS="],
            }
            self.stage(kind, commands[kind], required=False)
            self.env["PATH"] = previous_path

    def overview(self, baseline, candidate):
        self.stage("clock-python", [PYTHON, "-m", "unittest", "discover", "-s", "tools/verification/overview-ci-performance",
                                     "-p", "test_clock_contract.py", "-v"])
        self.stage("clock-go", ["go", "test", "./tools/verification/overview-ci-performance/runtime"])
        self.stage("overview", [PYTHON, "tools/verification/overview-ci-performance/run.py", "--baseline", baseline,
                                "--candidate", candidate, "--output", str(self.output / "overview"),
                                "--time-budget-seconds", "1500"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["native", "headless", "extended", "overview"])
    parser.add_argument("--commit", required=True, type=commit_sha)
    parser.add_argument("--baseline")
    parser.add_argument("--candidate")
    parser.add_argument("--reviewed", action="store_true", help="Confirm the exact code and dependencies were reviewed before local execution")
    parser.add_argument("--no-publish", action="store_true", help="Run checks without writing any GitHub status (also works for unpublished commits)")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--url", help="Optional HTTPS evidence URL for gh-signoff")
    args = parser.parse_args()
    if not args.reviewed:
        parser.error("Local tests execute code with your account privileges; review the exact checkout and pass --reviewed")
    if args.mode != "overview" and (args.baseline or args.candidate):
        parser.error("--baseline/--candidate apply only to overview mode")
    context = context_for(args.mode, args.baseline, args.candidate)
    unchanged(args.commit)
    origin = git("remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github.com/|git@github.com:)([^/]+/[^/]+?)(?:\.git)?", origin)
    if not match:
        parser.error("Expected a github.com origin")
    repository = match[1]
    if not args.no_publish:
        # Prove the exact commit exists remotely before running. Do not push,
        # fetch/update refs, or use gh-signoff's force override for local objects.
        remote = gh_json(f"repos/{repository}/commits/{args.commit}")
        if remote["sha"] != args.commit:
            raise RuntimeError("Remote commit identity mismatch")
        extensions = subprocess.check_output(["gh", "extension", "list"], text=True)
        if not any(row.split("\t")[1:] == ["basecamp/gh-signoff", SIGNOFF_REVISION[:8]]
                   for row in extensions.splitlines() if row.startswith("gh signoff\t")):
            raise RuntimeError("Install the reviewed gh-signoff revision documented in scripts/ci/local-macos.md")
    # One account-wide lock serializes native runs across all worktrees/modes.
    lock_path = Path.home() / "Library/Caches/Mokusei/local-macos-ci.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock = os.fdopen(os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600), "w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    output = (args.output or ROOT / ".scratch/local-ci" / args.commit / f"{args.mode}-{time.time_ns()}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    run = Run(output, args.commit, args.mode, lock_fd=lock.fileno())
    def signoff(failed=False):
        # gh-signoff's --commit path otherwise fetches all shared remote refs and
        # rejects PR merge objects absent from remote branch tips. The wrapper
        # independently requires a clean, unchanged exact checkout and a GitHub-
        # known object before execution; -f bypasses only that duplicate guard.
        command = ["gh", "signoff"] + (["fail"] if failed else ["-f"]) + ["--commit", args.commit, context.removeprefix("signoff/")]
        if args.url:
            command += ["--url", args.url]
        subprocess.run(command, cwd=ROOT, check=True, timeout=60)
    published_pending = False
    signal.signal(signal.SIGALRM, lambda *_: sys.exit("Local verification time limit exhausted"))
    signal.alarm({"native": 3600, "headless": 1800, "overview": 1800, "extended": 7920}[args.mode])
    try:
        if not args.no_publish:
            gh_json("-X", "POST", f"repos/{repository}/statuses/{args.commit}", "-f", "state=pending", "-f",
                    "context=" + context, "-f", "description=Local macOS verification is running")
            published_pending = True
        run.prerequisites()
        if args.mode == "overview":
            run.overview(args.baseline, args.candidate)
        else:
            getattr(run, args.mode)()
        unchanged(args.commit)
        if not run.receipt["steps"] or any(step["status"] != "passed" for step in run.receipt["steps"]):
            raise RuntimeError("Incomplete or failed execution; no success may be published")
        run.retain_captures()
        run.receipt.update(status="passed", finishedAt=time.time())
        run.save()
        if not args.no_publish:
            signoff()
            run.receipt["published"] = context
    except BaseException as error:
        run.receipt.update(status="failed", error=str(error))
        if published_pending:
            try:
                signoff(failed=True)
            except Exception as publishing_error:
                run.receipt["publicationError"] = str(publishing_error)
        raise
    finally:
        signal.alarm(0)
        try:
            run.retain_captures()
        except OSError as error:
            run.receipt["captureRetentionError"] = str(error)
        run.receipt["finishedAt"] = time.time()
        run.save()
        print("Local evidence:", output, flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit("Local CI terminated"))
    main()
