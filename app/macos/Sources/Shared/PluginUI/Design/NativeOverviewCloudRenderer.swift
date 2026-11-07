import Foundation
import Metal
import MokuseiCore
import QuartzCore
import SwiftUI

/// Immutable Metal objects shared by Overview clouds. No drawable is allocated
/// while deciding whether the native path is available.
final class NativeOverviewCloudPipeline: @unchecked Sendable {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let state: MTLRenderPipelineState

    @MainActor static let shared: NativeOverviewCloudPipeline? = {
        do { return try NativeOverviewCloudPipeline() }
        catch {
            NSLog("Mokusei Overview cloud: native pipeline unavailable; using SwiftUI: %@", String(describing: error))
            return nil
        }
    }()

    @MainActor private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PipelineError.noDevice
        }
        let library = try device.makeLibrary(URL: NativeCloudMetalField.libraryURL)
        guard let vertex = library.makeFunction(name: "nativeCloudVertex"),
              let fragment = library.makeFunction(name: "nativeCloudFragment") else {
            throw PipelineError.missingFunctions
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Overview cloud"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        // The shared shader already sums and clamps its premultiplied field.
        descriptor.colorAttachments[0].isBlendingEnabled = false
        self.device = device
        commandQueue = queue
        state = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private enum PipelineError: Error { case noDevice, missingFunctions }
}

struct NativeOverviewCloudFrame: Sendable {
    let geometry: [Float]
    let colors: [SIMD4<Float16>]
    let pointSize: SIMD2<Float>
}

/// Value-only input admitted on the main actor. No view or environment lookup is
/// allowed from the render driver; color resolution remains at the UI boundary.
struct NativeOverviewCloudInput: Sendable {
    let palette: NativeCloudPalette
    let colors: [SIMD4<Float16>]
    let colorScheme: ColorScheme
    let size: CGSize
    let seed: UInt64
    let startedAt: Date
    let frozenMotionTime: TimeInterval
    let animates: Bool
    let targetIntensity: Double
    let fadeFrom: Double?
    let fadeStartedAt: TimeInterval?

    func sample() -> (frame: NativeOverviewCloudFrame, continues: Bool) {
        let progress = fadeStartedAt.map { min(1, max(0, (CACurrentMediaTime() - $0) / 0.4)) } ?? 1
        let value = fadeFrom.map { $0 + (targetIntensity - $0) * UnitCurve.easeInOut.value(at: progress) }
            ?? targetIntensity
        let time = animates ? Date().timeIntervalSince(startedAt) : frozenMotionTime
        // A zero-energy terminal frame clears the Metal surface without waiting
        // for a main-actor callback to hide it after a fade-out.
        var lights = NativeCloudField(palette: palette, intensity: max(value, 0.000001),
            time: time * 1.4 + palette.phase, seed: seed).lights(in: size, colorScheme: colorScheme)
        if value <= 0 {
            for index in stride(from: 4, to: lights.geometry.count, by: 5) { lights.geometry[index] = 0 }
        }
        return (NativeOverviewCloudFrame(geometry: lights.geometry, colors: colors,
            pointSize: SIMD2(Float(size.width), Float(size.height))),
            progress < 1 || (animates && value > 0))
    }
}

