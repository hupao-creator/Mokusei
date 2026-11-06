import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

struct CodexUserMessage: View {
    @Environment(\.threadAgentDetail) private var agentDetail
    let message: CodexMessage
    let actions: HarnessThreadActions
    let context: HarnessRenderContext
    @Environment(\.locale) private var locale

    var body: some View {
        if agentDetail {
            ThreadSteerMessage(content: message.content, createdAt: message.raw["createdAt"]?.numberValue,
                details: message.annotations.isEmpty && message.attachments.isEmpty ? nil : AnyView(fullMessage))
        } else { fullMessage }
    }

    private var fullMessage: some View {
        ThreadMessage(id: message.id, author: .user, content: message.content,
            steeringLabel: agentDetail ? nil : codexLocalized(message.kind == "follow-up" ? "补充" : "你", locale: locale),
            annotations: message.annotations.map { annotation in
                ThreadMessageAnnotation(id: annotation.codexIdentity("id"), url: annotation["url"]?.stringValue ?? "",
                    title: annotation["title"]?.stringValue, comment: annotation["comment"]?.stringValue ?? "",
                    screenshotId: annotation["screenshotId"].map { _ in annotation.codexIdentity("screenshotId") })
            }, attachments: message.attachments.filter { attachment in
                !message.annotations.contains { $0["screenshotId"] == attachment["id"] }
            }.map { attachment in
                ThreadMessageAttachment(id: attachment.codexIdentity("id"), label: attachment["name"]?.stringValue ?? "", title: attachment["name"]?.stringValue)
            }, openExternal: { url in Task { try? await actions.openExternal(JSONText(url.absoluteString)) } },
            resolveMedia: context.resolveMedia, previewAttachment: context.previewAttachment)
    }
}
