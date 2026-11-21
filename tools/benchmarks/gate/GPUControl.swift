// Independent offscreen capability control, never linked into the product.
import Foundation
import Metal

let mode = CommandLine.arguments.dropFirst().first ?? "idle"
guard ["idle", "busy"].contains(mode) else { exit(2) }
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let buffer = device.makeBuffer(length: 16 * 1024 * 1024, options: .storageModePrivate) else {
    fputs("Metal device/queue/buffer unavailable\n", stderr)
    exit(2)
}
Thread.sleep(forTimeInterval: 0.5)
let end = ProcessInfo.processInfo.systemUptime + 1.0
var commands = 0
var gpuSeconds = 0.0
while ProcessInfo.processInfo.systemUptime < end {
    if mode == "idle" {
        Thread.sleep(forTimeInterval: 0.01)
        continue
    }
    guard let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { exit(2) }
    command.label = "chief-independent-gpu-control"
    blit.fill(buffer: buffer, range: 0..<buffer.length, value: UInt8(commands % 256))
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed, command.gpuEndTime >= command.gpuStartTime, command.gpuStartTime > 0 else { exit(2) }
    gpuSeconds += command.gpuEndTime - command.gpuStartTime
    commands += 1
}
let result: [String: Any] = ["kind": "independent-metal-control", "mode": mode,
    "commands": commands, "completedCommandGPUSeconds": gpuSeconds,
    "device": device.name, "pid": ProcessInfo.processInfo.processIdentifier,
    "scope": "completed owned blit commands; no presentation, App GPU or energy claim"]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
