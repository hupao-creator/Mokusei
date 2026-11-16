// No-window production geometry probe. These are not renderer/performance metrics.
import Foundation
@testable import MokuseiUI
import MokuseiPluginUI

@main private enum GeometryProbe {
    static func main() throws {
        let plan = try composeThreadCard(.standard(identity: .init(), extensions: [.todo(steps: [
            .init(step: "Inspect the production canvas", status: .completed),
            .init(step: "Keep semantic controls visible", status: .inProgress),
            .init(step: "Review light and dark appearance", status: .pending),
        ])]), layoutContext: .init(availableCols: 3))
        let viewport = NativeOverviewViewport(width: 1800, height: 1000,
            toolbarBottom: NativeOverviewViewportDefaults.toolbarBottom)
        let usable = NativeOverviewCameraGeometry.framingRegion(viewport)
        var rows: [[String: Any]] = []
        for count in [1, 5, 12, 30] {
            let members = (0..<count).map { index in
                NativeOverviewMember(id: "card-\(index)", columns: index.isMultiple(of: 5) ? plan.size.cols : 1,
                    rows: index.isMultiple(of: 5) ? plan.size.rows : 1)
            }
            let result = try NativeOverviewLayout.solve(members: members, usableViewport: usable)
            guard let camera = result.automaticCamera else { throw CocoaError(.featureUnsupported) }
            let frames = result.placements.map { placement in
                let frame = placement.cardFrame
                return CGRect(x: camera.x + frame.minX * camera.scale,
                              y: camera.y + frame.minY * camera.scale,
                              width: frame.width * camera.scale,
                              height: frame.height * camera.scale)
            }
            let window = CGRect(x: 0, y: 0, width: 1800, height: 1000)
            rows.append(["count": count, "placed": result.placements.count,
                "totalNaturalCells": members.reduce(0) { $0 + $1.columns * $1.rows },
                "cameraScale": camera.scale,
                "scaleCap": NativeOverviewGeometryPolicy.standard.scaleCap ?? 1.7,
                "fitScale": NativeOverviewCameraGeometry.centeredTransform(
                    content: result.bounds.contentRect, usable: usable,
                    scaleCap: nil)?.scale ?? 0,
                "geometricFullyInWindow": frames.filter { window.contains($0) }.count,
                "geometricIntersectingWindow": frames.filter { window.intersects($0) }.count,
                "boundsColumnsRows": [result.bounds.columns, result.bounds.rows]])
        }
        let result: [String: Any] = ["kind": "production pure geometry, no GUI and no glass timing",
            "viewportPoints": [1800, 1000], "toolbarBottom": viewport.toolbarBottom,
            "planColumnsRows": [plan.size.cols, plan.size.rows], "records": rows]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
