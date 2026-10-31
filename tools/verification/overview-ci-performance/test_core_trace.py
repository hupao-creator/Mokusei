"""Boundary checks for diagnostic overlays and owned trace receipts."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import core_trace as diagnostic


class OverlayBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.checkout = self.root / "checkout"
        self.overlays = self.root / "overlays"
        self.overlays.mkdir()
        entries = []
        for target in sorted(diagnostic.ALLOWED_TARGETS):
            destination = self.checkout / target
            destination.parent.mkdir(parents=True, exist_ok=True)
            previous = None if "diagnostic" in destination.name else b"original runtime input\n"
            if previous is not None:
                destination.write_bytes(previous)
            name = destination.name + ".txt"
            content = ("reviewed " + destination.name + "\n").encode()
            (self.overlays / name).write_bytes(content)
            entries.append({"target": target, "source": name,
                "beforeSHA256": hashlib.sha256(previous).hexdigest() if previous else None,
                "afterSHA256": hashlib.sha256(content).hexdigest()})
        self.manifest = {"schemaVersion": 1, "files": entries}
        self.save_manifest()

    def save_manifest(self):
        (self.overlays / "manifest.json").write_text(json.dumps(self.manifest))

    def test_stale_last_input_rejects_before_any_write(self):
        final = self.checkout / self.manifest["files"][-1]["target"]
        final.write_text("stale input")
        before = {str(p): p.read_bytes() for p in self.checkout.rglob("*.go")}
        with self.assertRaisesRegex(ValueError, "Unexpected original"):
            diagnostic.apply_overlays(self.checkout, self.overlays)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.checkout.rglob("*.go")})

    def test_product_target_is_rejected(self):
        self.manifest["files"][0]["target"] = "internal/core/runtime/runtime.go"
        self.save_manifest()
        with self.assertRaisesRegex(ValueError, "five reviewed runtime files"):
            diagnostic.apply_overlays(self.checkout, self.overlays)

    def test_symlink_source_cannot_leave_overlay_directory(self):
        entry = self.manifest["files"][0]
        source = self.overlays / entry["source"]
        outside = self.root / "outside.txt"
        outside.write_bytes(source.read_bytes())
        source.unlink(); source.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "leaves its reviewed directory"):
            diagnostic.apply_overlays(self.checkout, self.overlays)

    def test_tampered_overlay_rejects(self):
        (self.overlays / self.manifest["files"][-1]["source"]).write_text("unexpected bytes")
        with self.assertRaisesRegex(ValueError, "overlay content differs"):
            diagnostic.apply_overlays(self.checkout, self.overlays)

    def test_only_reviewed_runtime_inputs_change(self):
        untouched = self.checkout / "internal/core/runtime/runtime.go"
        untouched.parent.mkdir(parents=True); untouched.write_text("production stays original")
        receipt = diagnostic.apply_overlays(self.checkout, self.overlays)
        self.assertEqual(untouched.read_text(), "production stays original")
        self.assertEqual(len(receipt["files"]), 5)
        for entry in receipt["files"]:
            self.assertEqual(hashlib.sha256((self.checkout / entry["target"]).read_bytes()).hexdigest(), entry["afterSHA256"])


class CaptureReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "core.trace"
        # This fixture tests receipt identity only. Real trace decoding is
        # separately exercised by the Go diagnostic tests and by the CI driver.
        self.path.write_bytes(b"receipt validation content")
        expected = "/owned/native-replay/workspace/evidence/core.trace"
        self.row = {"valid": False, "invalidReasons": ["original source deadline exceeded"],
            "namedLaunchEnvironment": {"MOKUSEI_OVERVIEW_CORE_TRACE_PATH": expected},
            "result": {"core": {"clockOriginUptimeNanoseconds": 100}}}
        span_names = ["overview.source.wait", "overview.source.fifo-lock", "overview.source.fifo-clock",
            "overview.source.receipt", "overview.worker.store-update", "overview.publisher.observer"]
        self.receipt = {"schemaVersion": 1, "diagnosticKind": "overview-core-execution-trace", "status": "complete",
            "captureComplete": True, "tracePath": expected, "sidecarPath": expected + ".json",
            "traceBytes": self.path.stat().st_size, "traceSHA256": hashlib.sha256(self.path.read_bytes()).hexdigest(),
            "totalWriterBytes": self.path.stat().st_size, "maximumTraceBytes": 8 * 1024 * 1024,
            "droppedTraceBytes": 0, "overflow": False, "writerError": "", "measurementClockVersion": 2,
            "measurementClockID": "darwin.CLOCK_UPTIME_RAW.ns", "clockOriginUptimeNanoseconds": 100,
            "traceStart": {"beforeUptimeNanoseconds": 110, "afterUptimeNanoseconds": 120},
            "traceStop": {"beforeUptimeNanoseconds": 210, "afterUptimeNanoseconds": 220},
            "maximumRawAnchors": 8192, "rawAnchorCount": 2, "rawAnchorClockErrors": 0, "invalidIdentifiers": 0,
            "rawAnchors": [
                {"category": "overview.trace-start", "message": "lifecycle", "rawBeforeNanoseconds": 125, "rawAfterNanoseconds": 130},
                {"category": "overview.trace-stop", "message": "lifecycle", "rawBeforeNanoseconds": 200, "rawAfterNanoseconds": 205}],
            "pointCounts": {"overview.trace-start": 1, "overview.trace-stop": 1},
            "spanCounts": {name: {"started": 1, "ended": 1} for name in span_names}}

    def test_complete_capture_preserves_invalid_source(self):
        self.assertEqual(diagnostic.validate_capture(self.receipt, self.path, self.row), [])
        self.assertFalse(self.row["valid"])
        self.assertEqual(self.row["invalidReasons"], ["original source deadline exceeded"])
        self.assertFalse(self.row["traceAnnotationMappingVerified"])

    def test_foreign_trace_and_origin_are_rejected(self):
        self.receipt["tracePath"] = "/another/run/core.trace"
        self.receipt["clockOriginUptimeNanoseconds"] += 1
        failures = diagnostic.validate_capture(self.receipt, self.path, self.row)
        self.assertTrue(any("owned launch" in value for value in failures))
        self.assertTrue(any("actual Core" in value for value in failures))

    def test_overflow_prefix_is_not_complete_capture(self):
        self.receipt.update(captureComplete=False, status="incomplete", droppedTraceBytes=99, overflow=True)
        self.assertTrue(diagnostic.validate_capture(self.receipt, self.path, self.row))

    def test_changed_trace_bytes_are_rejected(self):
        self.path.write_bytes(b"changed trace")
        self.assertTrue(any("Trace content" in value for value in diagnostic.validate_capture(self.receipt, self.path, self.row)))

    def test_unclosed_region_and_outside_anchor_are_rejected(self):
        self.receipt["spanCounts"]["overview.worker.store-update"]["ended"] = 0
        self.assertTrue(any("regions" in value for value in diagnostic.validate_capture(self.receipt, self.path, self.row)))
        altered = copy.deepcopy(self.receipt)
        altered["rawAnchors"][1]["rawAfterNanoseconds"] = 300
        self.assertTrue(any("outside" in value for value in diagnostic.validate_capture(altered, self.path, self.row)))


if __name__ == "__main__":
    unittest.main()
