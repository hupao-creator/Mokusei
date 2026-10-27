"""Check the production fit geometry against the AppKit frame/bounds projection.

SwiftUI rendering is checked separately by NativeOverviewCenteringTests.
"""
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[3]
CAMERA = "app/macos/Sources/Host/Overview/NativeOverviewCamera.swift"
OUTPUT = ROOT / ".build/overview-centering"
HARNESS = r'''
import AppKit
import Foundation

private final class Plane: NSView { override var isFlipped: Bool { true } }
@main @MainActor struct Compare {
    static func main() throws {
        var records: [[String: Any]] = []
        // Fixed control boundaries exercise both a bare camera and a workspace
        // with a persistent Dock. The mounted suite supplies the real Dock size.
        for (width, height, toolbar, dock) in [(500.0, 600.0, 102.0, 0.0), (620, 600, 102, 68),
                                              (621, 600, 58, 68), (1180, 780, 58, 80),
                                              (2560, 1440, 58, 100)] {
            let viewport = NativeOverviewViewport(width: width, height: height,
                                                   toolbarBottom: toolbar, bottomReservedHeight: dock)
            for (w, h) in [(360.0, 200.0), (736, 416), (1488, 848), (2240, 1280), (360, 1280), (2240, 200)] {
                for (left, top) in [(0.0, 0.0), (-752, -432), (1128, 648)] {
                    let content = NativeOverviewContentRect(left: left, top: top, width: w, height: h)
                    let transform = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
                    let region = NativeOverviewCameraGeometry.framingRegion(viewport)
                    let host = Plane(frame: NSRect(x: 0, y: 0, width: width, height: height))
                    let plane = Plane(frame: .zero)
                    host.addSubview(plane)
                    // Project the camera using an AppKit flipped top-left origin.
                    plane.frame = CGRect(x: transform.x, y: transform.y, width: 8192 * transform.scale, height: 8192 * transform.scale)
                    plane.bounds = CGRect(x: 0, y: 0, width: 8192, height: 8192)
                    let projected = plane.convert(CGRect(x: left, y: top, width: w, height: h), to: host)
                    // Derive the oracle from the visible control boundaries,
                    // independently of the production framing-region helper.
                    let expectedX = width / 2
                    let expectedY = (toolbar + height - dock) / 2
                    records.append([
                        "viewport": [width, height], "toolbar": toolbar, "dock": dock,
                        "content": [left, top, w, h],
                        "region": [region.left, region.top, region.width, region.height],
                        "transform": [transform.scale, transform.x, transform.y],
                        "appkitProjectedBounds": [projected.minX, projected.minY, projected.width, projected.height],
                        "anchorError": [projected.midX - expectedX, projected.midY - expectedY]
                    ])
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
'''


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    harness = OUTPUT / "Compare.swift"
    harness.write_text(HARNESS)
    source = (ROOT / CAMERA).read_text()
    # Keep the production structs and complete pure geometry enum. The
    # asynchronous owner is irrelevant to this projection check.
    source = source[:source.index("/// Single-writer camera")]
    geometry = OUTPUT / "Geometry.swift"
    geometry.write_text(source)
    executable = OUTPUT / "verify-geometry"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                    "-module-cache-path", str(OUTPUT / "ModuleCache"),
                    str(geometry), str(harness), "-o", str(executable)], cwd=ROOT, check=True)
    records = json.loads(subprocess.check_output([str(executable)], cwd=ROOT, text=True))
    destination = OUTPUT / "geometry.json"
    destination.write_text(json.dumps(records, indent=2) + "\n")
    worst = max(max(map(abs, record["anchorError"])) for record in records)
    print(f"{len(records)} cases; maximum anchor error {worst:.3f}pt")
    print(destination)
    assert all(max(map(abs, record["anchorError"])) < 1e-6
               for record in records), "Camera projection does not preserve the framing anchor"


if __name__ == "__main__":
    main()
