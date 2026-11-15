import MokuseiCore
@testable import MokuseiPluginUI
import Testing

@MainActor
@Suite(.serialized)
struct HarnessDetailBodyGateTests {
    private func waitUntil(timeout: Duration = .seconds(2), _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Condition did not settle within \(timeout)")
    }

    @Test func fourAdmissionsThenTwoSlotsStayBounded() async throws {
        let gate = HarnessDetailBodyGate()
        var capacity = 4
        let limit = { @MainActor in capacity }
        var admissions: [HarnessDetailBodyGate.Admission] = []
        for _ in 0..<4 {
            admissions.append(try #require(await gate.acquire(limit: limit)))
        }
        #expect(gate.activeViewCount == 4)

        // A competing surface leaves two slots after all views were admitted.
        capacity = 2
        var granted = 0
        var activeReservations: [HarnessDetailBodyGate.PageReservation] = []
        var maximumBodyResources = 0
        let tasks = (0..<4).map { _ in
            Task { @MainActor in
                guard let reservation = try await gate.reservePage(capacity: limit) else { return }
                granted += 1
                activeReservations.append(reservation)
                maximumBodyResources = max(maximumBodyResources, activeReservations.count)
            }
        }
        try await waitUntil { granted == 2 }
        #expect(gate.pageReservationCount == 2)
        #expect(maximumBodyResources == 2)
        #expect(30 + maximumBodyResources <= 32)

        // Releasing the two page leases lets the waiting siblings proceed.
        for reservation in activeReservations {
            gate.releasePage(reservation)
        }
        activeReservations.removeAll()
        try await waitUntil { granted == 4 }
        #expect(maximumBodyResources <= 2)
        #expect(28 + 2 + maximumBodyResources <= 32)

        for reservation in activeReservations {
            gate.releasePage(reservation)
        }
        for admission in admissions { gate.release(admission) }
        tasks.forEach { $0.cancel() }
        try await waitUntil { gate.activeViewCount == 0 && gate.pageReservationCount == 0 }
    }

    @Test func fourAdmissionsThenZeroSlotsRecoverFromExternalRelease() async throws {
        let gate = HarnessDetailBodyGate()
        var capacity = 4
        var capacityReads = 0
        let limit = { @MainActor in
            capacityReads += 1
            return capacity
        }
        var admissions: [HarnessDetailBodyGate.Admission] = []
        for _ in 0..<4 {
            admissions.append(try #require(await gate.acquire(limit: limit)))
        }
        #expect(gate.activeViewCount == 4)

        // External (non-body) resources consume every slot. No gate release
        // happens here, so only the page-reservation poll can observe recovery.
        capacity = 0
        var started = 0
        var granted = 0
        var activeReservations: [HarnessDetailBodyGate.PageReservation] = []
        var maximumBodyResources = 0
        let tasks = (0..<4).map { _ in
            Task { @MainActor in
                started += 1
                guard let reservation = try await gate.reservePage(capacity: limit) else { return }
                granted += 1
                activeReservations.append(reservation)
                maximumBodyResources = max(maximumBodyResources, activeReservations.count)
            }
        }
        // Barrier instead of a wall-clock observation window: all four page
        // tasks must have started and read the zero capacity.
        try await waitUntil(timeout: .seconds(1)) { started == 4 && capacityReads >= 8 }
        #expect(granted == 0)
        #expect(gate.pageReservationCount == 0)

        // The external surface releases four slots; polling must recover.
        capacity = 4
        try await waitUntil(timeout: .seconds(5)) { granted == 4 }
        #expect(gate.pageReservationCount == 4)
        #expect(28 + maximumBodyResources <= 32)

        for reservation in activeReservations {
            gate.releasePage(reservation)
        }
        for admission in admissions { gate.release(admission) }
        tasks.forEach { $0.cancel() }
        try await waitUntil { gate.activeViewCount == 0 && gate.pageReservationCount == 0 }
    }

    @Test func capacityChangesMoreThanThreeTimesStillRecover() async throws {
        let gate = HarnessDetailBodyGate()
        var capacity = 4
        let limit = { @MainActor in capacity }
        var admissions: [HarnessDetailBodyGate.Admission] = []
        for _ in 0..<4 {
            admissions.append(try #require(await gate.acquire(limit: limit)))
        }

        capacity = 0
        var granted = 0
        var activeReservations: [HarnessDetailBodyGate.PageReservation] = []
        var maximumBodyResources = 0
        let tasks = (0..<4).map { _ in
            Task { @MainActor in
                guard let reservation = try await gate.reservePage(capacity: limit) else { return }
                granted += 1
                activeReservations.append(reservation)
                maximumBodyResources = max(maximumBodyResources, activeReservations.count)
            }
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(granted == 0)

        // More than three external capacity changes, including zero, before the
        // final release. No stale admission may exceed the 32-resource cap.
        for value in [1, 0, 2, 0, 3, 0, 4] {
            capacity = value
            try await Task.sleep(for: .milliseconds(40))
        }
        try await waitUntil(timeout: .seconds(4)) { granted == 4 }
        #expect(maximumBodyResources <= 4)
        #expect(28 + maximumBodyResources <= 32)

        for reservation in activeReservations {
            gate.releasePage(reservation)
        }
        for admission in admissions { gate.release(admission) }
        tasks.forEach { $0.cancel() }
        try await waitUntil { gate.activeViewCount == 0 && gate.pageReservationCount == 0 }
    }


    @Test func pageReservationTimeoutReturnsCapacityRetry() async throws {
        let gate = HarnessDetailBodyGate(pageCapacityTimeout: .milliseconds(120))
        var capacity = 1
        let admission = try #require(await gate.acquire(limit: { capacity }))
        capacity = 0
        let start = ContinuousClock.now
        let reservation = try await gate.reservePage(capacity: { capacity })
        #expect(reservation == nil)
        #expect(ContinuousClock.now - start >= .milliseconds(100))
        #expect(gate.pageReservationCount == 0)
        gate.release(admission)
        try await waitUntil { gate.activeViewCount == 0 }
    }

    @Test func externalCapacityAdmitsWaitingViewWithoutGateRelease() async throws {
        let gate = HarnessDetailBodyGate(pageCapacityTimeout: .seconds(2))
        var capacity = 1
        let limit = { @MainActor in capacity }
        let first = try #require(await gate.acquire(limit: limit))
        var second: HarnessDetailBodyGate.Admission?
        let task = Task { @MainActor in
            second = try await gate.acquire(limit: limit)
        }
        try await waitUntil { gate.waiterCount == 1 }

        // A non-body surface frees a slot; no gate release occurs. The periodic
        // capacity poll must wake the waiting view admission.
        capacity = 2
        try await waitUntil(timeout: .seconds(2)) { second != nil }
        #expect(second != nil)
        #expect(gate.activeViewCount == 2)
        if let second { gate.release(second) }
        gate.release(first)
        task.cancel()
        try await waitUntil { gate.activeViewCount == 0 }
    }

    @Test func releaseDuringNewWaiterRegistrationDoesNotLoseWake() async throws {
        let gate = HarnessDetailBodyGate()
        var capacity = 1
        let limit = { @MainActor in capacity }
        let dummy = try #require(await gate.acquire(limit: limit))
        #expect(gate.activeViewCount == 1)

        var first: HarnessDetailBodyGate.Admission?
        let firstTask = Task { @MainActor in
            first = try await gate.acquire(limit: limit)
        }
        try await waitUntil { gate.waiterCount == 1 }

        var second: HarnessDetailBodyGate.Admission?
        gate.beforeWaitForTesting = { [weak gate] in
            guard let gate else { return }
            capacity = 2
            gate.release(dummy)
        }
        let secondTask = Task { @MainActor in
            second = try await gate.acquire(limit: limit)
        }
        try await waitUntil { second != nil }
        gate.beforeWaitForTesting = nil
        #expect(second != nil)
        try await waitUntil { first != nil }

        if let second { gate.release(second) }
        if let first { gate.release(first) }
        firstTask.cancel(); secondTask.cancel()
        try await waitUntil { gate.activeViewCount == 0 }
    }
}
