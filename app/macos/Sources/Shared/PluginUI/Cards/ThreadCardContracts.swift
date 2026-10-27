import Foundation
import MokuseiCore
import MokuseiPluginAPI

/// Pure, ephemeral rendering values. These are not a persisted or canonical timeline.
public struct ThreadCardSize: Hashable, Sendable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}
public struct ThreadCardLayoutContext: Hashable, Sendable {
    public let availableCols: Int
    public init(availableCols: Int) { self.availableCols = availableCols }
}
public struct ThreadCardHarnessBrand: Hashable, Sendable {
    public let brandKey: String
    public let label: String
    public let logoSource: String
    public init(brandKey: String, label: String, logoSource: String) {
        self.brandKey = brandKey; self.label = label; self.logoSource = logoSource
    }
}
/// Milliseconds since the Unix epoch, matching the plugin protocol.
public struct ThreadCardRuntimeValue: Hashable, Sendable {
    public let startedAt: Double
    public let endedAt: Double?
    public init(startedAt: Double, endedAt: Double? = nil) { self.startedAt = startedAt; self.endedAt = endedAt }
}
public struct ThreadCardMessage: Hashable, Sendable {
    public let id: JSONText
    public let text: String
    public init(id: JSONText, text: String) { self.id = id; self.text = text }
}
public struct ThreadCardIdentityView: Hashable, Sendable {
    public let title: String
    public let providerStatus: String?
    public let state: String?
    public let harness: ThreadCardHarnessBrand?
    public let model: String?
    public let effort: String?
    public let fastMode: Bool
    public let runtime: ThreadCardRuntimeValue?
    public let cwd: String?
    public let cwdName: String?
    public let usesWorktree: Bool
    public let steer: String?
    public let excerpt: String
    public let message: ThreadCardMessage?
    public let initialResponse: ThreadCardInitialResponse?
    /// Eligible first-execution agent content, so leaving scope alone never animates a fallback.
    public let initialResponseContent: Bool
    public init(title: String, providerStatus: String? = nil, state: String? = nil,
                harness: ThreadCardHarnessBrand? = nil, model: String? = nil, effort: String? = nil,
                fastMode: Bool = false, runtime: ThreadCardRuntimeValue? = nil, cwd: String? = nil,
                cwdName: String? = nil, usesWorktree: Bool = false, steer: String? = nil,
                excerpt: String, message: ThreadCardMessage? = nil, initialResponse: ThreadCardInitialResponse? = nil, initialResponseContent: Bool = false) {
        self.title = title; self.providerStatus = providerStatus; self.state = state; self.harness = harness
        self.model = model; self.effort = effort; self.fastMode = fastMode; self.runtime = runtime
        self.cwd = cwd; self.cwdName = cwdName; self.usesWorktree = usesWorktree; self.steer = steer
        self.excerpt = excerpt; self.message = message; self.initialResponse = initialResponse; self.initialResponseContent = initialResponseContent
    }
}
public enum ThreadCardActivityStatus: String, Hashable, Sendable { case running, completed, failed, cancelled }
public enum ThreadCardIdentityToolKind: String, Hashable, Sendable { case command, file, search, tool }
public struct ThreadCardIdentityTool: Hashable, Sendable {
    public let kind: ThreadCardIdentityToolKind
    public let name: String
    public let summary: String?
    public let status: ThreadCardActivityStatus
    public init(kind: ThreadCardIdentityToolKind, name: String, summary: String? = nil, status: ThreadCardActivityStatus) {
        self.kind = kind; self.name = name; self.summary = summary; self.status = status
    }
}
public struct ThreadCardIdentityUsagePart: Hashable, Sendable, Identifiable {
    public let suffix: String?
    public let description: String?
    public let id: String
    public let label: String?
    public let value: String
    public let numericValue: Double?
    public init(suffix: String? = nil, description: String? = nil, id: String, label: String? = nil,
                value: String, numericValue: Double? = nil) {
        self.suffix = suffix; self.description = description; self.id = id; self.label = label
        self.value = value; self.numericValue = numericValue
    }
}
public struct ThreadCardIdentityUsage: Hashable, Sendable {
    public let parts: [ThreadCardIdentityUsagePart]
    public init(parts: [ThreadCardIdentityUsagePart]) { self.parts = parts }
}
public struct ThreadCardIdentityProjection: Hashable, Sendable {
    public let recentTools: [ThreadCardIdentityTool]?
    public let latestTool: ThreadCardIdentityTool?
    public let usage: ThreadCardIdentityUsage?
    public init(recentTools: [ThreadCardIdentityTool]? = nil, latestTool: ThreadCardIdentityTool? = nil,
                usage: ThreadCardIdentityUsage? = nil) {
        self.recentTools = recentTools; self.latestTool = latestTool; self.usage = usage
    }
}
public enum ThreadCardPlanStatus: String, Hashable, Sendable { case pending, inProgress, completed }
public struct ThreadCardPlanStep: Hashable, Sendable {
    public let step: String
    public let status: ThreadCardPlanStatus
    public init(step: String, status: ThreadCardPlanStatus) { self.step = step; self.status = status }
}
public enum ThreadCardDerivedKind: String, Hashable, Sendable { case shell, agent, task }
public struct ThreadCardDerivedRow: Hashable, Sendable, Identifiable {
    public let id: JSONText
    public let label: String
    public let status: ThreadCardActivityStatus
    public let kind: ThreadCardDerivedKind
    public let commandLine: Bool
    public init(id: JSONText, label: String, status: ThreadCardActivityStatus,
                kind: ThreadCardDerivedKind, commandLine: Bool = false) {
        self.id = id; self.label = label; self.status = status; self.kind = kind; self.commandLine = commandLine
    }
}
public struct ThreadCardDecisionAction: Hashable, Sendable, Identifiable {
    public let id: JSONText
    public let label: String
    public init(id: JSONText, label: String) { self.id = id; self.label = label }
}
public struct ThreadCardQuestionOption: Hashable, Sendable, Identifiable {
    public let id: JSONText
    public let label: String
    public let description: String?
    public let value: JSONText
    public init(id: JSONText, label: String, description: String? = nil, value: JSONText) {
        self.id = id; self.label = label; self.description = description; self.value = value
    }
}
public struct ThreadCardQuestion: Hashable, Sendable, Identifiable {
    public let id: JSONText
    public let prompt: String
    public let header: String?
    public let multiple: Bool
    public let allowOther: Bool
    public let secret: Bool
    public let options: [ThreadCardQuestionOption]
    public init(id: JSONText, prompt: String, header: String? = nil, multiple: Bool = false,
                allowOther: Bool = false, secret: Bool = false, options: [ThreadCardQuestionOption] = []) {
        self.id = id; self.prompt = prompt; self.header = header; self.multiple = multiple
        self.allowOther = allowOther; self.secret = secret; self.options = options
    }
}
public struct ThreadCardIntervention: Hashable, Sendable, Identifiable {
    public let id: JSONText
    public let title: String
    public let detail: String?
    public let actions: [ThreadCardDecisionAction]
    public let questions: [ThreadCardQuestion]
    public let submitActionId: JSONText?
    public let skipAction: ThreadCardDecisionAction?
    public init(id: JSONText, title: String, detail: String? = nil, actions: [ThreadCardDecisionAction],
                questions: [ThreadCardQuestion] = [], submitActionId: JSONText? = nil,
                skipAction: ThreadCardDecisionAction? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.actions = actions
        self.questions = questions; self.submitActionId = submitActionId; self.skipAction = skipAction
    }
}
public enum ThreadCardAnswer: Hashable, Sendable { case string(JSONText), strings([JSONText]) }
public struct ThreadCardInterventionResponse: Hashable, Sendable {
    public let actionId: JSONText
    public let answers: [JSONText: ThreadCardAnswer]?
    public init(actionId: JSONText, answers: [JSONText: ThreadCardAnswer]? = nil) {
        self.actionId = actionId; self.answers = answers
    }
}
public typealias ThreadCardInterventionHandler = @MainActor (ThreadCardInterventionResponse) async throws -> Void
public enum ThreadCardExtensionKind: String, Hashable, Sendable { case todo, intervention, derived, git }
public enum ThreadCardComponentKind: String, Hashable, Sendable { case identity, todo, derived, permission, question, git }
public struct ThreadCardSizeContract: Hashable, Sendable {
    public let component: ThreadCardComponentKind
    public let allowedSizes: [ThreadCardSize]
    public let preferredSize: ThreadCardSize
    public init(component: ThreadCardComponentKind, allowedSizes: [ThreadCardSize], preferredSize: ThreadCardSize) {
        self.component = component; self.allowedSizes = allowedSizes; self.preferredSize = preferredSize
    }
}
public struct ThreadCardSizeSelection: Hashable, Sendable {
    public let component: ThreadCardComponentKind
    public let allowedSizes: [ThreadCardSize]
    public let preferredSize: ThreadCardSize
    public let selectedSize: ThreadCardSize
    public init(component: ThreadCardComponentKind, allowedSizes: [ThreadCardSize], preferredSize: ThreadCardSize, selectedSize: ThreadCardSize) {
        self.component = component; self.allowedSizes = allowedSizes; self.preferredSize = preferredSize; self.selectedSize = selectedSize
    }
}
public enum ThreadCardExtensionProjection: Hashable, Sendable {
    case todo(steps: [ThreadCardPlanStep])
    case intervention(ThreadCardIntervention)
    case derived(rows: [ThreadCardDerivedRow])
    case git(HarnessGitStatus)
    public var kind: ThreadCardExtensionKind {
        switch self { case .todo: .todo; case .intervention: .intervention; case .derived: .derived; case .git: .git }
    }
}
public struct ThreadCardSlot: Hashable, Sendable, Identifiable {
    public let id: String
    public let col: Int
    public let row: Int
    public let size: ThreadCardSize
    public let className: String?
    public init(id: String, col: Int, row: Int, size: ThreadCardSize, className: String? = nil) {
        self.id = id; self.col = col; self.row = row; self.size = size; self.className = className
    }
}
public struct ThreadCardSlotLayout: Hashable, Sendable {
    public let size: ThreadCardSize
    public let identitySize: ThreadCardSize
    public let slots: [ThreadCardSlot]
    public init(size: ThreadCardSize, identitySize: ThreadCardSize, slots: [ThreadCardSlot]) {
        self.size = size; self.identitySize = identitySize; self.slots = slots
    }
}
public enum ThreadCardProjection: Hashable, Sendable {
    case standard(identity: ThreadCardIdentityProjection? = nil, extensions: [ThreadCardExtensionProjection])
    case slots(identity: ThreadCardIdentityProjection? = nil, layout: ThreadCardSlotLayout)
    public var identity: ThreadCardIdentityProjection? {
        switch self { case .standard(let identity, _), .slots(let identity, _): identity }
    }
}
public enum ThreadCardVariantId: String, Hashable, Sendable { case compact, wide, tall }
public struct ThreadCardExtensionPlacement: Hashable, Sendable {
    public let kind: ThreadCardExtensionKind
    public let component: ThreadCardComponentKind
    public let variant: ThreadCardVariantId
    public let col: Int
    public let row: Int
    public let allowedSizes: [ThreadCardSize]
    public let preferredSize: ThreadCardSize
    public let selectedSize: ThreadCardSize
    public init(kind: ThreadCardExtensionKind, component: ThreadCardComponentKind, variant: ThreadCardVariantId,
                col: Int, row: Int, allowedSizes: [ThreadCardSize], preferredSize: ThreadCardSize, selectedSize: ThreadCardSize) {
        self.kind = kind; self.component = component; self.variant = variant; self.col = col; self.row = row
        self.allowedSizes = allowedSizes; self.preferredSize = preferredSize; self.selectedSize = selectedSize
    }
}
public enum ThreadCardComposition: Hashable, Sendable {
    case standard(size: ThreadCardSize, identity: ThreadCardSizeSelection, placements: [ThreadCardExtensionPlacement], key: String)
    case slots(size: ThreadCardSize, identitySize: ThreadCardSize, slots: [ThreadCardSlot], key: String)
    public var size: ThreadCardSize {
        switch self { case .standard(let size, _, _, _), .slots(let size, _, _, _): size }
    }
    public var key: String {
        switch self { case .standard(_, _, _, let key), .slots(_, _, _, let key): key }
    }
    public var identitySize: ThreadCardSize {
        switch self { case .standard(_, let identity, _, _): identity.selectedSize; case .slots(_, let identity, _, _): identity }
    }
}
public struct ThreadCardPresentation: Hashable, Sendable {
    public let projection: ThreadCardProjection
    public let composition: ThreadCardComposition
    public let size: ThreadCardSize
    /// Structure only: no text, status, progress, or opaque provider state.
    public let key: String
    public init(projection: ThreadCardProjection, composition: ThreadCardComposition, size: ThreadCardSize, key: String) {
        self.projection = projection; self.composition = composition; self.size = size; self.key = key
    }
}
