import AppKit
import XCTest

// The UI-test runner is sandboxed by Xcode even for a non-sandboxed target.
// Use its public loopback client capability, not broader signing entitlements.
private func exchange(_ path: String, _ value: [String: Any] = [:]) throws -> [String: Any] {
    let env = ProcessInfo.processInfo.environment
    var request = URLRequest(url: URL(string: env["BENCH_HITCH_URL"]! + path)!)
    request.httpMethod = "POST"
    request.setValue(env["BENCH_HITCH_TOKEN"]!, forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: value)
    let semaphore = DispatchSemaphore(value: 0)
    var received: Data?, failure: Error?, status = 0
    URLSession.shared.dataTask(with: request) { data, response, error in
        received = data; failure = error; status = (response as? HTTPURLResponse)?.statusCode ?? 0
        semaphore.signal()
    }.resume()
    guard semaphore.wait(timeout: .now() + 10) == .success, status == 200 else {
        throw failure ?? NSError(domain: "benchmark-control-http", code: status)
    }
    return try JSONSerialization.jsonObject(with: received!) as! [String: Any]
}

// Inherit the native metric's lifecycle. A protocol wrapper loses XCTest's
// preparation of this metric and fails with an uninitialized signpost range.
@MainActor final class RecordingMetric: XCTHitchMetric {
    var target: XCUIApplication!
    convenience init(target: XCUIApplication) { self.init(application: target); self.target = target }
    override func copy(with zone: NSZone? = nil) -> Any { RecordingMetric(target: target) }
    override func reportMeasurements(from startTime: XCTPerformanceMeasurementTimestamp,
                                     to endTime: XCTPerformanceMeasurementTimestamp) throws -> [XCTPerformanceMeasurement] {
        let values = try super.reportMeasurements(from: startTime, to: endTime)
        let rows = values.map { value -> [String: Any] in
            ["identifier": value.identifier, "displayName": value.displayName,
             "value": value.doubleValue, "unit": value.unitSymbol]
        }
        _ = try exchange("/measurement", ["startNS": startTime.absoluteTimeNanoSeconds,
            "endNS": endTime.absoluteTimeNanoSeconds, "startMach": startTime.absoluteTime,
            "endMach": endTime.absoluteTime, "measurements": rows])
        return values
    }
}

@MainActor final class HitchTests: XCTestCase {
    func testExternalApplication() throws {
        let config = try exchange("/config")
        let expectedURL = URL(fileURLWithPath: try XCTUnwrap(config["app"] as? String)).resolvingSymlinksInPath()
        let pid = Int32(try XCTUnwrap(config["pid"] as? Int))
        let launchDate = try XCTUnwrap(config["launchDate"] as? Double)
        func checkOwner() throws {
            let owner = try XCTUnwrap(NSRunningApplication(processIdentifier: pid), "target no longer running")
            let bundleID = try XCTUnwrap(Bundle(url: expectedURL)?.bundleIdentifier)
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard owner.bundleURL?.resolvingSymlinksInPath() == expectedURL,
                  let actualDate = owner.launchDate, abs(actualDate.timeIntervalSince1970 - launchDate) < 0.001,
                  matches.map(\.processIdentifier) == [pid] else {
                throw NSError(domain: "benchmark-owner", code: 1, userInfo: [NSLocalizedDescriptionKey: "target identity mismatch"])
            }
        }
        try checkOwner()
        // A proxy only: launch/activate could restart a dead application.
        // A native process check alone does not prove that the metric proxy
        // observed that application. Unattached zero-valued metrics are invalid.
        let application = XCUIApplication(url: expectedURL)
        guard application.wait(for: .runningForeground, timeout: 5) else {
            throw NSError(domain: "benchmark-owner", code: 2, userInfo: [NSLocalizedDescriptionKey: "XCTest could not observe the existing foreground target"])
        }
        try checkOwner()
        let metric = RecordingMetric(target: application)
        let options = XCTMeasureOptions(); options.iterationCount = 1
        var invocation = 0
        measure(metrics: [metric], options: options) {
            invocation += 1
            do {
                try checkOwner()
                if invocation == 1 { Thread.sleep(forTimeInterval: 0.2) }
                else if invocation == 2 {
                    _ = try exchange("/ready", ["pid": pid, "launchDate": launchDate,
                                              "collectorPID": ProcessInfo.processInfo.processIdentifier, "readyNS": clock_gettime_nsec_np(CLOCK_UPTIME_RAW)])
                    let deadline = Date().addingTimeInterval(180)
                    var finished = false
                    while Date() < deadline {
                        finished = try exchange("/status")["finished"] as? Bool == true
                        if finished { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    XCTAssertTrue(finished, "external owner did not finish")
                } else { XCTFail("unexpected extra measurement invocation") }
                try checkOwner()
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(invocation, 2)
        _ = try exchange("/owner", ["pid": pid, "launchDate": launchDate, "invocations": invocation])
    }
}
