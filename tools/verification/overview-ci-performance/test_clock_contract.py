"""Clock-domain checks with deliberately misleading UTC and exact raw receipts."""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("overview_run", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def clock_fixture():
    identity = {"measurementClockVersion": 2, "measurementClockID": "darwin.CLOCK_UPTIME_RAW.ns"}
    source_identity = {"sourceProtocolVersion": 2, "sourceQueueCapacity": 256}
    origin = 1_000_000_000_000
    wall = 1_790_000_000_000_000_000
    deadlines = {"warmupStart": origin + 1_000_000_000, "formalStart": origin + 6_000_000_000,
                 "formalEnd": origin + 26_000_000_000, "tailObservationEnd": origin + 27_000_000_000}
    schedule = {**identity, **source_identity, "warmupSeconds": 5, "formalSeconds": 20,
                "sourceIntervalNanoseconds": 25_000_000, "clockOriginUptimeNanoseconds": origin}
    for name, at in deadlines.items():
        if name != "tailObservationEnd":
            schedule[name + "UptimeNanoseconds"] = at
            schedule[name + "UnixNano"] = wall + at - origin
    clock = {"schedule": copy.deepcopy(schedule), "rawDispatchChecks": [],
             "anchor": {"uptimeNanoseconds": origin, "unixNanoseconds": wall, "uncertaintyNanoseconds": 100},
             "endAnchor": {"uptimeNanoseconds": origin + 27_100_000_000,
                           "unixNanoseconds": wall + 27_100_000_000, "uncertaintyNanoseconds": 100}}
    boundaries = {}
    for name, at in deadlines.items():
        clock[name] = {"status": "captured", "plannedUptimeNanoseconds": at, "uptimeNanoseconds": at + 100_000,
                       "boundaryOffsetMilliseconds": 0.1, "dispatchDeadlineUptimeNanoseconds": at,
                       "deadlineRoundTripOffsetNanoseconds": 0}
        if name != "tailObservationEnd":
            boundaries[name] = {"plannedUptimeNanoseconds": at, "actualUptimeNanoseconds": at + 100_000}
    boundaries["observationEnd"] = {"actualUptimeNanoseconds": deadlines["tailObservationEnd"] + 100_000}
    for stage, at in (("beforeSource", origin), ("afterCPUWindows", origin + 27_100_000_000)):
        clock["rawDispatchChecks"].append({"stage": stage, "rawBeforeUptimeNanoseconds": at,
            "dispatchUptimeNanoseconds": at + 100, "rawAfterUptimeNanoseconds": at + 200,
            "uncertaintyNanoseconds": 100, "offsetNanoseconds": 0, "outsideBracketNanoseconds": 0,
            "maximumAllowedUncertaintyNanoseconds": 5_000_000, "valid": True})
    observations = []
    for index, stage in enumerate(("ready", "start", "status", "result", "final")):
        at = origin + (index + 1) * 1_000_000
        observations.append({**identity, "stage": stage, "clockOriginUptimeNanoseconds": origin,
            "startedUptimeNanoseconds": at - 1000, "finishedUptimeNanoseconds": at + 1000,
            "clockObservation": {"uptimeNanoseconds": at, "unixNanoseconds": wall + at - origin,
                                 "uncertaintyNanoseconds": 100},
            "maximumAllowedUncertaintyNanoseconds": 5_000_000, "valid": True})
    source = {"planned": 0, "enqueued": 0, "dequeued": 0, "sent": 0, "accepted": 0, "errors": []}
    for name, gate in (("enqueueDeadline", True), ("legacySentDeadline", False)):
        source[name] = {"thresholdMilliseconds": 50, "observedCount": 0, "missingCount": 0, "exceededCount": 0,
                        "exceededIndices": [], "wouldFail": False, "isValidityGate": gate, "maxLatenessMilliseconds": 0}
    windows = {}
    for phase, first, last in (("warmup", "warmupStart", "formalStart"),
                               ("formal", "formalStart", "formalEnd"),
                               ("tail", "formalEnd", "tailObservationEnd")):
        windows[phase] = {"startUptimeNanoseconds": deadlines[first] + 100_000,
                          "endUptimeNanoseconds": deadlines[last] + 100_000, "publishes": 0}
        for stage in ("planned", "enqueued", "dequeued", "sent", "accepted"):
            windows[phase][stage] = 0
            source[phase + stage.capitalize()] = 0
    core = {**identity, **source_identity, "clockOriginUptimeNanoseconds": origin,
            "schedule": schedule, "boundaries": boundaries, "cpu": {"wallSeconds": 20},
            "sourceComplete": True, "enqueueComplete": True, "producerFinished": True, "source": source,
            "sourceEvents": [], "publications": [], "windows": windows,
            "queue": {"capacity": 256, "closed": True, "overflowCount": 0, "pending": 0, "inFlight": 0,
                      "pendingIndices": [], "inFlightIndex": -1, "highWater": 0,
                      "observedAt": {"uptimeNanoseconds": origin + 28_000_000_000, "elapsedNanoseconds": 28_000_000_000}}}
    return {**identity, "comparisonIdentity": dict(identity), "core": core, "clock": clock,
            "measurementClockChecks": {stage: True for stage in ("ready", "start", "status", "result", "final")},
            "clockObservations": observations, "ui": {"wallSeconds": 20},
            "uiWindows": {"sourceThroughTailObservation": {"wallSeconds": 26}, "tailObservation": {"wallSeconds": 1}}}


def perturb_utc(value):
    """A backward step plus alternating slew affects every logged UTC field."""
    if isinstance(value, dict):
        for key, child in value.items():
            if "unix" in key.lower() and isinstance(child, int):
                value[key] = child - 7_000_000_000 + (child % 23) * 500_000
            else:
                perturb_utc(child)
    elif isinstance(value, list):
        for child in value:
            perturb_utc(child)


def loaded_source_fixture():
    value = clock_fixture()["core"]
    origin = value["clockOriginUptimeNanoseconds"]
    start = value["schedule"]["warmupStartUptimeNanoseconds"]
    for index in range(1000):
        event = {"index": index, "cardID": f"card-{index % 4}", "seq": index // 4, "commitSucceeded": True}
        for stage, delay in (("planned", 0), ("enqueued", 200_000), ("dequeued", 400_000), ("sent", 500_000),
                             ("storeUpdateStarted", 800_000), ("accepted", 1_200_000), ("completed", 1_500_000)):
            at = start + index * 25_000_000 + delay
            event[stage + "UptimeNanoseconds"] = at
            event[stage + "ElapsedNanoseconds"] = at - origin
            event[stage + "UnixNano"] = 1_790_000_000_000_000_000 + at - origin
        value["sourceEvents"].append(event)
    value["queue"]["highWater"] = 1
    for stage in ("planned", "enqueued", "dequeued", "sent", "accepted"):
        value["source"][stage] = 1000
        for phase, count in (("warmup", 200), ("formal", 799 if stage == "planned" else 800), ("tail", 0)):
            value["windows"][phase][stage] = count
            value["source"][phase + stage.capitalize()] = count
    for name, lateness in (("enqueueDeadline", 0.2), ("legacySentDeadline", 0.5)):
        value["source"][name]["observedCount"] = 1000
        value["source"][name]["maxLatenessMilliseconds"] = lateness
    return value


class ClockContractTests(unittest.TestCase):
    def test_known_raw_clock_contract(self):
        value = clock_fixture()
        self.assertEqual(runner.validate_measurement_clock(value), [])
        self.assertEqual(runner.validate_source_v2(value["core"], "R0"), [])

    def test_wall_step_and_slew_do_not_move_raw_validation(self):
        value = clock_fixture()
        perturb_utc(value)
        value["clock"]["realtimeAnchorDriftMilliseconds"] = -7000
        self.assertEqual(runner.validate_measurement_clock(value), [])
        self.assertEqual(runner.validate_source_v2(value["core"], "R0"), [])

    def test_loaded_source_windows_and_deadlines_ignore_utc_steps(self):
        value = loaded_source_fixture()
        self.assertEqual(runner.validate_source_v2(value, "S4"), [])
        perturb_utc(value)
        self.assertEqual(runner.validate_source_v2(value, "S4"), [])

    def test_count_windows_cannot_shrink_independently_of_cpu_boundaries(self):
        value = clock_fixture()["core"]
        value["windows"]["formal"]["startUptimeNanoseconds"] += 1_000_000_000
        value["windows"]["formal"]["endUptimeNanoseconds"] -= 1_000_000_000
        self.assertIn("formal Core count window differs from its actual CPU boundaries", runner.validate_source_v2(value, "R0"))

    def test_schedule_origin_must_match_the_source_receipts(self):
        value = clock_fixture()["core"]
        value["schedule"]["clockOriginUptimeNanoseconds"] += 1_000_000_000
        self.assertIn("Source schedule and Core result have different shared-clock origins", runner.validate_source_v2(value, "R0"))

    def test_a_timestamp_cannot_invent_a_successful_store_commit(self):
        value = loaded_source_fixture()
        value["sourceEvents"][0]["commitSucceeded"] = False
        self.assertTrue(runner.validate_source_v2(value, "S4"))

    def test_timely_utc_cannot_hide_a_late_actual_enqueue(self):
        value = loaded_source_fixture()
        event = value["sourceEvents"][-1]
        for stage in ("enqueued", "dequeued", "sent", "storeUpdateStarted", "accepted", "completed"):
            event[stage + "UptimeNanoseconds"] += 51_000_000
            event[stage + "ElapsedNanoseconds"] += 51_000_000
        for stage in ("enqueued", "dequeued", "sent", "accepted"):
            value["windows"]["formal"][stage] -= 1
            value["windows"]["tail"][stage] += 1
            value["source"]["formal" + stage.capitalize()] -= 1
            value["source"]["tail" + stage.capitalize()] += 1
        for name, maximum in (("enqueueDeadline", 51.2), ("legacySentDeadline", 51.5)):
            value["source"][name].update(exceededCount=1, exceededIndices=[999], wouldFail=True, maxLatenessMilliseconds=maximum)
        reasons = runner.validate_source_v2(value, "S4")
        self.assertEqual(reasons, ["Actual source enqueue exceeded the unchanged 50ms deadline at indices [999]"])

    def test_wrong_clock_epoch_is_rejected_despite_matching_id(self):
        value = clock_fixture()
        value["clockObservations"][1]["clockObservation"]["uptimeNanoseconds"] += 1_000_000_000
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_origin_cannot_change_between_responses(self):
        value = clock_fixture()
        value["clockObservations"][-1]["clockOriginUptimeNanoseconds"] += 1
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_missing_handshake_evidence_cannot_be_replaced_with_true_flags(self):
        value = clock_fixture()
        value["clockObservations"].pop()
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_clock_id_version_and_json_types_fail_closed(self):
        for field, invalid in (("measurementClockID", "linux.CLOCK_MONOTONIC_RAW.ns"),
                               ("measurementClockVersion", 1), ("measurementClockVersion", True)):
            with self.subTest(field=field, invalid=invalid):
                value = clock_fixture()
                value["core"][field] = invalid
                self.assertTrue(runner.validate_measurement_clock(value))
        value = clock_fixture()
        value["clockObservations"][0]["stage"] = []
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_dispatch_and_observation_uncertainty_keep_five_ms_gate(self):
        for target in ("dispatch", "observation"):
            with self.subTest(target=target):
                value = clock_fixture()
                if target == "dispatch":
                    row = value["clock"]["rawDispatchChecks"][0]
                    row["dispatchUptimeNanoseconds"] += 6_000_000
                    row["offsetNanoseconds"] = 6_000_000
                    row["outsideBracketNanoseconds"] = 5_999_900
                else:
                    value["clockObservations"][0]["clockObservation"]["uncertaintyNanoseconds"] = 5_000_001
                self.assertTrue(runner.validate_measurement_clock(value))

    def test_odd_nanosecond_brackets_round_uncertainty_up(self):
        value = clock_fixture()
        row = value["clock"]["rawDispatchChecks"][0]
        row["rawAfterUptimeNanoseconds"] += 1
        row["uncertaintyNanoseconds"] = 101
        self.assertEqual(runner.validate_measurement_clock(value), [])

    def test_raw_dispatch_checks_must_cover_both_ends(self):
        value = clock_fixture()
        value["clock"]["rawDispatchChecks"][1] = copy.deepcopy(value["clock"]["rawDispatchChecks"][0])
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_bad_anchor_uncertainty_remains_invalid_even_when_utc_is_diagnostic(self):
        value = clock_fixture()
        value["clock"]["endAnchor"]["uncertaintyNanoseconds"] = 5_000_001
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_source_and_ui_deadlines_must_be_the_same_absolute_raw_time(self):
        value = clock_fixture()
        value["core"]["schedule"]["formalStartUptimeNanoseconds"] += 1_000_000_000
        self.assertTrue(runner.validate_measurement_clock(value))
        self.assertTrue(runner.validate_source_v2(value["core"], "R0"))

    def test_cpu_denominator_and_lateness_are_independently_recomputed(self):
        value = clock_fixture()
        value["ui"]["wallSeconds"] = 19
        self.assertTrue(runner.validate_measurement_clock(value))
        value = clock_fixture()
        mark = value["clock"]["formalEnd"]
        mark["uptimeNanoseconds"] += 51_000_000
        mark["boundaryOffsetMilliseconds"] += 51
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_exact_and_coalesced_model_latency_ignore_misleading_utc(self):
        value = clock_fixture()
        origin = value["core"]["clockOriginUptimeNanoseconds"]
        base = origin + 6_000_000_000
        events = []
        for index, seq, shift in ((0, 0, 0), (4, 1, 100_000_000)):
            event = {"index": index, "cardID": "card-0", "seq": seq, "commitSucceeded": True}
            for stage, offset in (("planned", 0), ("enqueued", 1_000_000), ("accepted", 12_000_000)):
                event[stage + "UptimeNanoseconds"] = base + shift + offset
                event[stage + "UnixNano"] = 1_790_000_000_000_000_000 + shift + offset
            events.append(event)
        value["core"]["sourceEvents"] = events
        publication = base + 110_000_000
        value["core"]["publications"] = [{"revision": 9, "publishedUptimeNanoseconds": publication,
            "publishedElapsedNanoseconds": publication - origin, "publishedUnixNano": 1_790_000_100_000_000_000,
            "cardIDs": ["card-0"], "seqs": [1]}]
        value["installations"] = {"records": [{"kind": "mutation", "catalogRevision": 9,
            "uptimeNanoseconds": base + 115_000_000, "estimatedUnixNanoseconds": 1_790_000_000_000_000_000,
            "sequences": [1, -1, -1, -1]}]}
        value["core"]["expectedCards"] = [{"id": f"card-{i}", "seq": 1 if i == 0 else -1} for i in range(4)]
        before = runner.source_flow(value)
        model_before = runner.model_flow(value)
        self.assertEqual(before["counts"]["coalescedBeforePublication"], 1)
        self.assertEqual(before["counts"]["exactInstalled"], 1)
        self.assertEqual(before["latency"]["acceptedToPublicationMilliseconds"]["min"], -2)
        self.assertEqual(before["latency"]["enqueueToModelInstallMilliseconds"]["p95"], 14)
        self.assertEqual(model_before["finalSequenceInstallAfterLastSourceAcceptedMilliseconds"], 3)
        self.assertNotIn("firstExactModelInstallation", before["records"][0])
        perturb_utc(value)
        after = runner.source_flow(value)
        self.assertEqual(after["latency"], before["latency"])
        self.assertEqual(after["counts"], before["counts"])
        self.assertEqual(runner.model_flow(value), model_before)

    def test_historical_clock_results_are_not_reinterpreted(self):
        value = clock_fixture()
        value["core"].pop("measurementClockVersion")
        self.assertFalse(runner.source_flow(value)["available"])
        self.assertIn("unavailableReason", runner.model_flow(value))
        self.assertTrue(runner.validate_measurement_clock(value))

    def test_cross_process_flow_requires_both_clock_identities(self):
        value = clock_fixture()
        value["measurementClockID"] = "wrong-epoch"
        self.assertFalse(runner.source_flow(value)["available"])
        self.assertIn("unavailableReason", runner.model_flow(value))


if __name__ == "__main__":
    unittest.main()
