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

/// The field keeps its card-local coordinates when several cards share a drawable.
struct NativeOverviewCloudTile: Sendable {
    let origin: CGPoint
    let input: NativeOverviewCloudInput
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

    func sample() -> (geometry: [Float], continues: Bool) {
        let progress = fadeStartedAt.map { min(1, max(0, (CACurrentMediaTime() - $0) / 0.4)) } ?? 1
        let value = fadeFrom.map { $0 + (targetIntensity - $0) * UnitCurve.easeInOut.value(at: progress) }
            ?? targetIntensity
        let time = animates ? Date().timeIntervalSince(startedAt) : frozenMotionTime
        // A zero-energy terminal frame clears the Metal surface without waiting
        // for a main-actor callback to hide it after a fade-out.
        var geometry = NativeCloudField(palette: palette, intensity: max(value, 0.000001),
            time: time * 1.4 + palette.phase, seed: seed).geometry(in: size, colorScheme: colorScheme)
        if value <= 0 {
            for index in stride(from: 4, to: geometry.count, by: 5) { geometry[index] = 0 }
        }
        return (geometry, progress < 1 || (animates && value > 0))
    }
}

/// The main actor owns the layer's geometry/visibility; this serial queue alone
/// requests drawables and encodes commands. Mutable buffers belong to that queue.
/// A locked generation retires queued work, and one command buffer bounds submitted work
/// without blocking the main actor or building a backlog of stale animation frames.
final class NativeOverviewCloudRenderer: @unchecked Sendable {
    private let layer: CAMetalLayer
    private let pipeline: NativeOverviewCloudPipeline
    private let queue = DispatchQueue(label: "com.mokusei.overview.cloud-render", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var stopped = false
    private var inFlight: MTLCommandBuffer?
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

    /// Independent, screen-rate-capped sampling with at most one GPU frame in flight.
    func drive(_ tiles: [NativeOverviewCloudTile], size: CGSize, generation: UInt64, interval: Double,
               completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, self.accepts(generation) else { return }
            self.timer?.cancel()
            // Inputs are immutable for this revision. Palette and geometry storage
            // stay alive until the GPU has finished even if the driver is retargeted.
            let fields = tiles.compactMap { Field($0, device: self.pipeline.device) }
            guard !fields.isEmpty, fields.count == tiles.count else { completion(false); return }
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
                // This tick already runs on the buffers' owning queue. A steady
                // frame needs no separate completion wakeup to admit the next one.
                self.releaseFinishedFrame()
                guard self.inFlight == nil else { return }
                autoreleasepool {
                    var continues = false
                    for field in fields {
                        if field.sample() { continues = true }
                    }
                    if !first && continues {
                        self.encode(fields, size: size, generation: generation, completion: nil)
                        return
                    }
                    let notify = first
                    self.encode(fields, size: size, generation: generation) { [weak self, continues] succeeded in
                        if notify { completion(succeeded) }
                        if succeeded && !continues {
                            guard let self, self.driverRevision == revision else { return }
                            self.timer?.cancel()
                            self.timer = nil
                        }
                    }
                    first = false
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

    private func releaseFinishedFrame() {
        switch inFlight?.status {
        case .completed, .error: inFlight = nil
        default: break
        }
    }

    /// A render pass draws the disjoint card rectangles into a single transparent target.
    private func encode(_ fields: [Field], size: CGSize, generation: UInt64,
                        completion: (@Sendable (Bool) -> Void)?) {
        guard accepts(generation), let drawable = layer.nextDrawable(), accepts(generation),
              let commands = pipeline.commandQueue.makeCommandBuffer() else {
            completion?(false); return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            completion?(false); return
        }
        let scale = CGSize(width: Double(drawable.texture.width) / size.width,
                           height: Double(drawable.texture.height) / size.height)
        encoder.setRenderPipelineState(pipeline.state)
        for field in fields {
            field.draw(into: encoder, scale: scale, target: drawable.texture)
        }
        encoder.endEncoding()
        guard accepts(generation) else { completion?(false); return }
        if let completion {
            commands.addCompletedHandler { [self] finished in
                let succeeded = finished.status == .completed
                queue.async { [self] in
                    releaseFinishedFrame()
                    completion(succeeded && accepts(generation))
                }
            }
        }
        inFlight = commands
        commands.present(drawable)
        commands.commit()
    }

    /// Accessed only by the render queue, after its previous submission completes.
    private final class Field {
        let tile: NativeOverviewCloudTile
        let geometry: MTLBuffer
        let colors: MTLBuffer

        init?(_ tile: NativeOverviewCloudTile, device: MTLDevice) {
            let palette = tile.input.colors
            let colorBuffer = palette.withUnsafeBytes { bytes -> MTLBuffer? in
                guard let address = bytes.baseAddress, !bytes.isEmpty else { return nil }
                return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
            }
            guard let colors = colorBuffer,
                  let geometry = device.makeBuffer(length: palette.count * 5 * MemoryLayout<Float>.stride,
                                                   options: .storageModeShared) else { return nil }
            self.tile = tile
            self.geometry = geometry
            self.colors = colors
        }

        func sample() -> Bool {
            let sample = tile.input.sample()
            sample.geometry.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { memcpy(geometry.contents(), base, bytes.count) }
            }
            return sample.continues
        }

        func draw(into encoder: MTLRenderCommandEncoder, scale: CGSize, target: MTLTexture) {
            let x = tile.origin.x * scale.width, y = tile.origin.y * scale.height
            let width = tile.input.size.width * scale.width, height = tile.input.size.height * scale.height
            // Clip the full-screen triangle to this tile, including fractional raster scales.
            let left = max(0, Int(floor(x))), top = max(0, Int(floor(y)))
            let right = min(target.width, Int(ceil(x + width))), bottom = min(target.height, Int(ceil(y + height)))
            guard right > left, bottom > top else { return }
            encoder.setScissorRect(.init(x: left, y: top, width: right - left, height: bottom - top))
            encoder.setViewport(.init(originX: x, originY: y, width: width, height: height, znear: 0, zfar: 1))
            var uniforms = Uniforms(pointsPerPixel: SIMD2(Float(1 / scale.width), Float(1 / scale.height)),
                                    pixelOrigin: SIMD2(Float(x), Float(y)),
                                    geometryCount: UInt32(tile.input.colors.count * 5),
                                    colorCount: UInt32(tile.input.colors.count))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBuffer(geometry, offset: 0, index: 1)
            encoder.setFragmentBuffer(colors, offset: 0, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    /// Matches NativeCloudUniforms in CloudLoading.metal.
    private struct Uniforms {
        let pointsPerPixel: SIMD2<Float>
        let pixelOrigin: SIMD2<Float>
        let geometryCount: UInt32
        let colorCount: UInt32
    }
}
