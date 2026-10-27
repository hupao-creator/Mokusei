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
        let viewport = NativeOverviewViewport(width: 1800, height: 1000, toolbarBottom: 58)
        let region = NativeOverviewCameraGeometry.framingRegion(viewport)
        let minimum = NativeOverviewCameraGeometry.minimumScale(in: viewport)
        var rows: [[String: Any]] = []
        for count in [1, 5, 12, 30] {
            let members = (0..<count).map { index in
                NativeOverviewMember(id: "card-\(index)", columns: index.isMultiple(of: 5) ? plan.size.cols : 1,
                    rows: index.isMultiple(of: 5) ? plan.size.rows : 1)
            }
            let result = try NativeOverviewLayout.plan(previous: [], next: members,
                fittingSize: .init(width: region.width / minimum, height: region.height / minimum),
                preferredSize: .init(width: region.width / max(1, minimum), height: region.height / max(1, minimum)))
            let content = NativeOverviewContentRect(left: Double(result.bounds.column) * 376,
                top: Double(result.bounds.row) * 216, width: result.bounds.width, height: result.bounds.height)
            let camera = NativeOverviewCameraGeometry.fit(content, viewport: viewport)
            let frames = result.placements.map { placement in
                placement.cardFrame.applying(CGAffineTransform(a: camera.scale, b: 0, c: 0,
                    d: camera.scale, tx: camera.x, ty: camera.y))
            }
            let window = CGRect(x: 0, y: 0, width: 1800, height: 1000)
            rows.append(["count": count, "placed": result.placements.count,
                "totalNaturalCells": members.reduce(0) { $0 + $1.columns * $1.rows },
                "minimumScale": minimum, "cameraScale": camera.scale,
                "wholeSceneFitScale": NativeOverviewCameraGeometry.wholeSceneFitScale(content, viewport: viewport),
                "fitsAtReadingScale": NativeOverviewCameraGeometry.fitsAtReadingScale(content, viewport: viewport),
                "geometricFullyInWindow": frames.filter { window.contains($0) }.count,
                "geometricIntersectingWindow": frames.filter { window.intersects($0) }.count,
                "boundsColumnsRows": [result.bounds.columns, result.bounds.rows]])
        }
        let result: [String: Any] = ["kind": "production pure geometry, no GUI and no glass timing",
            "viewportPoints": [1800, 1000], "toolbarBottom": viewport.toolbarBottom,
            "readableCellBudget": NativeOverviewCameraGeometry.readableCellBudget,
            "planColumnsRows": [plan.size.cols, plan.size.rows], "records": rows]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
