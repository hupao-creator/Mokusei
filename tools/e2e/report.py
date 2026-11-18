"""Run receipts and fail-closed artifact verification (stdlib only)."""
import hashlib
import json
from pathlib import Path


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def exit_code(report):
    if report["validity"] != "valid":
        return 2
    if any(row["status"] == "failed" for row in report["scenarios"]):
        return 1
    if not report["scenarios"] or any(row["status"] != "passed" for row in report["scenarios"]):
        return 2
    return 0


def input_evidence_template():
    return {"backend": "unknown", "tccHost": "unknown",
            "probe": {"tool": "unknown", "status": "unknown", "artifact": None,
                      "permissions": {name: "unknown" for name in ("accessibility", "input", "capture")}},
            "rawAXArtifacts": None, "screenshotArtifacts": None}


def operator_input_evidence(value, directory):
    """Validate operator declarations; permission or TCC identity is never inferred."""
    result = input_evidence_template()
    if value is None:
        return result
    if not isinstance(value, dict) or set(value) - set(result):
        raise ValueError("invalid operator input-evidence metadata")

    def retained(name):
        if not isinstance(name, str) or Path(name).name != name or name in (".", ".."):
            raise ValueError("input evidence requires a bundle-local filename")
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("input evidence not archived: " + name)
        return name

    for key in ("backend", "tccHost"):
        text = value.get(key, "unknown")
        if not isinstance(text, str) or not text.strip() or len(text) > 512:
            raise ValueError("invalid input-evidence " + key)
        result[key] = text
    probe = value.get("probe", result["probe"])
    if not isinstance(probe, dict) or set(probe) - set(result["probe"]):
        raise ValueError("invalid permission probe metadata")
    result["probe"].update(probe)
    if result["probe"]["status"] not in ("unknown", "reported", "recorded"):
        raise ValueError("unknown permission probe status")
    tool = result["probe"]["tool"]
    if not isinstance(tool, str) or not tool.strip() or len(tool) > 512:
        raise ValueError("invalid permission probe tool")
    permissions = result["probe"]["permissions"]
    if not isinstance(permissions, dict) or set(permissions) != {"accessibility", "input", "capture"} or any(
            type(v) is not bool and v != "unknown" for v in permissions.values()):
        raise ValueError("invalid permission probe values")
    artifact = result["probe"]["artifact"]
    if artifact is not None:
        retained(artifact)
    if result["probe"]["status"] == "recorded" and artifact is None:
        raise ValueError("recorded permission probe lacks its artifact")
    for key in ("rawAXArtifacts", "screenshotArtifacts"):
        names = value.get(key)
        if names is not None:
            if not isinstance(names, list) or len(names) > 100 or any(not isinstance(n, str) for n in names) or len(names) != len(set(names)):
                raise ValueError("invalid archived input-artifact inventory")
            result[key] = [retained(name) for name in names]
    return result


def finish(directory, report):
    report["functionality"] = ("failed" if any(r["functionality"] == "failed" for r in report["scenarios"])
        else "passed" if report["scenarios"] and all(r["status"] == "passed" for r in report["scenarios"]) else "unknown")
    report["exitCode"] = exit_code(report)
    save(directory / "report.json", report)
    lines = ["# E2E run", "", f"Validity: **{report['validity']}**; functionality: **{report['functionality']}**; exit: **{report['exitCode']}**.",
             "", "Boundary: real Runtime / HTTP+NDJSON / SQLite / real Codex CLI; deterministic external provider.",
             "Reading, Settings and Collection use native semantic controls. Composer uses operator-assisted system input.",
             "Only passing rows are certified for this attempt; real external-provider behavior is not covered.", "",
             "| Scenario | Status | Functionality | Reason |", "| --- | --- | --- | --- |"]
    for row in report["scenarios"]:
        reason = row.get("reason", "").replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {row['id']} | {row['status']} | {row['functionality']} | {reason} |")
    lines += ["", "## Input backend and retained evidence", "",
              "Operator metadata is a declaration, not an automatically recorded AX trace or TCC-host proof.",
              "Unknown stays unknown. A null raw-artifact inventory is unknown; an empty list declares none archived.",
              "```json", json.dumps(report.get("inputEvidence", {"mode": "unknown", "operatorStages": {}}),
                                    ensure_ascii=False, indent=2), "```"]
    lines += ["", f"Source: `{report['source']['commit']}`; dirty: `{report['source']['dirty']}`.",
              "See source.json for exact source hashes, scenario-contract.json for selected IDs,",
              "events.jsonl for phases and cleanup.json for process cleanup.", ""]
    (directory / "report.md").write_text("\n".join(lines))
    save(directory / "manifest.json", {"version": 1, "files": {
        p.name: sha256(p) for p in sorted(directory.iterdir()) if p.is_file() and p.name != "manifest.json"}})


