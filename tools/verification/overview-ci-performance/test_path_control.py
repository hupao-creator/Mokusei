"""No macOS required: package relocation, failure retention and original gates."""
from contextlib import ExitStack
import copy
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

import path_control as control
from test_clock_contract import clock_fixture, loaded_source_fixture


class FakeReplay:
    def __init__(self, root):
        self.root = root.resolve()
        self.workspace = self.root / "workspace"
        self.application = self.root / (control.APP_NAME + ".app")
        self.executable = self.application / "Contents/MacOS" / control.APP_NAME
        self.executable.parent.mkdir(parents=True)
        self.workspace.mkdir()
        self.executable.write_bytes(b"same signed UI bytes")
        self.executable.chmod(0o755)
        (self.workspace / "runtime").write_bytes(b"same Core bytes")
        (self.workspace / "runtime").chmod(0o755)
        resource = self.application / "Contents/Resources/Fixture.bundle"
        resource.mkdir(parents=True)
        (resource / "data.txt").write_text("complete resource bytes")
        (resource / "alias").symlink_to("data.txt")
        with (self.application / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": control.BUNDLE_ID,
                          "CFBundleExecutable": control.APP_NAME}, stream)
        self.manifest = {"root": str(self.root), "workspace": str(self.workspace),
                         "resourceBundles": [str(resource)]}
        self.stopped_pids = set()
        self.process = None
        self.result = full_result()
        self.raise_in_run = None
        self.stop_count = 0

    def stop(self):
        self.stop_count += 1

    def run(self, arguments, **kwargs):
        if self.raise_in_run is not None:
            raise self.raise_in_run
        value = copy.deepcopy(self.result)
        value["runtimeProcess"] = {"pid": 4567, "parentPID": 3456,
                                   "executable": str(self.workspace / "runtime")}
        (self.root / "runtime-isolation.json").write_text(json.dumps({"pid": 3456,
            "cwd": str(self.workspace), "arguments": arguments,
            "resourceBundles": self.manifest["resourceBundles"]}))
        Path(arguments[arguments.index("--output")+1]).write_text(json.dumps(value))
        return 0

    def export(self, output):
        for path in (self.workspace / "evidence").glob("*.json"):
            shutil.copy2(path, output / path.name)


def full_result():
    result = clock_fixture()
    result.update(schemaVersion=1, condition="S4", n=40, k=4, valid=True, invalidReasons=[],
                  sourceProtocolVersion=2, sourceQueueCapacity=256,
                  sourceProtocolChecks={stage: True for stage in ("ready", "start", "status", "result", "final")})
    result["comparisonIdentity"].update(sourceProtocolVersion=2, sourceQueueCapacity=256)
    result["core"] = loaded_source_fixture()
    result["core"].update(valid=True, invalidReasons=[])
    result["core"]["cpu"].update(cpuSeconds=1, cpuPercent=5)
    result["ui"].update(cpuSeconds=10, cpuPercent=50)
    result["uiWindows"]["sourceThroughTailObservation"].update(cpuSeconds=13)
    result["uiWindows"]["tailObservation"].update(cpuSeconds=0.5)
    return result


def identity(replay):
    return {**control.verify_replay_locations(replay),
            "uiSHA256": control.reference.digest(replay.executable),
            "coreSHA256": control.reference.digest(replay.workspace / "runtime"),
            "appManifest": control.app_manifest(replay.application),
            "signature": {"verifiedDeepStrict": True, "identifier": control.BUNDLE_ID, "cdHash": "a"*40},
            "coreSignature": {"status": "unsigned", "displayExitCode": 1}}


class PathControlTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.p = FakeReplay(self.root / "P")
        self.q = FakeReplay(self.root / "Q")

    def tearDown(self):
        self.temporary.cleanup()

    def test_exact_eight_prespecified_cells(self):
        self.assertEqual([(x["group"], x["logicalLabel"], x["package"]) for x in control.planned_runs()],
            [("D_AB", "A", "P"), ("D_AB", "B", "Q"), ("S_AB", "A", "P"), ("S_AB", "B", "P"),
             ("S_BA", "B", "Q"), ("S_BA", "A", "Q"), ("D_BA", "B", "Q"), ("D_BA", "A", "P")])

    def test_copy_preserves_bytes_permissions_symlinks_not_p_locations(self):
        receipt = control.clone_payload(self.p, self.q)
        self.assertTrue(receipt["allSeparatePhysicalFiles"])
        self.assertEqual(control.app_manifest(self.p.application), control.app_manifest(self.q.application))
        self.assertFalse(control.reference.same_existing_file(self.p.executable, self.q.executable))
        self.assertFalse(control.reference.same_existing_file(self.p.workspace / "runtime", self.q.workspace / "runtime"))
        self.assertTrue(control.same_payload(identity(self.p), identity(self.q)))
        self.assertTrue(all(str(self.q.application) in path for path in self.q.manifest["resourceBundles"]))

    def test_copied_p_manifest_is_rejected(self):
        self.q.manifest = copy.deepcopy(self.p.manifest)
        with self.assertRaises(ValueError): control.verify_replay_locations(self.q)

    def test_hardlink_clone_is_rejected(self):
        (self.q.workspace / "runtime").unlink()
        with patch.object(control.shutil, "copy2", side_effect=os.link):
            with self.assertRaises(ValueError): control.clone_payload(self.p, self.q)

    def test_foreign_resource_path_is_rejected(self):
        self.q.manifest["resourceBundles"] = self.p.manifest["resourceBundles"]
        with self.assertRaises(ValueError): control.verify_replay_locations(self.q)

    def test_bundle_identity_change_is_rejected(self):
        path = self.q.application / "Contents/Info.plist"
        with path.open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "different.id", "CFBundleExecutable": control.APP_NAME}, stream)
        with self.assertRaises(ValueError): control.verify_replay_locations(self.q)

    def test_payload_missing_or_modified_is_not_equal(self):
        self.assertFalse(control.same_payload({}, {}))
        self.assertFalse(control.same_payload(None, None))
        left, right = identity(self.p), identity(self.q)
        right["coreSignature"] = {"status": "verified"}
        self.assertFalse(control.same_payload(left, right))
        (self.q.application / "Contents/Resources/Fixture.bundle/data.txt").write_text("different")
        self.assertFalse(control.same_payload(identity(self.p), identity(self.q)))

    def test_bundle_symlink_must_not_escape(self):
        (self.q.application / "Contents/escape").symlink_to(self.p.executable)
        with self.assertRaises(ValueError): control.app_manifest(self.q.application)

    def test_group_mappings_and_order_are_not_product_pairs(self):
        rows = [{**cell, "valid": True, "powerBefore": "AC Power", "result": full_result()} for cell in control.planned_runs()]
        groups = control.group_results(rows)
        self.assertEqual(len(groups), 4)
        self.assertTrue(all(group["valid"] for group in groups))
        rows[2]["package"] = "Q"
        self.assertFalse(control.group_results(rows)[1]["valid"])
        rows = list(reversed(rows))
        self.assertFalse(any(group["valid"] for group in control.group_results(rows)))

    def execute_cell(self, *, cleanup_error=None):
        output = self.root / "result"
        output.mkdir()
        row = dict(control.planned_runs()[1])
        observation = {"observations": {"power": {"stdout": "Now drawing from 'AC Power'"}}}
        with ExitStack() as stack:
            stack.enter_context(patch.object(control.reference, "machine_snapshot", return_value=observation))
            cleanup = stack.enter_context(patch.object(control.reference, "cleanup_runtime", side_effect=cleanup_error))
            validator = stack.enter_context(patch.object(control.reference, "validate_result", wraps=control.reference.validate_result))
            try:
                control.run_cell(row, self.q, identity(self.q), output, control.reference.Budget(30))
            finally:
                self.last_row = row
                self.cleanup_call = cleanup.call_args
                self.validator_call = validator.call_args
        return row

    def test_actual_q_and_original_validators_are_used(self):
        row = self.execute_cell()
        self.assertTrue(row["valid"], row["invalidReasons"])
        self.assertIs(self.cleanup_call.args[0], self.q)
        self.assertEqual(self.validator_call.args[1:], ("S4", 20))
        self.assertTrue(row["runtimeIdentity"]["samePhysicalFile"])
        self.assertEqual(row["runtimeIdentity"]["expectedExecutable"]["reportedPath"], str(self.q.workspace / "runtime"))

    def test_original_50ms_enqueue_gate_is_preserved(self):
        core = self.q.result["core"]
        for stage in ("enqueued", "dequeued", "sent", "storeUpdateStarted", "accepted", "completed"):
            core["sourceEvents"][-1][stage + "UptimeNanoseconds"] += 51_000_000
            core["sourceEvents"][-1][stage + "ElapsedNanoseconds"] += 51_000_000
        for stage in ("enqueued", "dequeued", "sent", "accepted"):
            core["windows"]["formal"][stage] -= 1
            core["windows"]["tail"][stage] += 1
            core["source"]["formal" + stage.capitalize()] -= 1
            core["source"]["tail" + stage.capitalize()] += 1
        for name, maximum in (("enqueueDeadline", 51.2), ("legacySentDeadline", 51.5)):
            core["source"][name].update(exceededCount=1, exceededIndices=[999], wouldFail=True, maxLatenessMilliseconds=maximum)
        row = self.execute_cell()
        self.assertFalse(row["valid"])
        self.assertEqual(row["invalidReasons"], ["Actual source enqueue exceeded the unchanged 50ms deadline at indices [999]"])
        self.assertIn("sourceEvents", row["result"]["core"])

    def test_unexpected_exception_retains_invalid_row_then_aborts(self):
        self.q.raise_in_run = AttributeError("unexpected fixture error")
        with self.assertRaises(AttributeError): self.execute_cell()
        self.assertFalse(self.last_row["valid"])
        saved = json.loads((self.root / "result/run.json").read_text())
        self.assertEqual(saved["exception"]["type"], "AttributeError")

    def test_keyboard_interrupt_is_not_swallowed(self):
        self.q.raise_in_run = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt): self.execute_cell()
        self.assertFalse(self.last_row["valid"])
        self.assertTrue((self.root / "result/run.json").is_file())

    def test_cleanup_failure_is_invalid_and_aborts_next_cells(self):
        with self.assertRaises(OSError): self.execute_cell(cleanup_error=OSError("cannot verify owned process"))
        self.assertFalse(self.last_row["valid"])
        self.assertTrue(any("cleanup failed" in message for message in self.last_row["invalidReasons"]))

    def test_partial_report_does_not_erase_plan_or_failure(self):
        output = self.root / "partial"
        output.mkdir()
        row = {**control.planned_runs()[0], "valid": False, "invalidReasons": ["test retained failure"], "result": None}
        report = {"status": "failed", "plan": control.planned_runs(), "runs": [row], "packages": {}, "errors": []}
        control.save_report(output, report)
        saved = json.loads((output / "report.json").read_text())
        self.assertEqual(len(saved["plan"]), 8)
        self.assertFalse(any(group["valid"] for group in saved["groups"]))
        self.assertIn("test retained failure", (output / "report.md").read_text())


if __name__ == "__main__":
    unittest.main()
