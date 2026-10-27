import Foundation
import MokuseiCore

func claudeValidateActivity(_ value: JSONValue, history: Bool = false) throws {
    try claudeKeys(value, history ? ["kind","label","status","detail","toolName"] : ["id","kind","label","status","toolName","detail","parentId","taskId"])
    if !history { try claudeText(value["id"], max: 512, nonempty: true) }
    guard ["command","file","tool","search","thinking","agent","task","hook","review","subagent"].contains(value.claudeKind),
          (history ? ["completed","failed","cancelled"] : ["running","completed","failed","cancelled"]).contains(value["status"]?.stringValue ?? "") else { throw claudeInvalid() }
    try claudeText(value["label"], max: 2_000)
    for (key, max) in [("toolName",512),("detail",100_000),("parentId",512),("taskId",512)] {
        if let item = value[key] { try claudeText(item, max: max, nonempty: key == "toolName") }
    }
}
func claudeValidateInteraction(_ value: JSONValue, history: Bool = false) throws {
    try claudeKeys(value, history ? ["kind","title","description","toolName","questions","status"] : ["id","kind","title","description","toolName","canRemember","input","schema","elicitationMode","url","elicitationId","serverName","status","questions","inputDisplay","schemaDisplay"])
    if !history { try claudeText(value["id"], max: 512, nonempty: true) }
    guard ["permission","question","elicitation","dialog"].contains(value.claudeKind),
          (history ? ["allowed","denied","submitted","cancelled","resolved"] : ["pending","allowed","denied","submitted","cancelled","resolved"]).contains(value["status"]?.stringValue ?? "") else { throw claudeInvalid() }
    try claudeText(value["title"], max: 2_000)
    for (key, max) in [("description",20_000),("toolName",512),("url",8_192),("elicitationId",512),("serverName",2_000)] { if let item = value[key] { try claudeText(item, max: max) } }
    if let remember = value["canRemember"], remember.boolValue == nil { throw claudeInvalid() }
    if let mode = value["elicitationMode"], !["url","form"].contains(mode.stringValue ?? "") { throw claudeInvalid() }
    if value.claudeKind != "elicitation", ["elicitationMode","url","elicitationId","serverName"].contains(where: { value[$0] != nil }) { throw claudeInvalid() }
    for key in ["input","schema"] { if let item = value[key] {
        try claudeValidateInteractionJSON(item)
    } }
    for key in ["input","schema"] {
        if let display = value[key + "Display"] {
            guard let native = value[key], claudeJSONDisplayMatches(display, value:native) else { throw claudeInvalid(key + " presentation") }
        }
    }
    if let questions = value["questions"] { for question in try claudeArray(questions, max: 32) {
        try claudeKeys(question, ["question","header","multiSelect","options"])
        try claudeText(question["question"], max: 10_000)
        if let header = question["header"] { try claudeText(header, max: 1_000) }
        guard question["multiSelect"]?.boolValue != nil else { throw claudeInvalid() }
        for option in try claudeArray(question["options"], max: 32) {
            try claudeKeys(option, ["label","description"]); try claudeText(option["label"], max: 2_000)
            if let description = option["description"] { try claudeText(description, max: 10_000) }
        }
    } }
}
func claudeValidatePlan(_ value: JSONValue?) throws {
    for step in try claudeArray(value, max: 2_000) {
        try claudeKeys(step, ["step","status"]); try claudeText(step["step"], max: 32_000, nonempty: true)
        guard ["pending","inProgress","completed"].contains(step["status"]?.stringValue ?? "") else { throw claudeInvalid() }
    }
}
func claudeValidateUsage(_ value: JSONValue) throws {
    try claudeKeys(value, ["inputTokens","outputTokens","reasoningTokens","cachedTokens","cacheWriteTokens","totalTokens","contextTokens","contextWindow","costUsd"])
    for (_, number) in value.objectValue ?? [:] { try claudeNumber(number) }
}
func claudeValidateNotice(_ value: JSONValue, history: Bool = false) throws {
    try claudeKeys(value, history ? ["level","message"] : ["id","level","message"])
    if !history { try claudeText(value["id"], max: 512, nonempty: true) }
    try claudeText(value["message"], max: 20_000)
    guard ["info","warning","error"].contains(value["level"]?.stringValue ?? "") else { throw claudeInvalid() }
}
func claudeValidateAttachments(_ values: [JSONValue]) throws {
    try claudeUnique(values, key: "id")
    for value in values {
        try claudeKeys(value, ["annotation","id","name","mimeType","size","kind"])
        try claudeText(value["id"], max: 512, nonempty: true); try claudeText(value["name"], max: 8_192, nonempty: true)
        try claudeText(value["mimeType"], max: 256, nonempty: true)
        let size = try claudeNumber(value["size"])
        guard size.rounded() == size, size <= 9_007_199_254_740_991, ["image","audio","file"].contains(value.claudeKind) else { throw claudeInvalid() }
        if let annotation = value["annotation"] { try claudeValidateAnnotation(annotation) }
    }
}
func claudeValidateTimeline(_ value: JSONValue, history: Bool = false) throws {
    try claudeText(value["id"], max: 512, nonempty: true); try claudeNumber(value["createdAt"])
    let base: Set<String> = ["id","kind","createdAt"]
    switch value.claudeKind {
    case "user-message":
        try claudeKeys(value, base.union(history ? ["content","attachments","checkpointId"] : ["promptIndex","checkpointId"]))
        if history { try claudeText(value["content"], max: 2_000_000); if let attachments = value["attachments"] { try claudeValidateAttachments(claudeArray(attachments, max: 128)) } }
        else { let index = try claudeNumber(value["promptIndex"]); guard index.rounded() == index else { throw claudeInvalid() } }
        if let checkpoint = value["checkpointId"] { try claudeText(checkpoint, max: 512, nonempty: true) }
    case "assistant":
        try claudeKeys(value, base.union(history ? ["content","status"] : ["content","status","messageId"]))
        try claudeText(value["content"], max: 4_000_000)
        guard (history ? ["complete","failed","cancelled"] : ["complete","streaming","failed","cancelled"]).contains(value["status"]?.stringValue ?? "") else { throw claudeInvalid() }
        if let id = value["messageId"] { try claudeText(id, max: 512, nonempty: true) }
    case "reasoning","diff","review":
        try claudeKeys(value, base.union(["content"])); try claudeText(value["content"], max: value.claudeKind == "reasoning" ? 4_000_000 : 500_000)
    case "activity": try claudeKeys(value, base.union(["activity"])); try claudeValidateActivity(value["activity"] ?? .null, history: history)
    case "interaction": try claudeKeys(value, base.union(["interaction"])); try claudeValidateInteraction(value["interaction"] ?? .null, history: history)
    case "notice": try claudeKeys(value, base.union(["notice"])); try claudeValidateNotice(value["notice"] ?? .null, history: history)
    case "plan": try claudeKeys(value, base.union(["plan","explanation"])); try claudeValidatePlan(value["plan"])
        if let explanation = value["explanation"] { try claudeText(explanation, max: 32_000) }
    case "usage": try claudeKeys(value, base.union(["usage"])); try claudeValidateUsage(value["usage"] ?? .null)
    case "error": try claudeKeys(value, base.union(["message"])); try claudeText(value["message"], max: 100_000)
    case "context-compaction": try claudeKeys(value, base)
    default: throw claudeInvalid()
    }
}
func claudeValidateRuntime(_ value: JSONValue) throws {
    try claudeKeys(value, ["model","cwd","claudeVersion","permissionMode","effort","capabilities","models","agents","commands","skills","plugins","mcpServers","backgroundTasks","remoteControl"])
    for key in ["model","cwd","claudeVersion","permissionMode","effort"] { if let item = value[key] { try claudeText(item, max: key == "cwd" ? 4_096 : 512) } }
    for key in ["capabilities","skills"] { if let items = value[key] { for item in try claudeArray(items, max: key == "skills" ? 2_000 : 512) { try claudeText(item, max: 2_000, nonempty: true) } } }
    let collections: [(String, Set<String>, Set<String>)] = [
        ("models", ["value","displayName","description","resolvedModel"], ["value","displayName"]),
        ("agents", ["name","description","model"], ["name","description"]),
        ("commands", ["name","description","argumentHint"], ["name"]),
        ("plugins", ["name","path","version"], ["name"]),
        ("mcpServers", ["name","status","serverInfo"], ["name","status"]),
        ("backgroundTasks", ["id","type","description","status"], ["id","description","status"])
    ]
    for (key, keys, required) in collections { if let items = value[key] {
        for item in try claudeArray(items, max: key == "commands" ? 2_000 : 512) {
            try claudeKeys(item, keys)
            for field in keys where required.contains(field) || item[field] != nil {
                let limit = field == "name" || field == "displayName" ? 1_000 : field == "description" || field == "serverInfo" ? 8_000 : field == "argumentHint" ? 2_000 : field == "path" ? 4_096 : ["version","status","type"].contains(field) ? 256 : 512
                let nonempty = ["name","displayName","value","resolvedModel","model","id","status"].contains(field) || key == "backgroundTasks" && field == "description"
                try claudeText(item[field], max:limit, nonempty:nonempty)
            }
        }
    } }
    if let remote = value["remoteControl"] {
        try claudeKeys(remote, ["enabled","sessionUrl","connectUrl","environmentId"])
        guard remote["enabled"]?.boolValue != nil else { throw claudeInvalid() }
        for key in ["sessionUrl","connectUrl","environmentId"] { if let text = remote[key] { try claudeText(text, max: 8_192, nonempty:true) } }
    }
}