def verify(directory):
    """Check retained evidence, not a new execution or proof of authenticity."""
    manifest = json.loads((directory / "manifest.json").read_text())
    files = manifest["files"]
    required = {"report.json", "report.md", "source.json", "scenario-contract.json", "events.jsonl", "cleanup.json"}
    if not required.issubset(files):
        raise ValueError("manifest omitted required run evidence")
    for name, digest in files.items():
        if Path(name).name != name or name in (".", ".."):
            raise ValueError("invalid evidence path")
        path = directory / name
        if path.is_symlink() or not path.is_file() or sha256(path) != digest:
            raise ValueError(f"missing or changed evidence: {name}")
    report = json.loads((directory / "report.json").read_text())
    contract = json.loads((directory / "scenario-contract.json").read_text())
    if [r["id"] for r in report["scenarios"]] != [r["id"] for r in contract]:
        raise ValueError("report differs from the requested scenario inventory")
    for row, spec in zip(report["scenarios"], contract):
        if row["status"] not in ("passed", "failed", "blocked", "not-run"):
            raise ValueError("unknown scenario outcome")
        if row["functionality"] not in ("passed", "failed", "unknown"):
            raise ValueError("unknown functional outcome")
        if row["status"] == "passed" and row["functionality"] != "passed":
            raise ValueError("passing scenario has no passing functional result")
        if row["status"] == "passed" and (not spec["evidence"] or not set(spec["evidence"]).issubset(files)):
            raise ValueError(f"passing scenario lacks required evidence: {row['id']}")
    cleanup = json.loads((directory / "cleanup.json").read_text())
    if report["validity"] == "valid" and cleanup.get("ok") is not True:
        raise ValueError("valid run lacks successful cleanup")
    if any(row["status"] == "passed" for row in report["scenarios"]):
        required = {"artifact.json", "ui-artifact.json", "peer.json", "api.jsonl", "ui-events.jsonl",
                    "native-cli.json", "selection.json", "creation.json", "initial-content.json", "initial-oracle.json"}
        if not required.issubset(files):
            raise ValueError("passing interaction lacks cross-boundary evidence")
    for stage, metadata in report.get("inputEvidence", {}).get("operatorStages", {}).items():
        if stage not in ("send", "stop") or metadata.get("receipt") != "operator-" + stage + ".json":
            raise ValueError("operator metadata has no matching input-stage receipt")
        if metadata["receipt"] not in files:
            raise ValueError("operator metadata receipt absent from manifest")
        normalized = operator_input_evidence({k: v for k, v in metadata.items() if k != "receipt"}, directory)
        receipt = json.loads((directory / metadata["receipt"]).read_text())
        if normalized != operator_input_evidence(receipt.get("inputEvidence"), directory):
            raise ValueError("operator metadata differs from its receipt declaration")
        referenced = (normalized["rawAXArtifacts"] or []) + (normalized["screenshotArtifacts"] or [])
        if normalized["probe"]["artifact"] is not None:
            referenced.append(normalized["probe"]["artifact"])
        if not set(referenced).issubset(files):
            raise ValueError("input artifacts absent from manifest")
    code = exit_code(report)
    if code != report["exitCode"]:
        raise ValueError("exit code contradicts report")
    return code
