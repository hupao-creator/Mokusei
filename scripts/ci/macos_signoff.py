"""Shared exact-commit status contract for local macOS execution and Actions."""
import json
import re
import subprocess

SIGNOFF_REVISION = "02e0cf9c11c9a1587784fec17c07b93fcb22ec24"


def commit_sha(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("Expected a full lowercase 40-character commit SHA")
    return value


def context_for(mode, baseline=None, candidate=None):
    if mode == "overview":
        # Keep the entire pair identity, including changes outside a short prefix.
        import hashlib
        pair = commit_sha(baseline or "") + commit_sha(candidate or "")
        return "signoff/macos-overview-" + hashlib.sha256(pair.encode()).hexdigest()[:24]
    return {"native": "signoff/macos-native", "extended": "signoff/macos-cli"}[mode]


def gh_json(*arguments):
    result = subprocess.run(["gh", "api", *arguments], text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError("GitHub API failed: " + result.stderr.strip())
    return json.loads(result.stdout)