private func claudeValidateAnnotation(_ value: JSONValue) throws {
    try claudeKeys(value,["id","comment","url","title","kind","rect","viewport","selector","text","screenshotId"])
    func uuid(_ value: JSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return text.range(of:#"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"#, options:.regularExpression) != nil || text == "00000000-0000-0000-0000-000000000000" || text == "ffffffff-ffff-ffff-ffff-ffffffffffff"
    }
    guard uuid(value["id"]), !claudeTrim(value["comment"]).isEmpty, claudeTrim(value["comment"]).utf16.count <= 10_000,
          ["element","region"].contains(value.claudeKind), let url = value["url"]?.stringValue.flatMap(URL.init(string:)), ["http","https"].contains(url.scheme ?? ""), url.host != nil else { throw claudeInvalid("annotation") }
    try claudeText(value["title"],max:2_048)
    for (key,limit) in [("selector",4_096),("text",4_000)] { if let field = value[key] { try claudeText(field,max:limit) } }
    if let screenshot = value["screenshotId"], !uuid(screenshot) { throw claudeInvalid("annotation screenshot") }
    for (key,fields) in [("rect",["x","y","width","height"]),("viewport",["width","height","scrollX","scrollY"])] {
        guard let object = value[key] else { throw claudeInvalid("annotation geometry") }; try claudeKeys(object,Set(fields))
        for field in fields {
            guard let number = object[field]?.numberValue, number.isFinite else { throw claudeInvalid("annotation geometry") }
            if ["scrollX","scrollY"].contains(field) { continue }
            guard number >= 0, number <= 100_000, !["width","height"].contains(field) || number > 0 else { throw claudeInvalid("annotation geometry") }
        }
    }
}

private func claudeValidateInteractionJSON(_ root: JSONValue) throws {
    var pending:[(JSONValue,Int)]=[(root,0)], nodes=0, characters=0
    while let (value,depth)=pending.popLast() {
        nodes += 1
        guard nodes <= 10_000,depth <= 32 else { throw claudeInvalid("interaction JSON") }
        switch value {
        case .null,.bool: break
        case .integer(let integer): characters += integer.literal.count
        case .number(let number): guard number.isFinite else { throw claudeInvalid("interaction JSON") }; characters += 32
        case .string(let text): guard !text.codeUnits.contains(0) else { throw claudeInvalid("interaction JSON") }; characters += text.codeUnits.count
        case .array(let values): pending += values.map { ($0,depth+1) }
        case .object(let values):
            for (key,value) in values {
                guard !key.codeUnits.contains(0) else { throw claudeInvalid("interaction JSON") }
                characters += key.codeUnits.count; pending.append((value,depth+1))
            }
        }
        guard characters <= 100_000 else { throw claudeInvalid("interaction JSON") }
    }
}
