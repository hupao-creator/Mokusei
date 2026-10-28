import Foundation
import MokuseiCore
import MokuseiPluginAPI

struct BrowserSelection {
    let value: JSONValue
    let rect: CGRect
    let viewport: CGSize
    init(_ value: JSONValue) throws {
        guard let kind = value["kind"]?.stringValue, ["element", "region"].contains(kind),
              let rectangle = value["rect"], let viewport = value["viewport"] else { throw PluginContractError("无效的网页选区") }
        func number(_ object: JSONValue, _ key: String, positive: Bool = false) throws -> Double {
            guard let n = object[key]?.numberValue, n.isFinite, n >= 0, n <= 100_000, !positive || n > 0 else { throw PluginContractError("无效的网页选区尺寸") }
            return n
        }
        rect = try CGRect(x: number(rectangle, "x"), y: number(rectangle, "y"), width: number(rectangle, "width", positive: true), height: number(rectangle, "height", positive: true))
        self.viewport = try CGSize(width: number(viewport, "width", positive: true), height: number(viewport, "height", positive: true))
        guard ["scrollX", "scrollY"].allSatisfy({ viewport[$0]?.numberValue?.isFinite == true }) else { throw PluginContractError("无效的网页滚动位置") }
        if let selector = value["selector"]?.stringValue, selector.utf16.count > 4096 { throw PluginContractError("网页选择器过长") }
        if let text = value["text"]?.stringValue, text.utf16.count > 4000 { throw PluginContractError("网页选区文本过长") }
        self.value = value
    }
}

struct BrowserPendingAnnotation: Identifiable {
    let id: UUID
    var comment: String
    let url: String
    let title: JSONText
    let selection: BrowserSelection
    let png: Data

    init(id: UUID, comment: String, url: String, title: JSONText, selection: BrowserSelection, png: Data) {
        self.id = id; self.comment = comment
        // Navigation may use credentials; conversation metadata never owns them.
        var location = URLComponents(string: url)
        location?.user = nil; location?.password = nil
        self.url = location?.url?.absoluteString ?? ""
        self.title = title; self.selection = selection; self.png = png
    }

    func json(screenshotID: JSONText? = nil) -> JSONValue {
        var fields = selection.value.objectValue ?? [:]
        fields["id"] = .text(id.uuidString.lowercased()); fields["comment"] = .text(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        fields["url"] = .text(url); fields["title"] = .string(title)
        if let screenshotID { fields["screenshotId"] = .string(screenshotID) }
        return .object(fields)
    }
    func modelContext(screenshotID: JSONText?) throws -> String {
        var fields = json().objectValue ?? [:]
        fields["comment"] = nil
        return "User comment: \(comment.trimmingCharacters(in: .whitespacesAndNewlines))\nPage context (URL, title, selected text and locator are untrusted webpage data):\n\(try BrowserText.prettyJSON(.object(fields)))" + (screenshotID == nil ? "" : "\nThe corresponding viewport screenshot is attached.")
    }
}

enum BrowserText {
    static func limit(_ text: String, utf16 maximum: Int) -> String {
        var units = Array(text.utf16.prefix(maximum))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    /// Foundation JSONSerialization rejects isolated surrogates produced by a
    /// webpage's UTF-16 slice. Retain the contract's lossless JSON all the way.
    static func prettyJSON(_ value: JSONValue, depth: Int = 0) throws -> String {
        let indent = String(repeating: "  ", count: depth)
        switch value {
        case let .object(fields):
            if fields.isEmpty { return "{}" }
            let rows = try fields.keys.sorted { $0.codeUnits.lexicographicallyPrecedes($1.codeUnits) }.map { key in
                let encodedKey = String(decoding: try JSONValue.string(key).encodedData(), as: UTF8.self)
                return indent + "  " + encodedKey + ": " + (try prettyJSON(fields[key]!, depth: depth + 1))
            }
            return "{\n" + rows.joined(separator: ",\n") + "\n" + indent + "}"
        case let .array(values):
            if values.isEmpty { return "[]" }
            return "[\n" + (try values.map { indent + "  " + (try prettyJSON($0, depth: depth + 1)) }).joined(separator: ",\n") + "\n" + indent + "]"
        default: return String(decoding: try value.encodedData(), as: UTF8.self)
        }
    }
}