/// The main actor owns the layer's geometry/visibility; this serial queue alone
/// requests drawables and encodes commands. Mutable buffers belong to that queue.
/// A locked generation retires queued work, and one permit bounds submitted work
/// without blocking the main actor or building a backlog of stale animation frames.
final class NativeOverviewCloudRenderer: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let pipeline: NativeOverviewCloudPipeline
    private let queue = DispatchQueue(label: "com.mokusei.overview.cloud-render", qos: .userInteractive)
    private let permit = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopped = false
    private var loggedFailure = false
    private var geometryBuffer: MTLBuffer?
    private var colorBuffer: MTLBuffer?
    // Timer and immutable input are owned exclusively by queue.
    private var timer: DispatchSourceTimer?
    private var driverRevision: UInt64 = 0

    init(layer: CAMetalLayer, pipeline: NativeOverviewCloudPipeline) {
        self.layer = layer
        self.pipeline = pipeline
    }

    @discardableResult
    func retireFrames() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func stop() {
        pause()
        lock.lock(); defer { lock.unlock() }
        stopped = true
        generation &+= 1
    }

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.driverRevision &+= 1
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Independent, screen-rate-capped sampling; nextDrawable and the one-frame
    /// permit provide backpressure. This is not a display-link/FPS guarantee.
    func drive(_ input: NativeOverviewCloudInput, generation: UInt64, interval: Double,
               completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.accepts(generation) else { return }
            self.timer?.cancel()
            self.driverRevision &+= 1
            let revision = self.driverRevision
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            var first = true
            timer.setEventHandler { [weak self] in
                // Cancellation can leave a delivered event queued behind a new input.
                guard let self, self.driverRevision == revision else { return }
                guard self.accepts(generation) else {
                    self.timer?.cancel(); self.timer = nil; return
                }
                guard self.permit.wait(timeout: .now()) == .success else { return }
                autoreleasepool {
                    // A span binds the sampled frame and its GPU completion
                    // to one recording. No handler or timestamps are allocated
                    // while recording is off. The context is this layer's local
                    // identity, not a model or business identifier.
                    let work = NativePerformance.begin(.metalGPU,
                        context: UInt64(UInt(bitPattern: ObjectIdentifier(self.layer))),
                        values: ["sampleAt": CACurrentMediaTime()])
                    let sample = input.sample()
                    // Static draws and terminal fade frames stop only after success;
                    // a missing drawable must remain retryable without main ticks.
                    let notify = first
                    first = false
                    self.encode(sample.frame, generation: generation, work: work) { [weak self] succeeded in
                        if notify { completion(succeeded) }
                        if succeeded && !sample.continues {
                            self?.queue.async { [weak self] in
                                guard let self, self.driverRevision == revision else { return }
                                self.timer?.cancel()
                                self.timer = nil
                            }
                        }
                    }
                }
            }
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
            self.timer = timer
            timer.resume()
        }
    }

    private func accepts(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && generation == value
    }

    private func encode(_ frame: NativeOverviewCloudFrame, generation: UInt64,
                        work: NativePerformanceSpan?,
                        completion: (@Sendable (Bool) -> Void)?) {
        // nextDrawable can block until its timeout. It never runs on the main
        // actor, and detached/hidden generations are checked on either side.
        guard accepts(generation), !frame.geometry.isEmpty, !frame.colors.isEmpty,
              let drawable = layer.nextDrawable(), accepts(generation),
              let commands = pipeline.commandQueue.makeCommandBuffer() else {
            permit.signal(); completion?(false); return
        }
        let geometryBytes = frame.geometry.count * MemoryLayout<Float>.stride
        let colorBytes = frame.colors.count * MemoryLayout<SIMD4<Float16>>.stride
        if (geometryBuffer?.length ?? 0) < geometryBytes {
            geometryBuffer = pipeline.device.makeBuffer(length: geometryBytes, options: .storageModeShared)
        }
        if (colorBuffer?.length ?? 0) < colorBytes {
            colorBuffer = pipeline.device.makeBuffer(length: colorBytes, options: .storageModeShared)
        }
        guard let geometryBuffer, let colorBuffer else {
            logFailure("Could not allocate cloud parameter buffers")
            permit.signal(); completion?(false); return
        }
        frame.geometry.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(geometryBuffer.contents(), base, bytes.count) }
        }
        frame.colors.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(colorBuffer.contents(), base, bytes.count) }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            logFailure("Could not create cloud render encoder")
            permit.signal(); completion?(false); return
        }
        var uniforms = Uniforms(pointsPerPixel: frame.pointSize / SIMD2(Float(drawable.texture.width), Float(drawable.texture.height)),
                                geometryCount: UInt32(frame.geometry.count), colorCount: UInt32(frame.colors.count))
        encoder.setRenderPipelineState(pipeline.state)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBuffer(geometryBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(colorBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        guard accepts(generation) else { permit.signal(); completion?(false); return }
        let presentation = work.flatMap { work -> NativePerformanceSpan? in
            let span = NativePerformance.begin(.metalPresented, context: work.id)
            // A recorder can be replaced while a drawable is acquired. Never
            // associate its later presentation with a different recording.
            return span?.recordingID == work.recordingID ? span : nil
        }
        if let presentation {
            drawable.addPresentedHandler { drawable in
                // Preserve zero as unavailable/dropped presentation evidence.
                // Capture only the span; retaining the drawable would cycle.
                let presentedAt = drawable.presentedTime
                presentation.end(presentedAt > 0 ? .completed : .failed,
                    values: ["presentedAt": presentedAt, "callbackAt": CACurrentMediaTime()])
            }
        }
        // This host timestamp bounds the immediate present/commit sequence.
        // The existing completion handler proves the command buffer reached the
        // GPU and finished; its host interval is not a GPU-duration measurement.
        let submittedAt = work.map { _ in CACurrentMediaTime() }
        commands.addCompletedHandler { [self] commands in
            let succeeded = commands.status == .completed
            if let work, let submittedAt {
                work.end(succeeded ? .completed : .failed,
                    values: ["submittedAt": submittedAt, "completedAt": CACurrentMediaTime(),
                             "commandStatus": Double(commands.status.rawValue)])
            }
            if !succeeded { logFailure(commands.error.map { String(describing: $0) } ?? "Cloud command buffer failed") }
            permit.signal()
            completion?(succeeded && accepts(generation))
        }
        commands.present(drawable)
        commands.commit()
    }

    private func logFailure(_ message: String) {
        lock.lock()
        let shouldLog = !loggedFailure
        loggedFailure = true
        lock.unlock()
        if shouldLog { NSLog("Mokusei Overview cloud: %@", message) }
    }

    /// Matches NativeCloudUniforms in CloudLoading.metal (16 bytes).
    private struct Uniforms {
        let pointsPerPixel: SIMD2<Float>
        let geometryCount: UInt32
        let colorCount: UInt32
    }
}
