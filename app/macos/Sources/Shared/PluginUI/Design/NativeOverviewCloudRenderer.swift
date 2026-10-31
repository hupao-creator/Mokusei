import Foundation
import Metal
import QuartzCore

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
        lock.lock(); defer { lock.unlock() }
        stopped = true
        generation &+= 1
    }

    private func accepts(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && generation == value
    }

    /// Completion is optional for the ordinary motion frames. It is used when
    /// revealing a surface or completing a requested static redraw.
    func submit(_ frame: NativeOverviewCloudFrame, generation: UInt64,
                completion: (@Sendable (Bool) -> Void)? = nil) -> Bool {
        guard accepts(generation), permit.wait(timeout: .now()) == .success else { return false }
        queue.async { [self] in
            autoreleasepool { encode(frame, generation: generation, completion: completion) }
        }
        return true
    }

    private func encode(_ frame: NativeOverviewCloudFrame, generation: UInt64,
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
        commands.addCompletedHandler { [self] commands in
            let succeeded = commands.status == .completed
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
