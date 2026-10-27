import Foundation

// Compile together with the production renderer; this replay needs no app/runtime.
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let motion = NativeCloudMotion(seed: 42)
let otherSurface = NativeCloudMotion(seed: 43)
let framesPerSecond = Int(NativeFrameRate.framesPerSecond)
var largestFrameStep = 0.0
var surfaceDifference = 0.0
var laneDifference = 0.0
var oldLoopDifference = 0.0
for lane in UInt64(0)..<14 {
    var previous = motion.value(at: 0, lane: lane)
    // Two minutes at display cadence crosses many independent waypoint arrivals.
    for frame in 1...(120 * framesPerSecond) {
        let time = Double(frame) * NativeFrameRate.interval
        let value = motion.value(at: time, lane: lane)
        require(value.isFinite && (-1...1).contains(value), "Unbounded cloud motion")
        largestFrameStep = max(largestFrameStep, abs(value - previous))
        require(value == motion.value(at: time, lane: lane), "Repeated drawing must be stable")
        if frame % framesPerSecond == 0 {
            surfaceDifference += abs(value - otherSurface.value(at: time, lane: lane))
            laneDifference += abs(value - motion.value(at: time, lane: lane + 1))
            oldLoopDifference += abs(value - motion.value(at: time + 200 * .pi, lane: lane))
        }
        previous = value
    }
    // Enter and leave a long hidden interval directly, without replaying frames.
    for time in [3.8, 86_400.0, 31_536_000.0] {
        let value = motion.value(at: time, lane: lane)
        let epsilon = 0.0001
        let left = motion.value(at: time - epsilon, lane: lane)
        let right = motion.value(at: time + epsilon, lane: lane)
        require(value.isFinite && (-1...1).contains(value), "Hidden interval produced invalid motion")
        require(abs(right - left) < 0.001, "Hidden interval broke continuity")
    }
}
require(largestFrameStep < 0.016 * 60 / NativeFrameRate.framesPerSecond, "Motion jumps between display frames")
require(surfaceDifference > 100, "Separate surfaces move in sync")
require(laneDifference > 100, "Separate motion lanes move in sync")
require(oldLoopDifference > 100, "The former trigonometric loop still repeats")
print("PASS: bounded smooth motion, stable samples, independent surfaces/lanes, no former loop, long hidden intervals")
print("Largest normalized \(framesPerSecond) Hz step: \(largestFrameStep)")
